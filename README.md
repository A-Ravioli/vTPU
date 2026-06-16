# Virtual TPU v4-Inspired Educational Accelerator

This repository builds an open, educational accelerator inspired by public TPU v4 architecture.

The guiding question is simple:

```text
How do we execute matrix-heavy ML workloads efficiently enough that data movement,
memory locality, parallelism, and verification all become first-class design choices?
```

This repo answers that question by building a small, inspectable machine from first principles: a Python executable contract, a custom ISA, a simulated memory hierarchy, and SystemVerilog RTL that follows the same behavior.

## Quick Start

```bash
make test-python
make lint
make test-rtl-unit
make test-rtl-integration
```

Run the Python 16x16 matmul demo:

```bash
PYTHONPATH=src python3 examples/matmul_16.py
```

Run the local Qwen/vTPU chip-sim demo UI:

```bash
make qwen-demo-ui
```

`make lint` requires Verilator. The Python tests require the package dependencies declared in [pyproject.toml](pyproject.toml).

## The Machine In One Picture

```text
Host / testbench / MMIO
        |
        v
Instruction memory -> decoder -> control FSM
        |                         |
        |                         v
        |                  DMA + barriers
        |                         |
        v                         v
Simulated HBM <----------> CMEM <----------> VMEM0 / VMEM1
                                                |
                                                v
                                      TensorCore local units
                                      MXU + vector + reduce
                                                |
                                                v
                                      results copied back to HBM
```

The top-level RTL version of this shape lives in [rtl/top/virtual_tpu_v4_top.sv](rtl/top/virtual_tpu_v4_top.sv). The Python version of the same execution contract lives in [src/virtual_tpu/golden.py](src/virtual_tpu/golden.py).

## From First Principles To Architecture

### 1. Dense matmul is the center of gravity

Modern ML workloads spend much of their time multiplying large tensors. If the core operation is:

```text
C = A @ B
```

then the machine should make that operation cheap, predictable, and easy to tile. The smallest end-to-end program in this repo is a 16x16 int8 matmul in [examples/matmul_16.py](examples/matmul_16.py), with reusable program construction in [src/virtual_tpu/programs.py](src/virtual_tpu/programs.py).

### 2. A systolic MXU exploits reuse

A matrix multiply reuses each element of `A` and `B` many times. A systolic array turns that reuse into local movement: `A` streams across one dimension, `B` streams across the other, and processing elements accumulate partial sums. This model uses an output-stationary dataflow because it is teachable, deterministic, and easy to verify before scaling.

The RTL compute path is split across [rtl/primitive/pe_int8.sv](rtl/primitive/pe_int8.sv), [rtl/mxu/systolic_array.sv](rtl/mxu/systolic_array.sv), and [rtl/mxu/mxu_top.sv](rtl/mxu/mxu_top.sv). The architectural rationale is in [docs/02_ARCHITECTURE.md](docs/02_ARCHITECTURE.md).

### 3. VMEM keeps tiles close to compute

If every multiply fetched from global memory, arithmetic units would mostly wait. So each TensorCore gets local VMEM, and matmul instructions operate on VMEM addresses. HBM is for bulk tensor storage; VMEM is for the active working set.

The Python memory contract is in [src/virtual_tpu/memory.py](src/virtual_tpu/memory.py). The banked RTL VMEM implementation is in [rtl/memory/vmem_top.sv](rtl/memory/vmem_top.sv) and [rtl/memory/vmem_bank.sv](rtl/memory/vmem_bank.sv).

### 4. DMA makes movement explicit

Accelerators are not just arithmetic engines. They are orchestration machines. This design uses explicit DMA instructions and barriers because the program should say when data moves, when compute may begin, and when results are safe to read.

The DMA and memory model are specified in [docs/05_MEMORY_AND_DMA.md](docs/05_MEMORY_AND_DMA.md), encoded in [src/virtual_tpu/isa.py](src/virtual_tpu/isa.py), executed by [src/virtual_tpu/golden.py](src/virtual_tpu/golden.py), and implemented in RTL in [rtl/memory/dma_engine.sv](rtl/memory/dma_engine.sv).

### 5. CMEM stages shared chip-level data

TPU v4 public documentation describes TensorCore-local VMEM and chip-level CMEM. This educational model keeps that distinction: VMEM is local to a TensorCore, while CMEM can stage data shared across TensorCores. CMEM exists because not every useful data movement is directly HBM-to-local; some programs need a chip-level scratchpad between bulk memory and compute.

See the CMEM-staged matmul program in [src/virtual_tpu/programs.py](src/virtual_tpu/programs.py) and the RTL shared memory in [rtl/memory/cmem_top.sv](rtl/memory/cmem_top.sv).

### 6. TensorCores and MXUs expose parallel work

The full v4-inspired shape has two TensorCores and four MXUs per TensorCore. The educational RTL keeps the structure visible while using small 16x16 arrays for tractable simulation. Target masks in the ISA select TensorCore-local VMEM spaces and eligible MXUs, which lets simple programs grow toward multi-unit scheduling without changing the core mental model.

The target field is documented in [docs/03_ISA.md](docs/03_ISA.md), modeled by `target` handling in [src/virtual_tpu/golden.py](src/virtual_tpu/golden.py), and wired through [rtl/tensor_core/tensor_core.sv](rtl/tensor_core/tensor_core.sv).

### 7. Vector and reduce units handle the work around matmul

Real tensor programs need more than matmul: elementwise operations, reductions, clamps, activations, and accumulation patterns all matter. This repo includes vector and reduce instructions so the architecture can express the non-MXU parts of simple ML kernels.

The operation names live in [src/virtual_tpu/isa.py](src/virtual_tpu/isa.py). The Python semantics are in [src/virtual_tpu/golden.py](src/virtual_tpu/golden.py). The RTL units are [rtl/vector/vector_unit.sv](rtl/vector/vector_unit.sv) and [rtl/vector/reduce_unit.sv](rtl/vector/reduce_unit.sv).

### 8. A custom ISA keeps the contract inspectable

The ISA is intentionally not a TPU ISA. It is a small educational instruction format:

```text
127:120 opcode
119:112 flags
111:104 target
103:096 reserved
095:080 dst
079:064 src0
063:048 src1
047:032 imm0
031:016 imm1
015:000 imm2
```

Instructions are fixed 128-bit words because decode clarity matters more than code density in this project. The format is spacious enough to keep memory spaces, target masks, dimensions, and operation modes visible to readers.

Read the ISA spec in [docs/03_ISA.md](docs/03_ISA.md), the Python encoding in [src/virtual_tpu/isa.py](src/virtual_tpu/isa.py), the assembler in [src/virtual_tpu/assembler.py](src/virtual_tpu/assembler.py), and the RTL decoder in [rtl/isa/instr_decoder.sv](rtl/isa/instr_decoder.sv).

### 9. Numerics start exact, then broaden

The first implemented compute path is int8 inputs with int32 accumulation because exact integer behavior makes verification crisp. BF16/FP32 matmul also runs in the Python reference path and in RTL simulation: BF16 operands are stored as raw 16-bit values, expanded to FP32 for accumulation, and written back as FP32 results. FP16 and BF16 vector/reduce paths are intentionally out of scope for now.

The numeric plan is in [docs/04_NUMERICS.md](docs/04_NUMERICS.md), and the Python helpers are in [src/virtual_tpu/numeric.py](src/virtual_tpu/numeric.py).

### 10. The golden model defines behavior before RTL

RTL should implement a checked contract, not vibes. The Python golden executor runs the same instruction stream against the same memory-space model and produces the expected architectural result. Tests compare programs to NumPy and use cocotb/Verilator to check RTL behavior against the contract.

The development method is described in [docs/07_VERIFICATION_DRIVEN_DEVELOPMENT.md](docs/07_VERIFICATION_DRIVEN_DEVELOPMENT.md). Python tests live in [tests/python](tests/python). RTL/cocotb tests live in [tests/cocotb](tests/cocotb) and are launched through [tests/rtl](tests/rtl).

## Read The Repo Like A Machine

Follow one 16x16 matmul from user intent to hardware-shaped execution:

1. [examples/matmul_16.py](examples/matmul_16.py) creates random `A` and `B`, writes them to simulated HBM, runs a program, and checks `C` against NumPy.
2. [src/virtual_tpu/programs.py](src/virtual_tpu/programs.py) builds that program: DMA `A` and `B` into VMEM, barrier, clear `C`, issue `MATMUL`, barrier, DMA `C` back to HBM, halt.
3. [src/virtual_tpu/isa.py](src/virtual_tpu/isa.py) turns those operations into fixed-width instructions with explicit address spaces, flags, targets, and dimensions.
4. [src/virtual_tpu/golden.py](src/virtual_tpu/golden.py) executes the instructions against [src/virtual_tpu/memory.py](src/virtual_tpu/memory.py), including DMA behavior, matmul semantics, barriers, errors, and counters.
5. [rtl/top/virtual_tpu_v4_top.sv](rtl/top/virtual_tpu_v4_top.sv) wires the hardware-shaped version: instruction memory, decoder, control FSM, DMA, HBM model, CMEM, two TensorCores, VMEM, MXUs, vector/reduce units, and counters.
6. [tests/python/test_golden.py](tests/python/test_golden.py) checks the golden model. [tests/rtl/test_chip_runner.py](tests/rtl/test_chip_runner.py) launches chip-level RTL tests that compare HBM-visible results and MMIO counters.

That path is the heart of the repo: a program is data movement plus local compute plus synchronization, and every layer is inspectable.

## What Works Today

- Custom 128-bit instruction encoding.
- Python assembler and golden executor.
- Simulated HBM, CMEM, VMEM0, and VMEM1 memory spaces.
- Exact int8 x int8 -> int32 tiled matmul behavior.
- Vector and reduce golden operations.
- BF16/FP32 Python reference path and RTL-simulation matmul path.
- Packed-tile 64x64 matmul and single-tile MLP lowering examples.
- Python 3D mesh/torus architectural simulator.
- Structured tiny-target layout search with JSONL experiment logs and OpenROAD fragments.
- Golden-model performance counters.
- Structural SystemVerilog chip top with instruction, control, memory, DMA, TensorCore, MXU, vector, reduce, and counter modules.
- RTL CMEM/VMEM0/VMEM1/HBM data movement.
- TC0/TC1 target-local execution, target masks, and MMIO counters.
- pytest-based Python verification.
- Verilator lint and cocotb unit-test harness.

BF16 matmul is supported in RTL simulation; FP16 and BF16 vector/reduce remain unsupported.

## Repository Layout

```text
docs/              Design specs, public contract, module contracts, and development plan
src/virtual_tpu/   Python ISA, assembler, memory model, golden executor, lowering, archsim
compiler/          Compatibility wrappers for the compiler package layout in docs
rtl/               SystemVerilog packages and RTL modules
tests/python/      pytest tests for the executable golden contract
tests/cocotb/      cocotb tests for RTL simulation
tests/rtl/         pytest wrappers for cocotb/Verilator tests
examples/          Small runnable programs
```

## Where To Go Next

- Architecture: [docs/02_ARCHITECTURE.md](docs/02_ARCHITECTURE.md)
- ISA: [docs/03_ISA.md](docs/03_ISA.md)
- Numerics: [docs/04_NUMERICS.md](docs/04_NUMERICS.md)
- Memory and DMA: [docs/05_MEMORY_AND_DMA.md](docs/05_MEMORY_AND_DMA.md)
- RTL module contracts: [docs/06_RTL_MODULE_CONTRACTS.md](docs/06_RTL_MODULE_CONTRACTS.md)
- Verification-driven development: [docs/07_VERIFICATION_DRIVEN_DEVELOPMENT.md](docs/07_VERIFICATION_DRIVEN_DEVELOPMENT.md)
- Test plan: [docs/08_TEST_PLAN.md](docs/08_TEST_PLAN.md)
- Compiler and assembler: [docs/10_COMPILER_ASSEMBLER.md](docs/10_COMPILER_ASSEMBLER.md)
- Example programs: [docs/11_EXAMPLE_PROGRAMS.md](docs/11_EXAMPLE_PROGRAMS.md)
- Multi-chip archsim: [docs/12_ARCHSIM_MULTI_CHIP.md](docs/12_ARCHSIM_MULTI_CHIP.md)
- Layout search: [docs/13_LAYOUT_SEARCH.md](docs/13_LAYOUT_SEARCH.md)

## Development Philosophy

The project follows a verification-first loop:

```text
public contract -> spec -> golden model -> tests -> RTL -> RTL tests -> docs
```

Every architectural decision should be legible, every educational simplification should be labeled, and every implemented behavior should have a test or a clear path toward one.
