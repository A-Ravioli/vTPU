import os
from pathlib import Path

from cocotb_tools.runner import get_runner

from runner_utils import rebuild_enabled, verilator_build_args, waves_enabled
from test_chip_runner import RTL
from virtual_tpu.qwen.rtl_artifacts import build_qwen_infer_artifacts


REPO = Path(__file__).resolve().parents[2]


def test_qwen_inference_cocotb() -> None:
    workload = os.getenv("QWEN_WORKLOAD", "tiny")
    mxu_dim = int(os.getenv("QWEN_MXU_DIM", "16"))
    instr_depth = int(os.getenv("QWEN_INSTR_DEPTH", "4096"))
    build_dir = REPO / "sim_build/qwen_infer" / workload
    run = build_qwen_infer_artifacts(build_dir, workload)
    os.environ["QWEN_RUN_JSON"] = str(build_dir / "run.json")

    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / path for path in RTL],
        hdl_toplevel="virtual_tpu_v4_top",
        build_dir=build_dir,
        always=rebuild_enabled(),
        waves=waves_enabled(),
        parameters={
            "SIM_MMAP_HBM": 1,
            "HBM_BYTES": int(run["hbm_bytes"]),
            "INSTR_DEPTH": max(instr_depth, int(run.get("program_instructions", 0)) + 16),
            "ARRAY_M": mxu_dim,
            "ARRAY_N": mxu_dim,
            "ARRAY_K": mxu_dim,
        },
        build_args=verilator_build_args(REPO, optimize=True),
    )
    runner.test(
        hdl_toplevel="virtual_tpu_v4_top",
        test_module="test_qwen_inference",
        build_dir=build_dir,
        test_dir=REPO / "tests/cocotb",
        plusargs=[
            f"+hbm_mmap={run['hbm_image']}",
            f"+instr_hex={run['program_hex']}",
            f"+qwen_run_json={build_dir / 'run.json'}",
        ],
        waves=waves_enabled(),
    )
