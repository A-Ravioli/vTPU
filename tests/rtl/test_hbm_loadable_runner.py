import os
from pathlib import Path

import numpy as np
from cocotb_tools.runner import get_runner

from runner_utils import rebuild_enabled, verilator_build_args, waves_enabled
from virtual_tpu.qwen.weights import build_hbm_image


REPO = Path(__file__).resolve().parents[2]


def test_hbm_loadable_cocotb() -> None:
    build_dir = REPO / "sim_build/hbm_loadable"
    build_dir.mkdir(parents=True, exist_ok=True)

    # Build a small bf16 image with the weight converter and write it to disk.
    rng = np.random.default_rng(11)
    tensors = {
        "a": rng.standard_normal((8, 8)).astype(np.float32),
        "b": rng.standard_normal((16,)).astype(np.float32),
    }
    image, _ = build_hbm_image(tensors, align=64)
    image_path = build_dir / "image.bin"
    image_path.write_bytes(image)
    os.environ["HBM_TEST_IMAGE"] = str(image_path)

    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / "rtl/common/vtpu_pkg.sv", REPO / "rtl/memory/hbm_model_loadable.sv"],
        hdl_toplevel="hbm_model_loadable",
        build_dir=build_dir,
        always=rebuild_enabled(),
        waves=waves_enabled(),
        parameters={"HBM_BYTES": 65536, "READ_LATENCY": 2, "WRITE_LATENCY": 2},
        build_args=verilator_build_args(REPO),
    )
    runner.test(
        hdl_toplevel="hbm_model_loadable",
        test_module="test_hbm_loadable",
        build_dir=build_dir,
        test_dir=REPO / "tests/cocotb",
        plusargs=[f"+hbm_image={image_path}"],
        waves=waves_enabled(),
    )
