from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]


def test_pe_bf16_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[
            REPO / "rtl/primitive/fp32_mul.sv",
            REPO / "rtl/primitive/fp32_add.sv",
            REPO / "rtl/primitive/pe_bf16.sv",
        ],
        hdl_toplevel="pe_bf16",
        build_dir=REPO / "sim_build/pe_bf16",
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel="pe_bf16",
        test_module="test_pe_bf16",
        build_dir=REPO / "sim_build/pe_bf16",
        waves=True,
    )
