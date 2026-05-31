# serialize instruction programs to one hex line per 128-bit word (for rtl / sim dumps)
from __future__ import annotations

from collections.abc import Sequence

from virtual_tpu.isa import Instruction


def emit_hex(program: Sequence[Instruction]) -> str:
    """one 32-char hex string per instruction, newline-separated."""

    return "\n".join(instr.to_hex() for instr in program)
