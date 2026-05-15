from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]


def test_pe_int8_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / "rtl/primitive/pe_int8.sv"],
        hdl_toplevel="pe_int8",
        build_dir=REPO / "sim_build/pe_int8",
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel="pe_int8",
        test_module="test_pe_int8",
        build_dir=REPO / "sim_build/pe_int8",
        waves=True,
    )
