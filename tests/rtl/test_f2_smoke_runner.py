from pathlib import Path

from cocotb_tools.runner import get_runner

from runner_utils import rebuild_enabled, verilator_build_args, waves_enabled
from test_chip_runner import RTL


REPO = Path(__file__).resolve().parents[2]
F2_RTL = RTL + [
    "rtl/fpga/vtpu_hbm_axi_adapter.sv",
    "rtl/fpga/vtpu_ocl_axil_bridge.sv",
    "rtl/fpga/axi512_memory_model.sv",
    "rtl/fpga/vtpu_f2_smoke_top.sv",
    "rtl/fpga/vtpu_f2_smoke_sim_top.sv",
]


def test_f2_smoke_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / path for path in F2_RTL],
        hdl_toplevel="vtpu_f2_smoke_sim_top",
        build_dir=REPO / "sim_build/f2_smoke",
        always=rebuild_enabled(),
        waves=waves_enabled(),
        build_args=verilator_build_args(REPO),
    )
    runner.test(
        hdl_toplevel="vtpu_f2_smoke_sim_top",
        test_module="test_f2_smoke",
        build_dir=REPO / "sim_build/f2_smoke",
        test_dir=REPO / "tests/cocotb",
        waves=waves_enabled(),
    )

