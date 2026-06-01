"""Tests for splittable 2x2 systolic array — ISA flag, golden model, and program builder."""
import numpy as np
import pytest

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import (
    MATMUL_FLAG_ACCUMULATE,
    MATMUL_FLAG_SIGNED,
    MATMUL_FLAG_SPLIT_2X2,
    AddressSpace,
    MemoryRef,
    UnitMask,
    barrier,
    clear,
    dma_copy,
    halt,
    split_matmul,
)
from virtual_tpu.memory import MemorySystem
from virtual_tpu.numeric import wrap_i32
from virtual_tpu.programs import SplitMatmul8Layout, split_matmul_8_program


# ---------------------------------------------------------------------------
# ISA encoding round-trip
# ---------------------------------------------------------------------------

def test_split_matmul_flag_encoding() -> None:
    instr = split_matmul(dst_addr=0x0400, src_a_addr=0x0000, src_b_addr=0x0200,
                         m=8, n=8, k=8)
    assert instr.flags & MATMUL_FLAG_SPLIT_2X2
    assert instr.flags & MATMUL_FLAG_SIGNED
    assert instr.imm0 == 8
    assert instr.imm1 == 8
    assert instr.imm2 == 8


def test_split_matmul_rejects_oversized_dimensions() -> None:
    from virtual_tpu.isa import ISAError
    with pytest.raises(ISAError):
        split_matmul(dst_addr=0, src_a_addr=0, src_b_addr=0, m=9, n=8, k=8)
    with pytest.raises(ISAError):
        split_matmul(dst_addr=0, src_a_addr=0, src_b_addr=0, m=8, n=9, k=8)


# ---------------------------------------------------------------------------
# Golden model: single split_matmul instruction
# ---------------------------------------------------------------------------

def _write_four_tiles_i8(memory, space, base_addr, tiles):
    """Write a list of numpy int8 matrices consecutively starting at base_addr."""
    offset = base_addr
    for tile in tiles:
        memory.write_i8_matrix(space, offset, tile)
        offset += tile.size


def _read_four_tiles_i32(memory, space, base_addr, m, n):
    """Read four consecutive int32 m×n matrices starting at base_addr."""
    tiles = []
    offset = base_addr
    for _ in range(4):
        tiles.append(memory.read_i32_matrix(space, offset, m, n))
        offset += m * n * 4
    return tiles


@pytest.mark.parametrize("seed", range(8))
def test_split_matmul_golden_matches_numpy(seed: int) -> None:
    """Four independent 8x8 matmuls via split mode must match NumPy per-partition."""
    rng = np.random.default_rng(seed)
    m, n, k = 8, 8, 8

    a_tiles = [rng.integers(-128, 127, (m, k), dtype=np.int8) for _ in range(4)]
    b_tiles = [rng.integers(-128, 127, (k, n), dtype=np.int8) for _ in range(4)]

    memory = MemorySystem()
    vmem = AddressSpace.VMEM0

    a_base, b_base, c_base = 0x0000, 0x0200, 0x0400
    _write_four_tiles_i8(memory, vmem, a_base, a_tiles)
    _write_four_tiles_i8(memory, vmem, b_base, b_tiles)

    instr = split_matmul(dst_addr=c_base, src_a_addr=a_base, src_b_addr=b_base,
                         m=m, n=n, k=k)
    result = GoldenExecutor([instr, halt()], memory).run()
    assert result.reason is HaltReason.HALT

    actual = _read_four_tiles_i32(memory, vmem, c_base, m, n)
    for p in range(4):
        expected = a_tiles[p].astype(np.int32) @ b_tiles[p].astype(np.int32)
        np.testing.assert_array_equal(actual[p], expected,
                                      err_msg=f"partition {p} mismatch (seed={seed})")


@pytest.mark.parametrize("seed", range(4))
def test_split_matmul_accumulate(seed: int) -> None:
    """ACCUMULATE flag in split mode adds into existing C values."""
    rng = np.random.default_rng(seed)
    m, n, k = 8, 8, 8

    a_tiles = [rng.integers(-128, 127, (m, k), dtype=np.int8) for _ in range(4)]
    b_tiles = [rng.integers(-128, 127, (k, n), dtype=np.int8) for _ in range(4)]
    c_init_tiles = [rng.integers(-256, 256, (m, n), dtype=np.int32) for _ in range(4)]

    memory = MemorySystem()
    vmem = AddressSpace.VMEM0
    a_base, b_base, c_base = 0x0000, 0x0200, 0x0400

    _write_four_tiles_i8(memory, vmem, a_base, a_tiles)
    _write_four_tiles_i8(memory, vmem, b_base, b_tiles)
    # pre-populate C with initial values
    offset = c_base
    for tile in c_init_tiles:
        memory.write_i32_matrix(vmem, offset, tile.astype(np.int64))
        offset += m * n * 4

    instr = split_matmul(dst_addr=c_base, src_a_addr=a_base, src_b_addr=b_base,
                         m=m, n=n, k=k, accumulate=True)
    GoldenExecutor([instr, halt()], memory).run()

    actual = _read_four_tiles_i32(memory, vmem, c_base, m, n)
    for p in range(4):
        expected = wrap_i32(
            c_init_tiles[p].astype(np.int64) +
            a_tiles[p].astype(np.int64) @ b_tiles[p].astype(np.int64)
        )
        np.testing.assert_array_equal(actual[p], expected,
                                      err_msg=f"accumulate partition {p} mismatch")


def test_split_matmul_rejects_m_gt_8_at_runtime() -> None:
    """Golden model halts with ERROR if m > 8 in split mode."""
    from virtual_tpu.isa import Instruction, Opcode

    memory = MemorySystem()
    # Craft a raw instruction with SPLIT_2X2 but m=16 (bypasses the ISA builder check)
    bad = Instruction(
        opcode=Opcode.MATMUL.value,
        flags=MATMUL_FLAG_SIGNED | MATMUL_FLAG_SPLIT_2X2,
        target=0x10,
        dst=0x0400,
        src0=0x0000,
        src1=0x0200,
        imm0=16,  # m=16, too large for split
        imm1=8,
        imm2=8,
    )
    result = GoldenExecutor([bad, halt()], memory).run()
    assert result.reason is HaltReason.ERROR
    assert result.error is not None and "m and n must be <= 8" in result.error


# ---------------------------------------------------------------------------
# Full program flow: split_matmul_8_program
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", range(6))
def test_split_matmul_8_program(seed: int) -> None:
    """End-to-end: HBM -> VMEM -> split matmul -> VMEM -> HBM matches NumPy."""
    rng = np.random.default_rng(seed)
    layout = SplitMatmul8Layout()
    memory = MemorySystem()
    m, n, k = layout.tile_m, layout.tile_n, layout.tile_k

    a_tiles = [rng.integers(-128, 127, (m, k), dtype=np.int8) for _ in range(4)]
    b_tiles = [rng.integers(-128, 127, (k, n), dtype=np.int8) for _ in range(4)]

    _write_four_tiles_i8(memory, AddressSpace.HBM, layout.hbm_a, a_tiles)
    _write_four_tiles_i8(memory, AddressSpace.HBM, layout.hbm_b, b_tiles)

    result = GoldenExecutor(split_matmul_8_program(layout), memory).run()
    assert result.reason is HaltReason.HALT

    actual = _read_four_tiles_i32(memory, AddressSpace.HBM, layout.hbm_c, m, n)
    for p in range(4):
        expected = a_tiles[p].astype(np.int32) @ b_tiles[p].astype(np.int32)
        np.testing.assert_array_equal(actual[p], expected,
                                      err_msg=f"program partition {p} mismatch (seed={seed})")


def test_split_matmul_perf_counter_counts_k_not_4k() -> None:
    """Hardware runs 4 partitions in parallel so active cycles = k, not 4*k."""
    rng = np.random.default_rng(0)
    layout = SplitMatmul8Layout()
    memory = MemorySystem()
    m, n, k = layout.tile_m, layout.tile_n, layout.tile_k

    a_tiles = [rng.integers(-128, 127, (m, k), dtype=np.int8) for _ in range(4)]
    b_tiles = [rng.integers(-128, 127, (k, n), dtype=np.int8) for _ in range(4)]
    _write_four_tiles_i8(memory, AddressSpace.HBM, layout.hbm_a, a_tiles)
    _write_four_tiles_i8(memory, AddressSpace.HBM, layout.hbm_b, b_tiles)

    executor = GoldenExecutor(split_matmul_8_program(layout), memory)
    executor.run()
    assert executor.counters.mxu_active_cycles == k, (
        f"expected {k} active cycles (parallel), got {executor.counters.mxu_active_cycles}"
    )


def test_split_vs_full_utilization() -> None:
    """Illustrate that split mode runs 4x the work in the same cycle budget as one tile."""
    rng = np.random.default_rng(42)
    m, n, k = 8, 8, 8

    # --- full 16x16 matmul on the standard array ---
    from virtual_tpu.programs import Matmul16Layout, matmul_16_program
    layout16 = Matmul16Layout()
    mem16 = MemorySystem()
    a16 = rng.integers(-128, 127, (16, 16), dtype=np.int8)
    b16 = rng.integers(-128, 127, (16, 16), dtype=np.int8)
    mem16.write_i8_matrix(AddressSpace.HBM, layout16.hbm_a, a16)
    mem16.write_i8_matrix(AddressSpace.HBM, layout16.hbm_b, b16)
    ex16 = GoldenExecutor(matmul_16_program(layout16), mem16)
    ex16.run()
    cycles_full = ex16.counters.mxu_active_cycles  # = 16 (k=16)

    # --- four 8x8 matmuls via split array ---
    layout8 = SplitMatmul8Layout()
    mem8 = MemorySystem()
    a_tiles = [rng.integers(-128, 127, (m, k), dtype=np.int8) for _ in range(4)]
    b_tiles = [rng.integers(-128, 127, (k, n), dtype=np.int8) for _ in range(4)]
    _write_four_tiles_i8(mem8, AddressSpace.HBM, layout8.hbm_a, a_tiles)
    _write_four_tiles_i8(mem8, AddressSpace.HBM, layout8.hbm_b, b_tiles)
    ex8 = GoldenExecutor(split_matmul_8_program(layout8), mem8)
    ex8.run()
    cycles_split = ex8.counters.mxu_active_cycles  # = 8 (k=8)

    # 4x the MACs (4 * 8*8*8 = 2048 vs 16*16*16 = 4096) in half the active cycles
    total_macs_full = 16 * 16 * 16
    total_macs_split = 4 * m * n * k
    assert total_macs_split == total_macs_full // 2
    assert cycles_split == cycles_full // 2
