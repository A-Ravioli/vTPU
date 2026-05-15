import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, ReduceOp, VectorOp, halt, reduce_op, vector_op
from virtual_tpu.memory import MemorySystem


def test_vector_add_and_relu() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    a = np.array([-3, 2, -1, 7], dtype=np.int32)
    b = np.array([1, 5, 9, -10], dtype=np.int32)
    memory.write_i32_vector(AddressSpace.VMEM0, 0, a)
    memory.write_i32_vector(AddressSpace.VMEM0, 32, b)

    program = [
        vector_op(dst_addr=64, src0_addr=0, src1_addr=32, length=4, op=VectorOp.VADD),
        vector_op(dst_addr=96, src0_addr=64, length=4, op=VectorOp.VRELU),
        halt(),
    ]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.HALT
    np.testing.assert_array_equal(memory.read_i32_vector(AddressSpace.VMEM0, 64, 4), a + b)
    np.testing.assert_array_equal(memory.read_i32_vector(AddressSpace.VMEM0, 96, 4), np.maximum(a + b, 0))


def test_reduce_sum_rows_and_max_cols() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    matrix = np.array([[1, -2, 3], [4, 5, -6]], dtype=np.int32)
    memory.write_i32_vector(AddressSpace.VMEM0, 0, matrix.reshape(-1))
    program = [
        reduce_op(dst_addr=64, src_addr=0, length=6, columns=3, op=ReduceOp.SUM_ROWS),
        reduce_op(dst_addr=96, src_addr=0, length=6, columns=3, op=ReduceOp.MAX_COLS),
        halt(),
    ]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.HALT
    np.testing.assert_array_equal(memory.read_i32_vector(AddressSpace.VMEM0, 64, 2), matrix.sum(axis=1))
    np.testing.assert_array_equal(memory.read_i32_vector(AddressSpace.VMEM0, 96, 3), matrix.max(axis=0))
