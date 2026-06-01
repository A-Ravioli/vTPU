import time

import numpy as np
import cocotb
from cocotb.clock import Clock

from chip_helpers import (
    COUNTER_CYCLES,
    COUNTER_INSTRUCTIONS,
    COUNTER_MXU_ACTIVE,
    COUNTER_DMA_BYTES,
    load_program,
    matrix_i8_bytes,
    read_counter,
    reset,
    reset_counters,
    start_and_wait,
    write_hbm_bytes,
)
from virtual_tpu.programs import Matmul16Layout, matmul_16_program
from virtual_tpu.qwen.runtime import per_token_cost, qwen35_0p8b


@cocotb.test()
async def benchmark_and_project(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    layout = Matmul16Layout()
    await load_program(dut, matmul_16_program(layout))
    rng = np.random.default_rng(0)
    a = rng.integers(-8, 8, (16, 16), dtype=np.int8)
    b = rng.integers(-8, 8, (16, 16), dtype=np.int8)
    await write_hbm_bytes(dut, layout.hbm_a, matrix_i8_bytes(a))
    await write_hbm_bytes(dut, layout.hbm_b, matrix_i8_bytes(b))
    await reset_counters(dut)

    t0 = time.time()
    status, err = await start_and_wait(dut)
    wall = time.time() - t0
    assert status & 0b001 and not (status & 0b100)

    cycles = await read_counter(dut, COUNTER_CYCLES)
    mxu = await read_counter(dut, COUNTER_MXU_ACTIVE)
    instr = await read_counter(dut, COUNTER_INSTRUCTIONS)
    dma = await read_counter(dut, COUNTER_DMA_BYTES)

    tile_macs = 16 * 16 * 16
    cyc_per_mac = mxu / tile_macs
    sim_cps = cycles / wall if wall > 0 else float("nan")

    cfg = qwen35_0p8b()
    cost = per_token_cost(cfg)
    tok_macs = cost["macs"]
    tok_instr = cost["total_instr"]

    # As-wired scalar MXU: MXU-bound ~ macs * cyc_per_mac
    scalar_cyc_tok = tok_macs * cyc_per_mac
    # Parallel 128x128 array (Phase-2 systolic_array_bf16 scaled): 16384 MAC/cycle, ~50% util
    par_macs_per_cyc = 16384 * 0.5
    par_cyc_tok = tok_macs / par_macs_per_cyc

    def fmt(c):
        return f"{c:,.0f}"

    print("\n================ vTPU throughput benchmark ================")
    print(f"[anchor] 16x16x16 int8 matmul on chip RTL:")
    print(f"   cycles={cycles}  mxu_active={mxu}  instr={instr}  dma_bytes={dma}")
    print(f"   cycles/MAC (scalar MXU) = {cyc_per_mac:.2f}")
    print(f"   Verilator sim speed     = {fmt(sim_cps)} sim-cycles/sec")
    print(f"\n[Qwen3.5-0.8B per-token cost model]")
    print(f"   MACs/token        = {fmt(tok_macs)}  (~{tok_macs/1e9:.2f} GMAC)")
    print(f"   instructions/token= {fmt(tok_instr)}  (matmul={fmt(cost['matmul_instr'])})")
    print(f"\n[Projected decode throughput]")
    for clk_ghz in (1.0,):
        clk = clk_ghz * 1e9
        print(f"  -- as-wired SCALAR MXU --")
        print(f"     cycles/token = {fmt(scalar_cyc_tok)}")
        print(f"     @ {clk_ghz:.0f} GHz ASIC : {clk/scalar_cyc_tok:.4f} tok/s  ({scalar_cyc_tok/clk:.2f} s/tok)")
        print(f"     in Verilator sim : {sim_cps/scalar_cyc_tok*3600:.3f} tok/hour  ({scalar_cyc_tok/sim_cps/3600:.1f} hr/tok)")
        print(f"  -- parallel 128x128 bf16 array (Phase-2 fabric scaled) --")
        print(f"     cycles/token = {fmt(par_cyc_tok)}")
        print(f"     @ {clk_ghz:.0f} GHz ASIC : {clk/par_cyc_tok:.1f} tok/s  ({par_cyc_tok/clk*1e3:.2f} ms/tok)")
        print(f"     in Verilator sim : {sim_cps/par_cyc_tok:.3f} tok/s")
    print("===========================================================\n")

    assert cyc_per_mac > 0 and tok_macs > 0
