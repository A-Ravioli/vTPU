import json
import os
import time

import cocotb
import numpy as np
from cocotb.clock import Clock

from chip_helpers import (
    COUNTER_BARRIER_WAIT,
    COUNTER_CYCLES,
    COUNTER_DMA_BYTES,
    COUNTER_HBM_STALL,
    COUNTER_INSTRUCTIONS,
    COUNTER_MXU_ACTIVE,
    COUNTER_VMEM_ACCESSES,
    read_counter,
    read_hbm_bytes,
    reset,
    reset_counters,
    start_and_wait,
)


COUNTERS = {
    "cycles": COUNTER_CYCLES,
    "instructions": COUNTER_INSTRUCTIONS,
    "dma_bytes": COUNTER_DMA_BYTES,
    "hbm_stall": COUNTER_HBM_STALL,
    "vmem_accesses": COUNTER_VMEM_ACCESSES,
    "mxu_active": COUNTER_MXU_ACTIVE,
    "barrier_wait": COUNTER_BARRIER_WAIT,
}


def _dtype_itemsize(dtype: str) -> int:
    return 2 if dtype == "bf16" else np.dtype(dtype).itemsize


async def _read_output(dut, run: dict) -> np.ndarray:
    out_meta = run["output"]
    raw = await read_hbm_bytes(dut, int(out_meta["offset"]), int(out_meta["bytes"]))
    return np.frombuffer(raw, dtype=np.dtype(out_meta["dtype"])).reshape(out_meta["shape"]).copy()


def _expected_output(run: dict) -> np.ndarray:
    out_meta = run["output"]
    return np.load(run["expected_npz"])["logits_tile"].reshape(out_meta["shape"])


def _format_executable(run: dict) -> str:
    details = " ".join(
        f"{key}={run['executable_slice'][key]}"
        for key in ("k", "n", "tile", "matmul_instructions", "macs")
        if key in run["executable_slice"]
    )
    return f"{run['executable_slice']['kind']} {details}".rstrip()


def _select_next_token(logits: np.ndarray, selected_logits: list[int]) -> int:
    flat = np.asarray(logits, dtype=np.float32).reshape(-1)
    return int(selected_logits[int(np.argmax(flat))])


@cocotb.test()
async def qwen_inference_preloaded_artifacts(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    run_json = cocotb.plusargs.get("qwen_run_json") or os.environ.get("QWEN_RUN_JSON")
    assert run_json, "pass +qwen_run_json=<path>"
    with open(run_json, "r", encoding="utf-8") as f:
        run = json.load(f)

    await reset(dut)
    manifest_path = run["hbm_image"].removesuffix(".hbm") + ".manifest.json"
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    x_meta = manifest["tensors"]["decode_input_tile"]
    with open(run["hbm_image"], "rb") as f:
        image = f.read()
    input_bytes = int(x_meta["count"]) * _dtype_itemsize(x_meta["dtype"])
    preloaded = await read_hbm_bytes(dut, int(x_meta["offset"]), input_bytes)
    assert preloaded == image[int(x_meta["offset"]): int(x_meta["offset"]) + input_bytes]

    await reset_counters(dut)
    timeout_cycles = int(os.getenv("QWEN_TIMEOUT_CYCLES", "2000000"))
    t0 = time.time()
    autoregressive = run.get("autoregressive")
    expected = _expected_output(run)
    tokens = None

    if autoregressive:
        tokens = list(autoregressive["prompt_tokens"])
        selected_logits = [int(token) for token in run["selected_logits"]]
        for _step in range(int(autoregressive["decode_steps"])):
            status, err = await start_and_wait(dut, timeout_cycles=timeout_cycles)
            assert status & 0b001 and not (status & 0b100), f"status={status:#x} err={err:#x}"
            got = await _read_output(dut, run)
            np.testing.assert_allclose(got, expected, rtol=5e-3, atol=1e-3)
            tokens.append(_select_next_token(got, selected_logits))
        assert tokens == autoregressive["expected_generated_tokens"]
    else:
        status, err = await start_and_wait(dut, timeout_cycles=timeout_cycles)
        assert status & 0b001 and not (status & 0b100), f"status={status:#x} err={err:#x}"

    wall = time.time() - t0

    counters = {name: await read_counter(dut, idx) for name, idx in COUNTERS.items()}
    cps = counters["cycles"] / wall if wall > 0 else float("nan")
    print("\n============= Qwen RTL inference harness =============")
    print(f"  workload      : {run['workload']}")
    print(f"  executable    : {_format_executable(run)}")
    if autoregressive:
        steps = int(autoregressive["decode_steps"])
        print(f"  decode steps  : {steps}")
        print(f"  generated     : {tokens}")
        print(f"  wall/token    : {wall / steps:.3f}s")
    print(f"  wall          : {wall:.3f}s")
    print(f"  sim cycles/sec: {cps:,.0f}")
    for name, value in counters.items():
        print(f"  {name:13s}: {value:,}")
    print("======================================================\n")

    got = await _read_output(dut, run)
    np.testing.assert_allclose(got, expected, rtol=5e-3, atol=1e-3)
