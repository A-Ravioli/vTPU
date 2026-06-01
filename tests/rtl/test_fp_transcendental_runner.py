from pathlib import Path

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]


def test_fp_transcendental_cocotb() -> None:
    runner = get_runner("verilator")
    runner.build(
        sources=[
            REPO / "rtl/primitive/fp32_mul.sv",
            REPO / "rtl/primitive/fp32_add.sv",
            REPO / "rtl/primitive/fp32_recip.sv",
            REPO / "rtl/primitive/fp32_rsqrt.sv",
            REPO / "rtl/primitive/fp32_exp.sv",
            REPO / "rtl/primitive/fp_trans_probe.sv",
        ],
        hdl_toplevel="fp_trans_probe",
        build_dir=REPO / "sim_build/fp_trans_probe",
        always=True,
        waves=False,
        build_args=["--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"],
    )
    runner.test(
        hdl_toplevel="fp_trans_probe",
        test_module="test_fp_transcendental",
        build_dir=REPO / "sim_build/fp_trans_probe",
        test_dir=REPO / "tests/cocotb",
        waves=False,
    )
