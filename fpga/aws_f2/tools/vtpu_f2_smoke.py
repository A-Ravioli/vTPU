#!/usr/bin/env python3
"""Generate and optionally run the F2 16x16 int8 matmul smoke workload."""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import numpy as np

from virtual_tpu.emit_hex import emit_hex
from virtual_tpu.programs import Matmul16Layout, matmul_16_program


def write_artifact(out_dir: Path, seed: int) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    a = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)
    b = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)
    c = a.astype(np.int32) @ b.astype(np.int32)
    layout = Matmul16Layout()
    program = matmul_16_program(layout)

    (out_dir / "program.hex").write_text(emit_hex(program) + "\n", encoding="utf-8")
    (out_dir / "a.bin").write_bytes(a.tobytes(order="C"))
    (out_dir / "b.bin").write_bytes(b.tobytes(order="C"))
    (out_dir / "expected.bin").write_bytes(c.astype(np.int32).tobytes(order="C"))
    run = {
        "program": str(out_dir / "program.hex"),
        "a": str(out_dir / "a.bin"),
        "b": str(out_dir / "b.bin"),
        "expected": str(out_dir / "expected.bin"),
        "layout": {
            "hbm_a": layout.hbm_a,
            "hbm_b": layout.hbm_b,
            "hbm_c": layout.hbm_c,
            "tile_bytes": layout.tile_bytes,
            "result_bytes": layout.result_bytes,
        },
        "seed": seed,
        "instructions": len(program),
    }
    (out_dir / "run.json").write_text(json.dumps(run, indent=2) + "\n", encoding="utf-8")
    return run


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=Path("build/f2_smoke"))
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--runtime-bin", type=Path, default=Path("fpga/aws_f2/software/runtime/vtpu_f2_smoke"))
    parser.add_argument("--slot", type=int, default=0)
    parser.add_argument("--no-run", action="store_true")
    args = parser.parse_args()

    run = write_artifact(args.out_dir, args.seed)
    print(json.dumps(run, indent=2))

    if args.no_run:
        return
    cmd = [
        str(args.runtime_bin),
        "--slot",
        str(args.slot),
        "--program",
        run["program"],
        "--a",
        run["a"],
        "--b",
        run["b"],
    ]
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()

