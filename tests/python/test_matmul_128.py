"""Tests for the 128x128 systolic array program builder and golden model."""
import numpy as np
import pytest

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace
from virtual_tpu.memory import MemorySystem
from virtual_tpu.programs import Matmul128Layout, matmul_128_program


@pytest.mark.parametrize("seed", range(4))
def test_matmul_128_matches_numpy(seed: int) -> None:
    rng = np.random.default_rng(seed)
    layout = Matmul128Layout()
    memory = MemorySystem()

    a = rng.integers(-128, 127, (128, 128), dtype=np.int8)
    b = rng.integers(-128, 127, (128, 128), dtype=np.int8)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_a, a)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_b, b)

    result = GoldenExecutor(matmul_128_program(layout), memory).run()
    assert result.reason is HaltReason.HALT

    actual = memory.read_i32_matrix(AddressSpace.HBM, layout.hbm_c, 128, 128)
    expected = a.astype(np.int32) @ b.astype(np.int32)
    np.testing.assert_array_equal(actual, expected)


def test_matmul_128_layout_fits_in_vmem() -> None:
    layout = Matmul128Layout()
    vmem_size = 256 * 1024  # 256 KB
    end = layout.vmem_c + layout.result_bytes
    assert end <= vmem_size, f"layout overflows VMEM: {end} > {vmem_size}"


def test_matmul_128_perf_counters() -> None:
    rng = np.random.default_rng(0)
    layout = Matmul128Layout()
    memory = MemorySystem()
    a = rng.integers(-128, 127, (128, 128), dtype=np.int8)
    b = rng.integers(-128, 127, (128, 128), dtype=np.int8)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_a, a)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_b, b)

    executor = GoldenExecutor(matmul_128_program(layout), memory)
    executor.run()
    # k=128 active cycles for the matmul
    assert executor.counters.mxu_active_cycles == 128
    # DMA moved 2 A/B tiles in + C tile out (C stored as two 32 KB ops due to 16-bit limit)
    assert executor.counters.dma_bytes == layout.tile_bytes * 2 + layout.result_bytes
