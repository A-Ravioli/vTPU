from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]
RTL = [
    "rtl/common/vtpu_pkg.sv",
    "rtl/common/perf_counters.sv",
    "rtl/primitive/pe_int8.sv",
    "rtl/mxu/systolic_array.sv",
    "rtl/mxu/mxu_top.sv",
    "rtl/vector/vector_unit.sv",
    "rtl/vector/reduce_unit.sv",
    "rtl/memory/vmem_top.sv",
    "rtl/memory/cmem_top.sv",
    "rtl/memory/hbm_model.sv",
    "rtl/memory/dma_engine.sv",
    "rtl/isa/instr_mem.sv",
    "rtl/isa/instr_decoder.sv",
    "rtl/isa/control_fsm.sv",
    "rtl/tensor_core/tensor_core.sv",
    "rtl/top/virtual_tpu_v4_top.sv",
]


def test_chip_top_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / path for path in RTL],
        hdl_toplevel="virtual_tpu_v4_top",
        build_dir=REPO / "sim_build/chip_top",
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common"), "--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"],
    )
    runner.test(
        hdl_toplevel="virtual_tpu_v4_top",
        test_module="test_chip_top",
        build_dir=REPO / "sim_build/chip_top",
        waves=True,
    )
