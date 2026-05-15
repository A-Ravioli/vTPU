from virtual_tpu.assembler import assemble, emit_hex
from virtual_tpu.isa import AddressSpace, Opcode, unpack_dma_flags


def test_assemble_matmul_program_fragment() -> None:
    program = assemble(
        """
        DMA_COPY dst=VMEM0:0x0000, src=HBM:0x0000, bytes=256
        BARRIER DMA
        CLEAR dst=VMEM0:0x0200, bytes=1024
        MATMUL target=TC0.MXU0, dst=VMEM0:0x0200, src0=VMEM0:0x0000, src1=VMEM0:0x0100, m=16, n=16, k=16
        BARRIER MXU
        HALT
        """
    )
    assert [instr.opcode for instr in program] == [
        Opcode.DMA_COPY.value,
        Opcode.BARRIER.value,
        Opcode.CLEAR.value,
        Opcode.MATMUL.value,
        Opcode.BARRIER.value,
        Opcode.HALT.value,
    ]
    src, dst = unpack_dma_flags(program[0].flags)
    assert src is AddressSpace.HBM
    assert dst is AddressSpace.VMEM0
    assert program[3].target == 0x10
    assert len(emit_hex(program).splitlines()) == len(program)


def test_assembler_symbols() -> None:
    program = assemble(
        "DMA_COPY dst=VMEM0:A0, src=HBM:A, bytes=256",
        symbols={"A0": 0x0000, "A": 0x1000},
    )
    assert program[0].dst == 0
    assert program[0].src0 == 0x1000


def test_assemble_vector_reduce_and_constants() -> None:
    program = assemble(
        """
        A = 0x0000
        B = 0x0040
        C = 0x0080
        VECTOR_OP dst=VMEM0:C, src0=VMEM0:A, src1=VMEM0:B, len=4, op=VADD
        REDUCE dst=VMEM0:C, src=VMEM0:A, len=16, cols=4, op=SUM_ROWS
        """
    )
    assert program[0].imm1 == 0
    assert program[1].imm1 == 2
