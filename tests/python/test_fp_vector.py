import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import (
    AddressSpace,
    ReduceOp,
    VectorOp,
    halt,
    reduce_op,
    vector_op,
)
from virtual_tpu.memory import MemorySystem


def _run(program):
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=8192)
    res = GoldenExecutor(list(program) + [halt()], mem).run()
    assert res.reason is HaltReason.HALT, res.error
    return mem


def test_fp_elementwise_ops():
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=8192)
    n = 8
    a = np.linspace(-3, 3, n).astype(np.float32)
    b = np.linspace(2, -2, n).astype(np.float32)
    mem.write_f32_vector(AddressSpace.VMEM0, 0x000, a)
    mem.write_f32_vector(AddressSpace.VMEM0, 0x100, b)
    prog = [
        vector_op(dst_addr=0x200, src0_addr=0x000, src1_addr=0x100, length=n, op=VectorOp.FADD),
        vector_op(dst_addr=0x300, src0_addr=0x000, src1_addr=0x100, length=n, op=VectorOp.FMUL),
        vector_op(dst_addr=0x400, src0_addr=0x000, length=n, op=VectorOp.FSILU),
        vector_op(dst_addr=0x500, src0_addr=0x000, length=n, op=VectorOp.FSIGMOID),
        halt(),
    ]
    GoldenExecutor(prog, mem).run()
    np.testing.assert_allclose(mem.read_f32_vector(AddressSpace.VMEM0, 0x200, n), a + b, rtol=1e-6)
    np.testing.assert_allclose(mem.read_f32_vector(AddressSpace.VMEM0, 0x300, n), a * b, rtol=1e-6)
    sig = 1.0 / (1.0 + np.exp(-a))
    np.testing.assert_allclose(mem.read_f32_vector(AddressSpace.VMEM0, 0x400, n), a * sig, rtol=1e-5)
    np.testing.assert_allclose(mem.read_f32_vector(AddressSpace.VMEM0, 0x500, n), sig, rtol=1e-5)


def test_fp_rmsnorm_primitives():
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=8192)
    n = 16
    x = np.random.default_rng(0).standard_normal(n).astype(np.float32)
    mem.write_f32_vector(AddressSpace.VMEM0, 0x000, x)
    prog = [
        reduce_op(dst_addr=0x100, src_addr=0x000, length=n, op=ReduceOp.FSUMSQ_ALL),
        halt(),
    ]
    GoldenExecutor(prog, mem).run()
    got = mem.read_f32_vector(AddressSpace.VMEM0, 0x100, 1)[0]
    np.testing.assert_allclose(got, (x * x).sum(), rtol=1e-5)


def test_fp_softmax_rows():
    mem = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=8192)
    rows, cols = 3, 4
    m = np.random.default_rng(1).standard_normal((rows, cols)).astype(np.float32)
    mem.write_f32_vector(AddressSpace.VMEM0, 0x000, m.reshape(-1))
    prog = [
        reduce_op(dst_addr=0x200, src_addr=0x000, length=rows * cols, op=ReduceOp.FMAX_ROWS, columns=cols),
        halt(),
    ]
    GoldenExecutor(prog, mem).run()
    got = mem.read_f32_vector(AddressSpace.VMEM0, 0x200, rows)
    np.testing.assert_allclose(got, m.max(axis=1), rtol=1e-6)
