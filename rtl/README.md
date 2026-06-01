# RTL Scope

The RTL in this repository is an educational simplification that follows the early module contracts in `docs/06_RTL_MODULE_CONTRACTS.md`.

Implemented now:

- `vtpu_pkg.sv` common custom ISA and command/status types
- `perf_counters.sv` shared 64-bit MMIO counter block
- `pe_int8.sv` one-cycle signed int8 multiply-accumulate PE
- `systolic_array.sv` command-level tiled int8/int32 matmul block
- `mxu_top.sv` VMEM-backed scalar-scheduled MXU datapath
- `instr_decoder.sv`, `instr_mem.sv`, and `control_fsm.sv` threaded into the executable top
- `vmem_top.sv`, `cmem_top.sv`, `hbm_model.sv`, and `dma_engine.sv` request/response memory path
- `tensor_core.sv`, `vector_unit.sv`, and `reduce_unit.sv` VMEM-connected datapaths with four MXUs per TensorCore
- `virtual_tpu_v4_top.sv` structural chip top with HBM, CMEM, two TensorCores, DMA, control, and counters

The Python golden model is the executable source of truth for full-program behavior. The RTL currently lint-checks under Verilator and has cocotb coverage for PE behavior, the standalone RTL unit matrix, HBM-visible 16x16 matmul, BF16 matmul in simulation, TC1/VMEM1 targeting, CMEM staging, multi-MXU auto-scheduling, MLP-style vector execution, reductions, error handling, and host-readable counters. FP16 and BF16 vector/reduce remain unsupported.
