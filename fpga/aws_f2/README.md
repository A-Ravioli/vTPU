# vTPU AWS F2 Bring-Up

This directory contains the repo-side AWS F2 integration. It intentionally does
not vendor the AWS FPGA HDK; instead, `scripts/sync_cl_vtpu.py` copies the vTPU
customer-logic payload into an existing `$AWS_FPGA_REPO_DIR` checkout on an F2
Developer AMI.

## Local Smoke Simulation

The portable F2-facing wrapper is `rtl/fpga/vtpu_f2_smoke_top.sv`. It exposes:

- OCL-style 32-bit AXI-Lite for the existing vTPU MMIO map.
- One 512-bit AXI4 HBM channel.
- `virtual_tpu_v4_top` with `EXTERNAL_HBM=1`.

Run the local cocotb wrapper test with:

```sh
PYTHONPATH=src:tests/cocotb python3 -m pytest -q tests/rtl/test_f2_smoke_runner.py
```

## Generate and Run the Hardware Smoke Artifact

Generate a deterministic 16x16 int8 matmul artifact:

```sh
PYTHONPATH=src python3 fpga/aws_f2/tools/vtpu_f2_smoke.py --out-dir build/f2_smoke --no-run
```

On an F2 runtime host with the AFI loaded:

```sh
cd fpga/aws_f2/software/runtime
make
sudo ./vtpu_f2_smoke --slot 0 \
  --program ../../../build/f2_smoke/program.hex \
  --a ../../../build/f2_smoke/a.bin \
  --b ../../../build/f2_smoke/b.bin
```

## Sync Into the AWS HDK

On the F2 Developer AMI:

```sh
export AWS_FPGA_REPO_DIR=$HOME/aws-fpga
PYTHONPATH=src python3 fpga/aws_f2/scripts/sync_cl_vtpu.py --build-dcp
```

The script creates or refreshes:

```text
$AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_vtpu
```

It uses the HDK `create_new_cl.py --new_cl_name cl_vtpu` helper when available,
copies a flattened vTPU RTL payload into `design/`, copies the AWS HBM helper
sources from `cl_dram_hbm_dma`, installs `build/scripts/synth_cl_vtpu.tcl`, and
copies the runtime into `software/runtime/vtpu`.

The flattening is intentional: the stock HDK encryption step only picks up
top-level files in the CL `design/` directory.

## Create an AFI

After a DCP build succeeds on the Developer AMI, submit AFI creation:

```sh
PYTHONPATH=src python3 fpga/aws_f2/scripts/sync_cl_vtpu.py \
  --create-afi \
  --s3-bucket "$VTPU_AFI_BUCKET" \
  --s3-prefix vtpu/cl_vtpu
```

When AWS returns the AFI/AGFI, load it on an F2 runtime instance with the AWS
FPGA management tools, then run the smoke runtime from the loaded slot. AFI
creation requires AWS credentials, a writable S3 bucket, and the F2 Developer
AMI HDK/Vivado environment.
