# vTPU Physical-Design Flow

This directory contains the first physical-design target for the RTL: a reduced
`vtpu_pd_tiny_top` instance intended to shake out synthesis, floorplanning, and
OpenROAD integration before trying to harden the full educational chip top.

## What This Target Is

`rtl/physical/vtpu_pd_tiny_top.sv` wraps `virtual_tpu_v4_top` with scalar IO and
small parameters:

- 2 TensorCores
- 4 MXUs per TensorCore
- 2x2 systolic arrays
- 256 B VMEM per TensorCore
- 256 B CMEM
- 256 B simulated HBM
- 16 instruction words

This is not the final silicon architecture. It is a small hardening target that
lets the tool flow fail quickly and usefully.

## Install Tools

The minimum open-source stack is:

- Verilator, for RTL lint/elaboration
- Yosys, for logic synthesis checks
- OpenROAD-flow-scripts, for synthesis through routed layout
- Sky130 or GF180 PDK support inside OpenROAD-flow-scripts
- KLayout, for viewing final GDS

On macOS, the least painful path is usually a containerized OpenROAD-flow-scripts
setup. Native installs also work, but dependency drift is more common.

## Run The Repo-Side Checks

```sh
make physical-lint
make physical-synth-check
```

`physical-synth-check` uses local Homebrew Yosys. The current vTPU RTL uses
SystemVerilog features that plain Yosys may not parse, so the Docker-backed
check is usually the better match for this project:

```sh
make physical-synth-check-docker
```

The Docker check uses `yosys-slang` from the ORFS image and writes a quick
synthesized Verilog check artifact to `physical/reports/`.

## Run OpenROAD

Point `OPENROAD_FLOW_ROOT` at the `flow` directory inside your
OpenROAD-flow-scripts checkout:

```sh
export OPENROAD_FLOW_ROOT=/path/to/OpenROAD-flow-scripts/flow
make physical-openroad
```

On macOS/Apple Silicon, the recommended path is the official ORFS Docker image:

```sh
export OPENROAD_FLOW_ROOT=/Users/arav/Desktop/Coding/OpenROAD-flow-scripts/flow
make physical-openroad-docker
```

The Docker target uses `openroad/orfs:latest` with `linux/amd64` emulation, mounts
this repo at `/work/vTPU`, and writes ORFS results into the mounted
OpenROAD-flow-scripts `flow` directory.

If Yosys synthesis has already produced `1_2_yosys.v` and only the OpenROAD
database stage failed, resume without repeating the expensive Yosys/ABC step:

```sh
make physical-openroad-synth-odb-docker
make physical-openroad-floorplan-docker
```

The design config lives at:

```text
physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk
```

The tiny target now uses the Sky130 OpenRAM macro bundled with ORFS at:

```text
platforms/sky130ram/sky130_sram_1rw1r_80x64_8
```

`config.mk` loads that macro's LEF, Liberty, and GDS views and uses
`macro_placement.tcl` to place CMEM, VMEM, and instruction-memory macro
instances. HBM remains an external/latency-only physical shell.

The timing constraints live at:

```text
physical/openroad/designs/sky130hd/vtpu_pd_tiny/constraint.sdc
```

## Run The Default Full-Chip Target

`vtpu_pd_full_top` wraps the default educational vTPU scale for a Sky130 HD
physical-design attempt:

- 2 TensorCores
- 4 MXUs per TensorCore
- 16x16 systolic arrays
- 256 KiB VMEM per TensorCore
- 512 KiB CMEM
- 1024 instruction words
- physical SRAM macro adapters enabled

The full target uses the same ORFS Docker setup:

```sh
export OPENROAD_FLOW_ROOT=/Users/arav/Desktop/Coding/OpenROAD-flow-scripts/flow
make physical-full-lint
make physical-full-synth-check-docker
make physical-full-openroad-floorplan-docker
make physical-full-openroad-docker
```

The config lives at:

```text
physical/openroad/designs/sky130hd/vtpu_pd_full/config.mk
```

The macro placement script deterministically places the default memory macro
tiles:

```text
physical/openroad/designs/sky130hd/vtpu_pd_full/macro_placement.tcl
```

This first full-chip target is intentionally oversized and relaxed. The default
memories expand to thousands of Sky130 SRAM macro instances, so initial success
means elaborating, floorplanning, and producing a routed GDS; density and clock
tightening are later iterations.

HBM is not implemented as a 1 MiB on-chip SRAM array in the physical target.
The `PHYSICAL_MEMORIES` path uses a physical-safe latency shell so the first GDS
does not synthesize a large behavioral memory. A real off-chip memory PHY or
pad-level request/response interface is a future integration step.

## Expected First Failures

The first hardening attempts may fail in synthesis or placement because this RTL
still uses behavioral memory arrays. That is normal. The next serious step is to
replace VMEM, CMEM, instruction memory, and the HBM model with SRAM macro
wrappers or external-memory interfaces.

The recommended progression is:

1. Get this tiny target through Yosys elaboration.
2. Get a standard-cell-only toy route, even if memory inference is ugly.
3. Replace memories with explicit SRAM wrappers.
4. Add macro placement.
5. Tighten the clock after the design routes.

Do not start by hardening the full default `virtual_tpu_v4_top`. The memories are
too large for a useful first physical-design loop.
