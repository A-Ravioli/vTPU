# Layout Search

The layout search package is a fast architectural floorplan proxy. It does not
replace OpenROAD placement, routing, DRC, or timing closure. Its job is to make
macro-region experiments cheap before a full physical-design run.

Run the tiny target search:

```sh
PYTHONPATH=src python3 -m virtual_tpu.layout --target tiny --iters 500 --seed 1
```

Run the default full-chip target search:

```sh
PYTHONPATH=src python3 -m virtual_tpu.layout --target full --iters 500 --seed 1
```

Each run writes:

- `run_seed<N>.jsonl`, with every scored candidate.
- `best_seed<N>.json`, with the best structured floorplan.
- `best_seed<N>.mk`, with OpenROAD-style die/core hints and block comments.

For `vtpu_pd_full`, the search models aggregate regions: control, DMA,
instruction memory, CMEM, each TensorCore VMEM, each TensorCore compute region,
and the external HBM interface side. The exact per-SRAM macro placement for GDS
lives in:

```text
physical/openroad/designs/sky130hd/vtpu_pd_full/macro_placement.tcl
```

The first full-chip floorplan is intentionally oversized. Default-scale vTPU
contains thousands of Sky130 SRAM macro instances, so routeability is the first
goal; density and clock tightening should happen only after a complete routed
layout exists.
