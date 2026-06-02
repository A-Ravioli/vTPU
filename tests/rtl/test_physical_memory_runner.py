from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]
COMMON = [REPO / "rtl/common/vtpu_pkg.sv", REPO / "rtl/physical/physical_memories.sv"]


def test_vmem_top_physical_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=COMMON,
        hdl_toplevel="vmem_top_physical",
        build_dir=REPO / "sim_build/vmem_top_physical",
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common")],
    )
    runner.test(
        hdl_toplevel="vmem_top_physical",
        test_module="test_physical_memories",
        build_dir=REPO / "sim_build/vmem_top_physical",
        test_dir=REPO / "tests/cocotb",
        waves=True,
    )


def test_cmem_top_physical_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=COMMON,
        hdl_toplevel="cmem_top_physical",
        build_dir=REPO / "sim_build/cmem_top_physical",
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common")],
    )
    runner.test(
        hdl_toplevel="cmem_top_physical",
        test_module="test_physical_memories",
        build_dir=REPO / "sim_build/cmem_top_physical",
        test_dir=REPO / "tests/cocotb",
        waves=True,
    )


def test_instr_mem_physical_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=COMMON,
        hdl_toplevel="instr_mem_physical",
        build_dir=REPO / "sim_build/instr_mem_physical",
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common")],
    )
    runner.test(
        hdl_toplevel="instr_mem_physical",
        test_module="test_physical_memories",
        build_dir=REPO / "sim_build/instr_mem_physical",
        test_dir=REPO / "tests/cocotb",
        waves=True,
    )
