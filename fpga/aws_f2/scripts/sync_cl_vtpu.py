#!/usr/bin/env python3
"""Sync the vTPU F2 CL payload into an AWS FPGA HDK checkout."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
CL_NAME = "cl_vtpu"

RTL_SOURCES = [
    "rtl/common/vtpu_pkg.sv",
    "rtl/common/perf_counters.sv",
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
    "rtl/memory/vmem_top.sv",
    "rtl/memory/cmem_top.sv",
    "rtl/memory/hbm_model.sv",
    "rtl/memory/hbm_model_loadable.sv",
    "rtl/memory/hbm_model_mmap.sv",
    "rtl/memory/dma_engine.sv",
    "rtl/isa/instr_mem.sv",
    "rtl/isa/instr_decoder.sv",
    "rtl/isa/control_fsm.sv",
    "rtl/tensor_core/tensor_core.sv",
    "rtl/top/virtual_tpu_v4_top.sv",
    "rtl/fpga/vtpu_hbm_axi_adapter.sv",
    "rtl/fpga/vtpu_ocl_axil_bridge.sv",
    "rtl/fpga/vtpu_f2_smoke_top.sv",
]

LOCAL_DESIGN_FILES = [
    "fpga/aws_f2/cl_vtpu/design/cl_vtpu.sv",
    "fpga/aws_f2/cl_vtpu/design/cl_vtpu_defines.vh",
]

LOCAL_BUILD_FILES = [
    ("fpga/aws_f2/cl_vtpu/build/scripts/synth_cl_vtpu.tcl", "build/scripts/synth_cl_vtpu.tcl"),
]

AWS_HBM_HELPERS = [
    "cl_dram_dma_pkg.sv",
    "cl_hbm_axi4.sv",
    "cl_hbm_wrapper.sv",
]


def run(cmd: list[str], cwd: Path) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def ensure_cl_dir(examples_dir: Path, cl_dir: Path) -> None:
    if cl_dir.exists():
        return
    creator = examples_dir / "create_new_cl.py"
    if creator.exists():
        run(["python3", str(creator), "--new_cl_name", CL_NAME], cwd=examples_dir)
        return
    template = examples_dir / "CL_TEMPLATE"
    if template.exists():
        shutil.copytree(template, cl_dir)
        return
    cl_dir.mkdir(parents=True)
    (cl_dir / "design").mkdir()
    (cl_dir / "build/scripts").mkdir(parents=True)
    (cl_dir / "software/runtime").mkdir(parents=True)


def copy_sources(aws_fpga_repo: Path, cl_dir: Path) -> None:
    design_dir = cl_dir / "design"
    nested_payload = design_dir / "vtpu"
    if nested_payload.exists():
        shutil.rmtree(nested_payload)

    for stale in ["CL_TEMPLATE.sv", "CL_TEMPLATE_defines.vh", "vtpu_sources.f"]:
        path = design_dir / stale
        if path.exists():
            path.unlink()

    basenames = [Path(src).name for src in RTL_SOURCES]
    dupes = sorted({name for name in basenames if basenames.count(name) > 1})
    if dupes:
        raise SystemExit(f"Cannot flatten RTL sources with duplicate filenames: {', '.join(dupes)}")

    for src in RTL_SOURCES:
        shutil.copy2(REPO / src, design_dir / Path(src).name)

    for src in LOCAL_DESIGN_FILES:
        shutil.copy2(REPO / src, design_dir / Path(src).name)

    hbm_src_dir = aws_fpga_repo / "hdk/cl/examples/cl_dram_hbm_dma/design"
    for helper in AWS_HBM_HELPERS:
        src = hbm_src_dir / helper
        if not src.exists():
            raise SystemExit(f"Missing AWS HBM helper source: {src}")
        shutil.copy2(src, design_dir / helper)

    cl_id_defines = design_dir / "cl_id_defines.vh"
    if not cl_id_defines.exists():
        template_id_defines = aws_fpga_repo / "hdk/cl/examples/CL_TEMPLATE/design/cl_id_defines.vh"
        if not template_id_defines.exists():
            raise SystemExit(f"Missing required cl_id_defines.vh in {design_dir}")
        shutil.copy2(template_id_defines, cl_id_defines)

    manifest = cl_dir / "design" / "vtpu_sources.f"
    manifest.write_text(
        "\n".join(f"$CL_DIR/design/{Path(src).name}" for src in RTL_SOURCES) + "\n",
        encoding="utf-8",
    )
    shutil.copy2(REPO / "fpga/aws_f2/cl_vtpu/design/README.md", cl_dir / "design" / "README.vtpu.md")


def copy_build_scripts(cl_dir: Path) -> None:
    for src, dst in LOCAL_BUILD_FILES:
        dst_path = cl_dir / dst
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / src, dst_path)


def copy_runtime(cl_dir: Path) -> None:
    runtime_src = REPO / "fpga/aws_f2/software/runtime"
    runtime_dst = cl_dir / "software/runtime/vtpu"
    if runtime_dst.exists():
        shutil.rmtree(runtime_dst)
    shutil.copytree(runtime_src, runtime_dst)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aws-fpga-repo", type=Path, default=Path(os.environ.get("AWS_FPGA_REPO_DIR", "")))
    parser.add_argument("--build-dcp", action="store_true", help="Run the HDK DCP build after syncing.")
    parser.add_argument("--create-afi", action="store_true", help="Submit AFI creation after DCP build.")
    parser.add_argument("--s3-bucket", help="S3 bucket for AFI creation.")
    parser.add_argument("--s3-prefix", default="vtpu/cl_vtpu", help="S3 prefix for AFI creation.")
    args = parser.parse_args()

    if not args.aws_fpga_repo:
        raise SystemExit("Set AWS_FPGA_REPO_DIR or pass --aws-fpga-repo")
    examples_dir = args.aws_fpga_repo / "hdk/cl/examples"
    if not examples_dir.exists():
        raise SystemExit(f"Missing AWS HDK examples directory: {examples_dir}")

    cl_dir = examples_dir / CL_NAME
    ensure_cl_dir(examples_dir, cl_dir)
    copy_sources(args.aws_fpga_repo, cl_dir)
    copy_build_scripts(cl_dir)
    copy_runtime(cl_dir)
    print(f"Synced vTPU payload to {cl_dir}")
    print("Installed flattened RTL sources, AWS HBM helper sources, runtime, and synth_cl_vtpu.tcl.")

    if args.build_dcp:
        build_scripts = cl_dir / "build/scripts"
        if not build_scripts.exists():
            raise SystemExit(f"Cannot build DCP: missing {build_scripts}")
        run(["./aws_build_dcp_from_cl.py", "-c", CL_NAME], cwd=build_scripts)

    if args.create_afi:
        if not args.s3_bucket:
            raise SystemExit("--create-afi requires --s3-bucket")
        build_scripts = cl_dir / "build/scripts"
        run(
            [
                "./aws_create_afi.py",
                "-c",
                CL_NAME,
                "--s3_bucket",
                args.s3_bucket,
                "--s3_dcp_key",
                f"{args.s3_prefix}/dcp",
                "--s3_logs_key",
                f"{args.s3_prefix}/logs",
            ],
            cwd=build_scripts,
        )


if __name__ == "__main__":
    main()
