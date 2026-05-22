import numpy as np
import pytest

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, MemoryRef, clear, dma_copy, halt, matmul
from virtual_tpu.memory import MemorySystem
from virtual_tpu.programs import Matmul16Layout, matmul_16_program


@pytest.mark.parametrize("seed", range(10))
def test_full_16x16_matmul_program_matches_numpy(seed: int) -> None:
    rng = np.random.default_rng(seed)
    layout = Matmul16Layout()
    memory = MemorySystem()
    a = rng.integers(-128, 127, size=(16, 16), dtype=np.int8)
    b = rng.integers(-128, 127, size=(16, 16), dtype=np.int8)

    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_a, a)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_b, b)

    result = GoldenExecutor(matmul_16_program(layout), memory).run()
    assert result.reason is HaltReason.HALT
    actual = memory.read_i32_matrix(AddressSpace.HBM, layout.hbm_c, 16, 16)
    expected = a.astype(np.int32) @ b.astype(np.int32)
    np.testing.assert_array_equal(actual, expected)


def test_performance_counters_track_demo_program() -> None:
    layout = Matmul16Layout()
    memory = MemorySystem()
    executor = GoldenExecutor(matmul_16_program(layout), memory)
    result = executor.run()
    assert result.reason is HaltReason.HALT
    assert executor.counters.instructions_retired == len(matmul_16_program(layout))
    assert executor.counters.dma_bytes == (2 * layout.tile_bytes) + layout.result_bytes
    assert executor.counters.mxu_active_cycles == 16


def test_matmul_accumulate_flag_accumulates_existing_c() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    a = np.ones((2, 2), dtype=np.int8)
    b = np.full((2, 2), 3, dtype=np.int8)
    c = np.full((2, 2), 5, dtype=np.int32)
    memory.write_i8_matrix(AddressSpace.VMEM0, 0, a)
    memory.write_i8_matrix(AddressSpace.VMEM0, 16, b)
    memory.write_i32_matrix(AddressSpace.VMEM0, 32, c)

    program = [
        matmul(dst_addr=32, src_a_addr=0, src_b_addr=16, m=2, n=2, k=2, accumulate=True),
        halt(),
    ]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.HALT
    np.testing.assert_array_equal(memory.read_i32_matrix(AddressSpace.VMEM0, 32, 2, 2), c + (a.astype(np.int32) @ b.astype(np.int32)))


def test_matmul_accumulate_wraps_like_int32() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    memory.write_i8_matrix(AddressSpace.VMEM0, 0, np.array([[100]], dtype=np.int8))
    memory.write_i8_matrix(AddressSpace.VMEM0, 4, np.array([[100]], dtype=np.int8))
    memory.write_i32_matrix(AddressSpace.VMEM0, 8, np.array([[2_147_483_600]], dtype=np.int32))

    program = [
        matmul(dst_addr=8, src_a_addr=0, src_b_addr=4, m=1, n=1, k=1, accumulate=True),
        halt(),
    ]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.HALT
    expected = np.array([[((2_147_483_600 + 10_000 + 2**31) % 2**32) - 2**31]], dtype=np.int32)
    np.testing.assert_array_equal(memory.read_i32_matrix(AddressSpace.VMEM0, 8, 1, 1), expected)


def test_matmul_broadcast_target_updates_both_tensor_core_vmems() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    a0 = np.array([[1, 2], [3, 4]], dtype=np.int8)
    b0 = np.array([[5, 6], [7, 8]], dtype=np.int8)
    a1 = np.array([[2, 0], [1, -1]], dtype=np.int8)
    b1 = np.array([[3, 4], [5, 6]], dtype=np.int8)
    memory.write_i8_matrix(AddressSpace.VMEM0, 0, a0)
    memory.write_i8_matrix(AddressSpace.VMEM0, 16, b0)
    memory.write_i8_matrix(AddressSpace.VMEM1, 0, a1)
    memory.write_i8_matrix(AddressSpace.VMEM1, 16, b1)

    program = [matmul(dst_addr=32, src_a_addr=0, src_b_addr=16, m=2, n=2, k=2, target=0x30), halt()]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.HALT
    np.testing.assert_array_equal(memory.read_i32_matrix(AddressSpace.VMEM0, 32, 2, 2), a0.astype(np.int32) @ b0.astype(np.int32))
    np.testing.assert_array_equal(memory.read_i32_matrix(AddressSpace.VMEM1, 32, 2, 2), a1.astype(np.int32) @ b1.astype(np.int32))


def test_illegal_unaligned_dma_errors_without_corruption() -> None:
    memory = MemorySystem(hbm_bytes=64, cmem_bytes=64, vmem_bytes=64)
    memory.write(AddressSpace.HBM, 0, b"abcdef")
    program = [
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, 1),
            src=MemoryRef(AddressSpace.HBM, 0),
            length=4,
        )
    ]
    result = GoldenExecutor(program, memory).run()
    assert result.reason is HaltReason.ERROR
    assert memory.read(AddressSpace.VMEM0, 0, 4) == b"\x00\x00\x00\x00"


def test_clear_zeroes_region() -> None:
    memory = MemorySystem(hbm_bytes=64, cmem_bytes=64, vmem_bytes=64)
    memory.write(AddressSpace.VMEM0, 0, b"x" * 16)
    result = GoldenExecutor([clear(dst=MemoryRef(AddressSpace.VMEM0, 0), length=16), halt()], memory).run()
    assert result.reason is HaltReason.HALT
    assert memory.read(AddressSpace.VMEM0, 0, 16) == b"\x00" * 16
