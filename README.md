# Virtual TPU v4-Inspired Educational Accelerator

This repository contains an educational, public-derived TPU v4-inspired accelerator model. It is not compatible with, or a clone of, proprietary Google TPU internals.

The first implemented milestone is intentionally small:

- custom 128-bit instruction encoding
- Python assembler and golden executor
- simulated HBM/CMEM/VMEM memory spaces
- exact int8 x int8 -> int32 tiled matmul behavior
- vector/reduce golden operations
- bf16/FP32 Python reference path
- packed-tile 64x64 matmul and single-tile MLP lowering examples
- Python 3D mesh/torus architectural simulator
- golden-model performance counters
- SystemVerilog package and initial PE/MXU RTL modules
- pytest-based Python verification
- Verilator lint and cocotb unit-test harness

## Quick Start

```bash
make test-python
make lint
make test-rtl-unit
make all
```

`make lint` requires Verilator. On this machine it was installed with Homebrew stable.

## Demo

Run the Python 16x16 matmul demo:

```bash
PYTHONPATH=src python3 examples/matmul_16.py
```

## Repository Layout

```text
docs/              Design plan and module contracts
src/virtual_tpu/   Python ISA, assembler, memory model, golden executor
compiler/          Compatibility wrappers for the compiler package layout in docs
rtl/               SystemVerilog packages and initial RTL modules
tests/python/      pytest tests for the executable golden contract
tests/cocotb/      cocotb test skeleton for RTL simulation
tests/rtl/         pytest wrapper for cocotb/Verilator tests
examples/          Small runnable programs
```

## Current Scope

The implemented path covers the verified Python roadmap through tiled matmul, vector/reduce, bf16 reference math, MLP lowering, counters, and archsim. The RTL is lint-clean under Verilator and has a cocotb PE test harness, with deeper VMEM-fed MXU/chip data-path tests still to be added.
