import pytest

from virtual_tpu.isa import AddressSpace, ISAError, Instruction, MemoryRef, Opcode, dma_copy, unpack_dma_flags


def test_instruction_roundtrip() -> None:
    instr = Instruction(
        opcode=Opcode.MATMUL.value,
        flags=0x09,
        target=0x10,
        reserved=0,
        dst=0x0200,
        src0=0x0000,
        src1=0x0100,
        imm0=16,
        imm1=16,
        imm2=16,
    )
    assert Instruction.decode(instr.encode()) == instr
    assert Instruction.from_bytes(instr.to_bytes()) == instr
    assert Instruction.from_hex(instr.to_hex()) == instr


def test_field_boundaries_are_checked() -> None:
    with pytest.raises(ISAError):
        Instruction(opcode=0x100)
    with pytest.raises(ISAError):
        Instruction(opcode=Opcode.NOP.value, dst=0x1_0000)


def test_dma_flags_pack_spaces() -> None:
    instr = dma_copy(
        dst=MemoryRef(AddressSpace.VMEM0, 0x100),
        src=MemoryRef(AddressSpace.HBM, 0x200),
        length=256,
    )
    src, dst = unpack_dma_flags(instr.flags)
    assert src is AddressSpace.HBM
    assert dst is AddressSpace.VMEM0
