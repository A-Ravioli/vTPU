import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, Instruction, MemoryRef, dma_copy, halt
from virtual_tpu.memory import MemorySystem


def test_dma_32bit_addresses_roundtrip():
    """DMA through HBM/VMEM byte offsets well beyond the old 16-bit (64 KB) limit."""
    mem = MemorySystem(hbm_bytes=8 * 1024 * 1024, cmem_bytes=4096, vmem_bytes=256 * 1024)
    payload = np.arange(64, dtype=np.int32).tobytes()  # 256 bytes
    src_hbm = 0x0030_0000   # 3 MB into HBM (needs high addr bits)
    dst_hbm = 0x0050_0000   # 5 MB
    vmem = 0x0002_0000      # 128 KB into VMEM (> 64 KB)
    mem.write(AddressSpace.HBM, src_hbm, payload)

    prog = [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem), src=MemoryRef(AddressSpace.HBM, src_hbm), length=len(payload)),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, dst_hbm), src=MemoryRef(AddressSpace.VMEM0, vmem), length=len(payload)),
        halt(),
    ]
    res = GoldenExecutor(prog, mem).run()
    assert res.reason is HaltReason.HALT, res.error
    assert mem.read(AddressSpace.HBM, dst_hbm, len(payload)) == payload


def test_dma_high_bits_encoded_in_imm():
    instr = dma_copy(
        dst=MemoryRef(AddressSpace.VMEM0, 0x0002_0004),
        src=MemoryRef(AddressSpace.HBM, 0x0031_0008),
        length=256,
    )
    # low halves in dst/src0, high halves in imm1/imm2
    assert instr.dst == 0x0004 and instr.imm1 == 0x0002
    assert instr.src0 == 0x0008 and instr.imm2 == 0x0031
    # round-trips through encode/decode
    assert Instruction.decode(instr.encode()) == instr
