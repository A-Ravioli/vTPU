from pathlib import Path

from cocotb_tools.runner import get_runner

from test_chip_runner import RTL  # reuse the chip source list

REPO = Path(__file__).resolve().parents[2]


def test_benchmark_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / path for path in RTL],
        hdl_toplevel="virtual_tpu_v4_top",
        build_dir=REPO / "sim_build/chip_bench",
        always=True,
        build_args=["-I" + str(REPO / "rtl/common"), "--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"],
    )
    runner.test(
        hdl_toplevel="virtual_tpu_v4_top",
        test_module="test_benchmark",
        build_dir=REPO / "sim_build/chip_bench",
        test_dir=REPO / "tests/cocotb",
    )
