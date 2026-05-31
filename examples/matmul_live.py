#!/usr/bin/env python3
"""Terminal animation of the 16×16 matmul program and MXU K-slices."""

from __future__ import annotations

import sys
import time

import numpy as np

from virtual_tpu.golden import GoldenExecutor
from virtual_tpu.isa import AddressSpace, Opcode
from virtual_tpu.memory import MemorySystem
from virtual_tpu.programs import Matmul16Layout, matmul_16_program

TILE = 16
SLEEP = 0.35


def render_matrix(
    name: str,
    matrix: np.ndarray,
    *,
    highlight_row: int | None = None,
    highlight_col: int | None = None,
) -> str:
    lines = [f"{name} ({matrix.shape[0]}×{matrix.shape[1]}):"]
    for r in range(matrix.shape[0]):
        cells: list[str] = []
        for c in range(matrix.shape[1]):
            value = int(matrix[r, c])
            mark = ""
            if highlight_row is not None and r == highlight_row:
                mark = "^"
            if highlight_col is not None and c == highlight_col:
                mark = "<" if mark else ">"
            cells.append(f"{value:4d}{mark}")
        lines.append(" ".join(cells))
    return "\n".join(lines)


def describe_instruction(pc: int, instr) -> str:
    op = instr.opcode_enum
    if op == Opcode.DMA_COPY:
        return f"PC {pc}: DMA_COPY  src={instr.src0:#06x}  dst={instr.dst:#06x}  len={instr.imm0}"
    if op == Opcode.BARRIER:
        return f"PC {pc}: BARRIER   units=0x{instr.target:02x}"
    if op == Opcode.CLEAR:
        return f"PC {pc}: CLEAR     dst={instr.dst:#06x}  len={instr.imm0}"
    if op == Opcode.MATMUL:
        return (
            f"PC {pc}: MATMUL    m={instr.imm0} n={instr.imm1} k={instr.imm2}  "
            f"A@{instr.src0:#06x} B@{instr.src1:#06x} C@{instr.dst:#06x}"
        )
    if op == Opcode.HALT:
        return f"PC {pc}: HALT"
    return f"PC {pc}: {op.name}"


def mxu_k_frames(a: np.ndarray, b: np.ndarray, c_base: np.ndarray | None):
    acc = np.zeros((TILE, TILE), dtype=np.int64) if c_base is None else c_base.astype(np.int64).copy()
    for k in range(TILE):
        yield ("feed", k, acc.copy())
        for r in range(TILE):
            for c in range(TILE):
                acc[r, c] += int(a[r, k]) * int(b[k, c])
        yield ("capture", k, acc.copy())


def clear_screen() -> None:
    sys.stdout.write("\033[2J\033[H")
    sys.stdout.flush()


def animate_matmul(pc: int, instr, memory: MemorySystem) -> None:
    vmem_a = memory.read_i8_matrix(AddressSpace.VMEM0, instr.src0, TILE, TILE)
    vmem_b = memory.read_i8_matrix(AddressSpace.VMEM0, instr.src1, TILE, TILE)
    c_base = memory.read_i32_matrix(AddressSpace.VMEM0, instr.dst, TILE, TILE) if instr.flags & 0x01 else None
    for phase, k, acc in mxu_k_frames(vmem_a, vmem_b, c_base):
        clear_screen()
        print(describe_instruction(pc, instr))
        print(f"MXU phase: {phase.upper()}   K={k}\n")
        print(render_matrix("A", vmem_a, highlight_col=k))
        print()
        print(render_matrix("B", vmem_b, highlight_row=k))
        print()
        print(render_matrix("C acc", acc.astype(np.int32)))
        time.sleep(SLEEP)


def main() -> None:
    rng = np.random.default_rng(7)
    layout = Matmul16Layout()
    memory = MemorySystem()
    a = rng.integers(-4, 5, size=(TILE, TILE), dtype=np.int8)
    b = rng.integers(-4, 5, size=(TILE, TILE), dtype=np.int8)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_a, a)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_b, b)

    program = matmul_16_program(layout)
    executor = GoldenExecutor(program, memory)

    print("vTPU matmul live — Ctrl+C to stop\n")
    time.sleep(1.0)

    while not executor.halted:
        pc = executor.pc
        instr = program[pc]
        clear_screen()
        print(describe_instruction(pc, instr))
        print()

        if instr.opcode_enum == Opcode.MATMUL:
            animate_matmul(pc, instr, memory)
            executor.step()
            continue

        executor.step()
        time.sleep(SLEEP)

    if executor.error:
        raise SystemExit(executor.error)

    c = memory.read_i32_matrix(AddressSpace.HBM, layout.hbm_c, TILE, TILE)
    expected = a.astype(np.int32) @ b.astype(np.int32)
    np.testing.assert_array_equal(c, expected)
    clear_screen()
    print("Done — HBM C matches NumPy reference matmul.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
