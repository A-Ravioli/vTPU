from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]


def run_unit(name: str, sources: list[str], extra_args: list[str] | None = None) -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[REPO / path for path in sources],
        hdl_toplevel=name,
        build_dir=REPO / f"sim_build/{name}",
        always=True,
        waves=True,
        build_args=["-I" + str(REPO / "rtl/common"), "--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"] + (extra_args or []),
    )
    runner.test(
        hdl_toplevel=name,
        test_module="test_unit_matrix",
        build_dir=REPO / f"sim_build/{name}",
        test_dir=REPO / "tests/cocotb",
        waves=True,
    )


def test_systolic_array_cocotb() -> None:
    run_unit(
        "systolic_array",
        [
            "rtl/common/vtpu_pkg.sv",
            "rtl/primitive/pe_int8.sv",
            "rtl/mxu/systolic_array.sv",
        ],
    )


def test_mxu_top_cocotb() -> None:
    run_unit(
        "mxu_top",
        [
            "rtl/common/vtpu_pkg.sv",
            "rtl/primitive/pe_int8.sv",
            "rtl/primitive/fp32_mul.sv",
            "rtl/primitive/fp32_add.sv",
            "rtl/primitive/pe_bf16.sv",
            "rtl/mxu/systolic_array.sv",
            "rtl/mxu/systolic_array_bf16.sv",
            "rtl/mxu/mxu_top.sv",
        ],
    )


_FP = [
    "rtl/primitive/fp32_mul.sv",
    "rtl/primitive/fp32_add.sv",
    "rtl/primitive/fp32_recip.sv",
    "rtl/primitive/fp32_rsqrt.sv",
    "rtl/primitive/fp32_exp.sv",
]


def test_vector_unit_cocotb() -> None:
    run_unit("vector_unit", ["rtl/common/vtpu_pkg.sv"] + _FP + ["rtl/vector/vector_unit.sv"])


def test_reduce_unit_cocotb() -> None:
    run_unit("reduce_unit", ["rtl/common/vtpu_pkg.sv"] + _FP + ["rtl/vector/reduce_unit.sv"])


def test_hbm_model_cocotb() -> None:
    run_unit("hbm_model", ["rtl/common/vtpu_pkg.sv", "rtl/memory/hbm_model.sv"])


def test_dma_engine_cocotb() -> None:
    run_unit("dma_engine", ["rtl/common/vtpu_pkg.sv", "rtl/memory/dma_engine.sv"])


def test_instr_decoder_cocotb() -> None:
    run_unit("instr_decoder", ["rtl/common/vtpu_pkg.sv", "rtl/isa/instr_decoder.sv"])


def test_control_fsm_cocotb() -> None:
    run_unit("control_fsm", ["rtl/common/vtpu_pkg.sv", "rtl/isa/control_fsm.sv"])


def test_tensor_core_cocotb() -> None:
    run_unit(
        "tensor_core",
        [
            "rtl/common/vtpu_pkg.sv",
            "rtl/memory/vmem_top.sv",
            "rtl/primitive/pe_int8.sv",
            "rtl/primitive/fp32_mul.sv",
            "rtl/primitive/fp32_add.sv",
            "rtl/primitive/fp32_recip.sv",
            "rtl/primitive/fp32_rsqrt.sv",
            "rtl/primitive/fp32_exp.sv",
            "rtl/primitive/pe_bf16.sv",
            "rtl/mxu/systolic_array.sv",
            "rtl/mxu/systolic_array_bf16.sv",
            "rtl/mxu/mxu_top.sv",
            "rtl/vector/vector_unit.sv",
            "rtl/vector/reduce_unit.sv",
            "rtl/tensor_core/tensor_core.sv",
        ],
    )
