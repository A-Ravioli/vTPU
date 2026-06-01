import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, halt
from virtual_tpu.memory import MemorySystem
from virtual_tpu.numeric import bf16_to_float32, float32_to_bf16
from virtual_tpu.qwen.kernels import (
    Conv1DLayout,
    DeltaNetStepLayout,
    L2NormLayout,
    conv1d_causal_program,
    gated_deltanet_step_program,
    l2norm_program,
)

VM = AddressSpace.VMEM0


def _bf(x):
    return bf16_to_float32(float32_to_bf16(np.asarray(x, np.float32)))


def _run(mem, prog):
    res = GoldenExecutor(list(prog) + [halt()], mem).run()
    assert res.reason is HaltReason.HALT, res.error


def test_l2norm_kernel():
    n = 16
    x = np.random.default_rng(0).standard_normal(n).astype(np.float32) * 2
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 16)
    L = L2NormLayout(x=0x000, out=0x100, ss=0x200, rinv=0x210, n=n)
    mem.write_f32_vector(VM, L.x, x)
    _run(mem, l2norm_program(L))
    got = mem.read_f32_vector(VM, L.out, n)
    ref = x / np.sqrt((x * x).sum())
    np.testing.assert_allclose(got, ref, rtol=3e-3, atol=1e-4)


def test_conv1d_causal_kernel():
    C, K = 8, 4
    rng = np.random.default_rng(1)
    xhist = [rng.standard_normal(C).astype(np.float32) for _ in range(K)]  # lag 0..3
    wf = [rng.standard_normal(C).astype(np.float32) for _ in range(K)]
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 16)
    taps_x = tuple(0x000 + j * 0x100 for j in range(K))
    taps_w = tuple(0x800 + j * 0x100 for j in range(K))
    L = Conv1DLayout(taps_x=taps_x, taps_w=taps_w, acc=0x1000, tmp=0x1100, out=0x1200, c=C)
    for j in range(K):
        mem.write_f32_vector(VM, taps_x[j], xhist[j])
        mem.write_f32_vector(VM, taps_w[j], wf[j])
    _run(mem, conv1d_causal_program(L))
    got = mem.read_f32_vector(VM, L.out, C)
    acc = sum(wf[j] * xhist[j] for j in range(K))
    ref = acc * (1.0 / (1.0 + np.exp(-acc)))
    np.testing.assert_allclose(got, ref, rtol=3e-3, atol=1e-3)


def _deltanet_ref_step(S, k_n, q_n, v, alpha, beta, g):
    kb, qb = _bf(k_n), _bf(q_n)
    u = _bf(S) @ kb
    w = beta * (v - alpha * u)
    outer = _bf(w)[:, None] * kb[None, :]
    S_new = alpha * S + outer
    o = _bf(S_new) @ qb
    silu_g = g * (1.0 / (1.0 + np.exp(-g)))
    out = o * silu_g
    return S_new, out


def test_gated_deltanet_recurrence_multistep():
    d = 8  # d_v == d_k for the test
    rng = np.random.default_rng(2)
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 17)
    L = DeltaNetStepLayout(
        s=0x0000, s_bf16=0x0400, s2_bf16=0x0500,
        qb=0x0600, kb=0x0680, v=0x0700, g=0x0800,
        alpha=0x0900, neg_alpha=0x0910, beta=0x0920,
        u=0x0A00, au=0x0A80, vmt=0x0B00, w=0x0B80, wb=0x0C00,
        outer=0x1000, o=0x1400, sg=0x1480, out=0x1500, d_v=d, d_k=d,
    )
    S = np.zeros((d, d), dtype=np.float32)
    mem.write_f32_vector(VM, L.s, S.reshape(-1))

    for step in range(5):
        q = rng.standard_normal(d).astype(np.float32)
        k = rng.standard_normal(d).astype(np.float32)
        v = rng.standard_normal(d).astype(np.float32)
        g = rng.standard_normal(d).astype(np.float32)
        alpha = np.float32(rng.uniform(0.7, 0.99))
        beta = np.float32(rng.uniform(0.2, 0.8))
        q_n = q / np.linalg.norm(q)
        k_n = k / np.linalg.norm(k)

        mem.write_u16_matrix(VM, L.qb, float32_to_bf16(q_n).reshape(1, -1))
        mem.write_u16_matrix(VM, L.kb, float32_to_bf16(k_n).reshape(1, -1))
        mem.write_f32_vector(VM, L.v, v)
        mem.write_f32_vector(VM, L.g, g)
        mem.write_f32_vector(VM, L.alpha, np.array([alpha], np.float32))
        mem.write_f32_vector(VM, L.neg_alpha, np.array([-alpha], np.float32))
        mem.write_f32_vector(VM, L.beta, np.array([beta], np.float32))

        _run(mem, gated_deltanet_step_program(L))
        got = mem.read_f32_vector(VM, L.out, d)

        S, ref = _deltanet_ref_step(S, k_n, q_n, v, alpha, beta, g)
        np.testing.assert_allclose(got, ref, rtol=1e-2, atol=2e-2,
                                   err_msg=f"deltanet step {step} output mismatch")

    # final state in VMEM matches the reference recurrence
    got_S = mem.read_f32_vector(VM, L.s, d * d).reshape(d, d)
    np.testing.assert_allclose(got_S, S, rtol=1e-2, atol=2e-2)
