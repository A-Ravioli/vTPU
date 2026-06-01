from pathlib import Path

from cocotb_tools.runner import get_runner


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
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common"), "--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"],
    )
    runner.test(
        hdl_toplevel="systolic_array_bf16",
        test_module="test_systolic_bf16",
        build_dir=REPO / "sim_build/systolic_array_bf16",
        test_dir=REPO / "tests/cocotb",
        waves=True,
    )
