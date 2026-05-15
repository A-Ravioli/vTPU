# RTL Scope

The RTL in this repository is an educational simplification that follows the early module contracts in `docs/06_RTL_MODULE_CONTRACTS.md`.

Implemented now:

- `vtpu_pkg.sv` common custom ISA and command/status types
- `pe_int8.sv` one-cycle signed int8 multiply-accumulate PE
- `systolic_array.sv` command-level tiled int8/int32 matmul block
- `mxu_top.sv` initial MXU wrapper around the tiled array
- `instr_decoder.sv` fixed-width instruction decoder and MVP legality checks
- `instr_mem.sv` and `control_fsm.sv` instruction/control shells
- `vmem_bank.sv`, `vmem_top.sv`, `hbm_model.sv`, and `dma_engine.sv` memory/DMA shells
- `tensor_core.sv`, `vector_unit.sv`, and `reduce_unit.sv` unit routing/status shells
- `virtual_tpu_v4_top.sv` top-level status shell

The Python golden model is the executable source of truth for full-program behavior. The RTL currently lint-checks under Verilator and has a cocotb PE test path; later work should connect byte-accurate VMEM/HBM data paths through the MXU and chip top.
