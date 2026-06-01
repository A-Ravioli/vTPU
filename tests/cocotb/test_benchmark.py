import time

import numpy as np
import cocotb
from cocotb.clock import Clock

from chip_helpers import (
    COUNTER_CYCLES,
    load_program,
    matrix_i8_bytes,
    read_counter,
    reset,
    reset_counters,
    start_and_wait,
    write_hbm_bytes,
)
from virtual_tpu.isa import AddressSpace, MemoryRef, UnitMask, barrier, clear, dma_copy, halt, matmul
from virtual_tpu.qwen.runtime import per_token_cost, qwen35_0p8b


def _matmul_bench_program(reps, m, n, k):
    """Load A,B once, then run `reps` matmul tiles (same dst) — isolates per-tile MXU cost."""
    tile = 16 * 16
    prog = [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, 0x0000), src=MemoryRef(AddressSpace.HBM, 0x0000), length=tile),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, 0x0100), src=MemoryRef(AddressSpace.HBM, 0x0100), length=tile),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, 0x0200), length=16 * 16 * 4),
    ]
    for _ in range(reps):
        prog.append(matmul(dst_addr=0x0200, src_a_addr=0x0000, src_b_addr=0x0100, m=m, n=n, k=k))
        prog.append(barrier(UnitMask.MXU))
    prog.append(halt())
    return prog


async def _run_cycles(dut, prog, a, b):
    await reset(dut)
    await load_program(dut, prog)
    await write_hbm_bytes(dut, 0x0000, matrix_i8_bytes(a))
    await write_hbm_bytes(dut, 0x0100, matrix_i8_bytes(b))
    await reset_counters(dut)
    t0 = time.time()
    status, err = await start_and_wait(dut)
    wall = time.time() - t0
    assert status & 0b001 and not (status & 0b100)
    return await read_counter(dut, COUNTER_CYCLES), wall


@cocotb.test()
async def benchmark_parallel_mxu(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = np.random.default_rng(0)
    a = rng.integers(-8, 8, (16, 16), dtype=np.int8)
    b = rng.integers(-8, 8, (16, 16), dtype=np.int8)
    R = 8

    # per-tile cost via difference (cancels fixed DMA/clear overhead)
    c1_full, _ = await _run_cycles(dut, _matmul_bench_program(1, 16, 16, 16), a, b)
    cR_full, wall = await _run_cycles(dut, _matmul_bench_program(R, 16, 16, 16), a, b)
    tile16 = (cR_full - c1_full) / (R - 1)

    c1_dec, _ = await _run_cycles(dut, _matmul_bench_program(1, 1, 16, 16), a, b)
    cR_dec, _ = await _run_cycles(dut, _matmul_bench_program(R, 1, 16, 16), a, b)
    tile_dec = (cR_dec - c1_dec) / (R - 1)

    sim_cps = (cR_full / wall) if wall > 0 else float("nan")

    SCALAR_TILE16 = 4096 * 6.19   # measured previously for the scalar MXU (~25.3k cyc/16^3 tile)

    cfg = qwen35_0p8b()
    cost = per_token_cost(cfg)
    decode_matmul_cyc = cost["matmul_instr"] * tile_dec

    def f(x):
        return f"{x:,.0f}"

    print("\n============= parallel MXU benchmark (chip RTL) =============")
    print(f"  16x16x16 tile (load+compute+store): {f(tile16)} cycles")
    print(f"     vs scalar MXU ~{f(SCALAR_TILE16)} cyc  ->  {SCALAR_TILE16/tile16:.1f}x faster")
    print(f"     effective MACs/cycle = {4096/tile16:.1f}")
    print(f"  1x16x16 decode tile: {f(tile_dec)} cycles  ({256/tile_dec:.2f} MAC/cyc)")
    print(f"  Verilator sim speed: {f(sim_cps)} sim-cycles/sec")
    print(f"\n  Qwen3.5-0.8B decode, matmul-only floor:")
    print(f"     matmul tiles/token = {f(cost['matmul_instr'])}")
    print(f"     matmul cycles/token= {f(decode_matmul_cyc)}")
    print(f"     in Verilator sim   = {decode_matmul_cyc/sim_cps/3600:.1f} hr/token (matmul alone)")
    print(f"  NOTE: single-token decode is memory-bandwidth bound (stream ~1.6GB weights/token);")
    print(f"        the parallel array fixes COMPUTE, not the per-token weight DMA. Tractable")
    print(f"        end-to-end sim needs a smaller model or batched/prefill workloads.")
    print("============================================================\n")
    assert tile16 < SCALAR_TILE16   # the parallel array must beat the scalar engine
