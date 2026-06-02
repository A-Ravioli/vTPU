from pathlib import Path

from cocotb_tools.runner import get_runner

from runner_utils import rebuild_enabled, waves_enabled


REPO = Path(__file__).resolve().parents[2]
COMMON = [REPO / "rtl/common/vtpu_pkg.sv"]


def test_vmem_top_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=COMMON + [REPO / "rtl/memory/vmem_top.sv"],
        hdl_toplevel="vmem_top",
        build_dir=REPO / "sim_build/vmem_top",
        always=rebuild_enabled(),
        waves=waves_enabled(),
        build_args=["-I" + str(REPO / "rtl/common")],
    )
    runner.test(
        hdl_toplevel="vmem_top",
        test_module="test_banked_memory",
        build_dir=REPO / "sim_build/vmem_top",
        test_dir=REPO / "tests/cocotb",
        waves=waves_enabled(),
    )


def test_cmem_top_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=COMMON + [REPO / "rtl/memory/cmem_top.sv"],
        hdl_toplevel="cmem_top",
        build_dir=REPO / "sim_build/cmem_top",
        always=rebuild_enabled(),
        waves=waves_enabled(),
        build_args=["-I" + str(REPO / "rtl/common")],
    )
    runner.test(
        hdl_toplevel="cmem_top",
        test_module="test_banked_memory",
        build_dir=REPO / "sim_build/cmem_top",
        test_dir=REPO / "tests/cocotb",
        waves=waves_enabled(),
    )
