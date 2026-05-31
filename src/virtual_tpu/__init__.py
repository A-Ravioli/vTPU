# public package surface: custom isa types for the educational vtpu model
"""Educational TPU v4-inspired model.

This package implements the public-derived, custom ISA and Python golden model
used to verify the first tiny accelerator milestones.
"""

from virtual_tpu.isa import AddressSpace, Instruction, Opcode, ReduceOp, UnitMask, VectorOp

__all__ = [
    "AddressSpace",
    "Instruction",
    "Opcode",
    "ReduceOp",
    "UnitMask",
    "VectorOp",
]
