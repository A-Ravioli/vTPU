from pathlib import Path

from cocotb_tools.runner import get_runner

from runner_utils import rebuild_enabled, verilator_build_args, waves_enabled


REPO = Path(__file__).resolve().parents[2]


def test_systolic_array_bf16_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[
            REPO / "rtl/common/vtpu_pkg.sv",
            REPO / "rtl/primitive/fp32_mul.sv",
            REPO / "rtl/primitive/fp32_add.sv",
            REPO / "rtl/primitive/pe_bf16.sv",
            REPO / "rtl/mxu/systolic_array_bf16.sv",
        ],
        hdl_toplevel="systolic_array_bf16",
        build_dir=REPO / "sim_build/systolic_array_bf16",
        always=rebuild_enabled(),
        waves=waves_enabled(),
        build_args=verilator_build_args(REPO),
    )
    runner.test(
        hdl_toplevel="systolic_array_bf16",
        test_module="test_systolic_bf16",
        build_dir=REPO / "sim_build/systolic_array_bf16",
        test_dir=REPO / "tests/cocotb",
        waves=waves_enabled(),
    )
