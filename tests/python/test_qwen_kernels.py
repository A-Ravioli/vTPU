import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, halt
from virtual_tpu.memory import MemorySystem
from virtual_tpu.qwen.kernels import (
    RMSNormLayout,
    RopeLayout,
    SoftmaxLayout,
    rmsnorm_program,
    rope_program,
    softmax_program,
)

VM = AddressSpace.VMEM0


def _run(mem, prog):
    res = GoldenExecutor(list(prog) + [halt()], mem).run()
    assert res.reason is HaltReason.HALT, res.error


def test_rmsnorm_kernel():
    H = 16
    rng = np.random.default_rng(0)
    x = rng.standard_normal(H).astype(np.float32)
    w = rng.standard_normal(H).astype(np.float32)
    eps = np.float32(1e-6)
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 16)
    L = RMSNormLayout(x=0x000, w=0x100, y=0x200, inv_h=0x300, eps=0x310,
                      ss=0x320, mean=0x330, denom=0x340, h=H)
    mem.write_f32_vector(VM, L.x, x)
    mem.write_f32_vector(VM, L.w, w)
    mem.write_f32_vector(VM, L.inv_h, np.array([1.0 / H], np.float32))
    mem.write_f32_vector(VM, L.eps, np.array([eps], np.float32))
    _run(mem, rmsnorm_program(L))
    got = mem.read_f32_vector(VM, L.y, H)
    ref = x * (1.0 / np.sqrt((x * x).mean() + eps)) * w
    np.testing.assert_allclose(got, ref, rtol=3e-3, atol=1e-4)


def test_softmax_kernel_causal():
    n = 8
    rng = np.random.default_rng(1)
    scores = (rng.standard_normal(n) * 3).astype(np.float32)
    # causal mask: allow first 5 positions, mask the rest
    keep = 5
    mask = np.where(np.arange(n) < keep, 0.0, -1e30).astype(np.float32)
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 16)
    L = SoftmaxLayout(scores=0x000, mask=0x100, probs=0x200, ones=0x300, neg_one=0x400,
                      s=0x500, mx=0x600, negmx=0x610, shift=0x700, e=0x900, sm=0xA00,
                      rs=0xA10, length=n)
    mem.write_f32_vector(VM, L.scores, scores)
    mem.write_f32_vector(VM, L.mask, mask)
    mem.write_f32_vector(VM, L.ones, np.ones(n, np.float32))
    mem.write_f32_vector(VM, L.neg_one, np.array([-1.0], np.float32))
    _run(mem, softmax_program(L))
    got = mem.read_f32_vector(VM, L.probs, n)
    masked = scores.copy()
    masked[keep:] = -1e30
    ref = np.exp(masked - masked.max())
    ref = ref / ref.sum()
    np.testing.assert_allclose(got, ref, rtol=2e-3, atol=1e-5)
    assert got[keep:].sum() < 1e-6  # masked positions ~0


def test_rope_kernel():
    d = 16
    rng = np.random.default_rng(2)
    x = rng.standard_normal(d).astype(np.float32)
    pos = 3
    inv_freq = 1.0 / (10000 ** (np.arange(0, d, 2) / d))
    ang = pos * inv_freq
    cos = np.concatenate([np.cos(ang), np.cos(ang)]).astype(np.float32)
    sin = np.concatenate([np.sin(ang), np.sin(ang)]).astype(np.float32)
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 16)
    L = RopeLayout(x=0x000, cos=0x100, sin=0x200, out=0x300, rh=0x400, t2=0x500,
                   pos_one=0x600, neg_one=0x610, d=d)
    mem.write_f32_vector(VM, L.x, x)
    mem.write_f32_vector(VM, L.cos, cos)
    mem.write_f32_vector(VM, L.sin, sin)
    mem.write_f32_vector(VM, L.pos_one, np.array([1.0], np.float32))
    mem.write_f32_vector(VM, L.neg_one, np.array([-1.0], np.float32))
    _run(mem, rope_program(L))
    got = mem.read_f32_vector(VM, L.out, d)
    half = d // 2
    rot = np.concatenate([-x[half:], x[:half]])
    ref = x * cos + rot * sin
    np.testing.assert_allclose(got, ref, rtol=2e-3, atol=1e-4)


from virtual_tpu.numeric import bf16_to_float32, float32_to_bf16
from virtual_tpu.qwen.kernels import (
    AttnHeadLayout,
    SwiGLULayout,
    attention_head_program,
    swiglu_program,
)


def _bf(x):
    return bf16_to_float32(float32_to_bf16(np.asarray(x, np.float32)))


def _store_bf16(mem, addr, arr):
    mem.write_u16_matrix(VM, addr, float32_to_bf16(np.asarray(arr, np.float32)).reshape(arr.shape if arr.ndim > 1 else (1, -1)))


def test_swiglu_kernel():
    K, N = 8, 16
    rng = np.random.default_rng(5)
    x = rng.standard_normal(K).astype(np.float32) * 0.5
    Wg = rng.standard_normal((K, N)).astype(np.float32) * 0.3
    Wu = rng.standard_normal((K, N)).astype(np.float32) * 0.3
    Wd = rng.standard_normal((N, K)).astype(np.float32) * 0.3
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 18)
    L = SwiGLULayout(x_bf16=0x0000, wg_bf16=0x0040, wu_bf16=0x0240, wd_bf16=0x0440,
                     gate=0x1000, up=0x1100, h=0x1200, h_bf16=0x1300, out=0x1400, k=K, n=N)
    _store_bf16(mem, L.x_bf16, x)
    _store_bf16(mem, L.wg_bf16, Wg)
    _store_bf16(mem, L.wu_bf16, Wu)
    _store_bf16(mem, L.wd_bf16, Wd)
    _run(mem, swiglu_program(L))
    got = mem.read_f32_vector(VM, L.out, K)
    gate = _bf(x) @ _bf(Wg)
    up = _bf(x) @ _bf(Wu)
    sg = gate * (1.0 / (1.0 + np.exp(-gate)))
    ref = _bf(sg * up) @ _bf(Wd)
    np.testing.assert_allclose(got, ref, rtol=5e-3, atol=1e-3)


def test_attention_head_kernel():
    d, T = 4, 4
    rng = np.random.default_rng(6)
    q = rng.standard_normal(d).astype(np.float32) * 0.5
    Km = rng.standard_normal((T, d)).astype(np.float32) * 0.5
    Vm = rng.standard_normal((T, d)).astype(np.float32) * 0.5
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=1 << 18)
    sm = SoftmaxLayout(scores=0x2000, mask=0x2100, probs=0x2200, ones=0x2300, neg_one=0x2400,
                       s=0x2500, mx=0x2600, negmx=0x2610, shift=0x2700, e=0x2900, sm=0x2A00,
                       rs=0x2A10, length=T)
    L = AttnHeadLayout(q_bf16=0x0000, k_bf16=0x0040, v_bf16=0x0240,
                       probs_bf16=0x0440, ctx=0x0500, sm=sm, d=d, t=T)
    _store_bf16(mem, L.q_bf16, q)
    _store_bf16(mem, L.k_bf16, Km)
    _store_bf16(mem, L.v_bf16, Vm)
    mem.write_f32_vector(VM, sm.mask, np.zeros(T, np.float32))  # full visibility
    mem.write_f32_vector(VM, sm.ones, np.ones(T, np.float32))
    mem.write_f32_vector(VM, sm.neg_one, np.array([-1.0], np.float32))
    _run(mem, attention_head_program(L))
    got = mem.read_f32_vector(VM, L.ctx, d)
    scores = _bf(q) @ _bf(Km).T
    p = np.exp(scores - scores.max()); p = p / p.sum()
    ref = _bf(p) @ _bf(Vm)
    np.testing.assert_allclose(got, ref, rtol=5e-3, atol=1e-3)
