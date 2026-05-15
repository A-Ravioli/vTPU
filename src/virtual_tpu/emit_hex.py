from __future__ import annotations

from collections.abc import Sequence

from virtual_tpu.isa import Instruction


def emit_hex(program: Sequence[Instruction]) -> str:
    return "\n".join(instr.to_hex() for instr in program)
