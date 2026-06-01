# reusable reference programs for the virtual tpu (dma + matmul + barriers + halt)
from __future__ import annotations  # lets us use Matmul16Layout | None before the class is defined

from dataclasses import dataclass

from virtual_tpu.isa import (  # helpers that build Instruction objects for the simulator / rtl
    AddressSpace,
    Instruction,
    MemoryRef,
    UnitMask,
    VectorOp,
    barrier,
    clear,
    dma_copy,
    halt,
    matmul,
    split_matmul,
    vector_op,
)


@dataclass(frozen=True)
class Matmul16Layout:
    """byte offsets for a single 16x16 int8 matmul: where a/b/c live in hbm and vmem."""

    hbm_a: int = 0x0000  # matrix a tile in high-bandwidth memory
    hbm_b: int = 0x0100  # matrix b tile (256 bytes after a)
    hbm_c: int = 0x0200  # output c tile in hbm (int32, so 4x bigger than a/b)
    vmem_a: int = 0x0000  # scratch for a on tensor core 0's local memory
    vmem_b: int = 0x0100
    vmem_c: int = 0x0200
    tile_bytes: int = 16 * 16  # 16x16 int8 = 256 bytes per operand tile
    result_bytes: int = 16 * 16 * 4  # 16x16 int32 = 1024 bytes for c


def matmul_16_program(layout: Matmul16Layout | None = None) -> list[Instruction]:
    """minimal end-to-end 16x16 matmul: hbm -> vmem -> mxu -> hbm."""

    layout = layout or Matmul16Layout()  # default addresses if caller doesn't override
    return [
        # stage operand tiles from slow hbm into fast vmem on tc0
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_a),
            length=layout.tile_bytes,
        ),
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_b),
            length=layout.tile_bytes,
        ),
        barrier(UnitMask.DMA),  # wait until both loads finish
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),  # zero c before matmul
        matmul(
            dst_addr=layout.vmem_c,
            src_a_addr=layout.vmem_a,
            src_b_addr=layout.vmem_b,
            m=16,
            n=16,
            k=16,
            target=0x10,  # tc0 + default mxu0 (see isa target encoding)
            accumulate=False,  # overwrite c, don't add into existing values
        ),
        barrier(UnitMask.MXU),  # matmul is async; sync before reading c
        dma_copy(
            dst=MemoryRef(AddressSpace.HBM, layout.hbm_c),
            src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c),
            length=layout.result_bytes,
        ),
        barrier(UnitMask.DMA),
        halt(),  # stop the program counter
    ]


def cmem_staged_matmul_16_program(layout: Matmul16Layout | None = None) -> list[Instruction]:
    """16x16 matmul with HBM -> CMEM -> VMEM staging for both input tiles."""

    layout = layout or Matmul16Layout()
    cmem_a = 0x0000  # chip-level staging buffer offsets (between hbm and vmem)
    cmem_b = 0x0100
    return [
        # hop 1: pull a and b from hbm into cmem (wider / shared staging)
        dma_copy(dst=MemoryRef(AddressSpace.CMEM, cmem_a), src=MemoryRef(AddressSpace.HBM, layout.hbm_a), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.CMEM, cmem_b), src=MemoryRef(AddressSpace.HBM, layout.hbm_b), length=layout.tile_bytes),
        # hop 2: cmem -> vmem where the mxu actually reads operands
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a), src=MemoryRef(AddressSpace.CMEM, cmem_a), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b), src=MemoryRef(AddressSpace.CMEM, cmem_b), length=layout.tile_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        matmul(
            dst_addr=layout.vmem_c,
            src_a_addr=layout.vmem_a,
            src_b_addr=layout.vmem_b,
            m=16,
            n=16,
            k=16,
            target=0x1F,  # broadcast to all mxus on tc0 (stress / multi-mxu path)
        ),
        barrier(UnitMask.MXU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, layout.hbm_c), src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]


@dataclass(frozen=True)
class SplitOutputMatmulLayout:
    """two different b tiles and two output regions — one matmul per tensor core."""

    hbm_a: int = 0x0000  # shared a tile in hbm
    hbm_b0: int = 0x0100  # b for tc0 / output c0
    hbm_b1: int = 0x0200  # b for tc1 / output c1
    hbm_c0: int = 0x1000  # result for tc0 (spaced apart so tiles don't overlap)
    hbm_c1: int = 0x1400
    vmem_a: int = 0x0000
    vmem_b: int = 0x0100
    vmem_c: int = 0x0200
    tile_bytes: int = 16 * 16
    result_bytes: int = 16 * 16 * 4


def split_output_two_tc_matmul_program(layout: SplitOutputMatmulLayout | None = None) -> list[Instruction]:
    """Compute two independent 16x16 output tiles across TC0/VMEM0 and TC1/VMEM1."""

    layout = layout or SplitOutputMatmulLayout()
    return [
        # same a tile loaded into both tensor cores' vmem
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a), src=MemoryRef(AddressSpace.HBM, layout.hbm_a), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_a), src=MemoryRef(AddressSpace.HBM, layout.hbm_a), length=layout.tile_bytes),
        # different b tiles per tc
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b), src=MemoryRef(AddressSpace.HBM, layout.hbm_b0), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_b), src=MemoryRef(AddressSpace.HBM, layout.hbm_b1), length=layout.tile_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        clear(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_c), length=layout.result_bytes),
        matmul(dst_addr=layout.vmem_c, src_a_addr=layout.vmem_a, src_b_addr=layout.vmem_b, m=16, n=16, k=16, target=0x10),  # tc0
        matmul(dst_addr=layout.vmem_c, src_a_addr=layout.vmem_a, src_b_addr=layout.vmem_b, m=16, n=16, k=16, target=0x20),  # tc1
        barrier(UnitMask.MXU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, layout.hbm_c0), src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, layout.hbm_c1), src=MemoryRef(AddressSpace.VMEM1, layout.vmem_c), length=layout.result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]


@dataclass(frozen=True)
class TiledMatmulLayout:
    """big m×n×k matmul built from 16×16 tiles in a packed hbm layout."""

    m: int = 64
    n: int = 64
    k: int = 64
    tile: int = 16  # hardware/native tile size
    hbm_a: int = 0x0000
    hbm_b: int = 0x2000
    hbm_c: int = 0x4000
    vmem_a: int = 0x0000
    vmem_b: int = 0x0100
    vmem_c: int = 0x0200

    @property
    def a_tile_bytes(self) -> int:
        return self.tile * self.tile  # int8 tile

    @property
    def b_tile_bytes(self) -> int:
        return self.tile * self.tile

    @property
    def c_tile_bytes(self) -> int:
        return self.tile * self.tile * 4  # int32 accumulators per output tile


def packed_tile_offset(tile_row: int, tile_col: int, tiles_per_row: int, tile_bytes: int, base: int = 0) -> int:
    """hbm byte offset for tile (tile_row, tile_col) in row-major packed storage."""

    return base + ((tile_row * tiles_per_row) + tile_col) * tile_bytes


def matmul_tiled_packed_program(layout: TiledMatmulLayout | None = None) -> list[Instruction]:
    """Serial tiled matmul for compiler-managed packed 16x16 HBM tile layout."""

    layout = layout or TiledMatmulLayout()
    if layout.m % layout.tile or layout.n % layout.tile or layout.k % layout.tile:
        raise ValueError("packed tiled MVP requires dimensions to be multiples of tile size")

    program: list[Instruction] = []
    mt = layout.m // layout.tile  # number of output tile rows
    nt = layout.n // layout.tile  # output tile cols
    kt = layout.k // layout.tile  # k-dimension tiles (inner loop for accumulation)
    for m_tile in range(mt):
        for n_tile in range(nt):
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.c_tile_bytes))
            for k_tile in range(kt):
                # a tile at (m_tile, k_tile); b tile at (k_tile, n_tile) — standard blocked matmul
                program.append(
                    dma_copy(
                        dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a),
                        src=MemoryRef(
                            AddressSpace.HBM,
                            packed_tile_offset(m_tile, k_tile, kt, layout.a_tile_bytes, layout.hbm_a),
                        ),
                        length=layout.a_tile_bytes,
                    )
                )
                program.append(
                    dma_copy(
                        dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b),
                        src=MemoryRef(
                            AddressSpace.HBM,
                            packed_tile_offset(k_tile, n_tile, nt, layout.b_tile_bytes, layout.hbm_b),
                        ),
                        length=layout.b_tile_bytes,
                    )
                )
                program.append(barrier(UnitMask.DMA))
                program.append(
                    matmul(
                        dst_addr=layout.vmem_c,
                        src_a_addr=layout.vmem_a,
                        src_b_addr=layout.vmem_b,
                        m=layout.tile,
                        n=layout.tile,
                        k=layout.tile,
                        target=0x10,
                        accumulate=k_tile != 0,  # first k tile overwrites; later ones add (partial sum)
                    )
                )
                program.append(barrier(UnitMask.MXU))
            # one output tile done — write c(m_tile, n_tile) back to hbm
            program.append(
                dma_copy(
                    dst=MemoryRef(
                        AddressSpace.HBM,
                        packed_tile_offset(m_tile, n_tile, nt, layout.c_tile_bytes, layout.hbm_c),
                    ),
                    src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c),
                    length=layout.c_tile_bytes,
                )
            )
            program.append(barrier(UnitMask.DMA))
    program.append(halt())
    return program


@dataclass(frozen=True)
class Matmul128Layout:
    """Byte offsets for a single 128x128 int8 matmul in HBM and VMEM.

    Tile sizes:
      A / B: 128*128 int8 = 16384 bytes each (fits in 16-bit address + length)
      C:     128*128 int32 = 65536 bytes

    ISA note: the MVP instruction format uses 16-bit address and length fields
    (max 65535).  The C result tile is exactly 65536 bytes so it cannot be
    expressed as a single DMA or CLEAR instruction.  matmul_128_program therefore
    loads A/B from HBM, runs the matmul, and leaves C in VMEM; callers that need
    C in HBM should read VMEM directly (test/software path) or implement a tiled
    readback using 32-row strips (each 128*32*4 = 16384 bytes, fits 16 bits).
    """

    hbm_a: int = 0x00000
    hbm_b: int = 0x04000   # 16384 bytes after A
    vmem_a: int = 0x0000
    vmem_b: int = 0x4000   # 16384 bytes after A
    vmem_c: int = 0x8000   # 32768 bytes after A; C spans 0x8000..0x17FFF in VMEM
    tile_bytes: int = 128 * 128        # 16384 bytes per int8 operand tile
    result_bytes: int = 128 * 128 * 4  # 65536 bytes for int32 C (exceeds 16-bit imm0)


def matmul_128_program(layout: Matmul128Layout | None = None) -> list[Instruction]:
    """128x128 int8 matmul: load A/B from HBM into VMEM, run MXU, halt with C in VMEM.

    C is not written back to HBM: the ISA's 16-bit address/length fields cannot
    express the full 65536-byte C tile in a single DMA instruction.  Tests read
    C directly from VMEM via memory.read_i32_matrix(VMEM0, layout.vmem_c, 128, 128).
    """
    layout = layout or Matmul128Layout()
    return [
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_a),
            length=layout.tile_bytes,
        ),
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_b),
            length=layout.tile_bytes,
        ),
        barrier(UnitMask.DMA),
        matmul(
            dst_addr=layout.vmem_c,
            src_a_addr=layout.vmem_a,
            src_b_addr=layout.vmem_b,
            m=128,
            n=128,
            k=128,
            target=0x10,
            accumulate=False,  # C is zeroed implicitly (no CLEAR needed)
        ),
        barrier(UnitMask.MXU),
        halt(),
    ]


@dataclass(frozen=True)
class SplitMatmul8Layout:
    """Memory layout for four concurrent 8x8 int8 matmuls on the split 2x2 array.

    Four independent A, B, C tiles are packed consecutively in HBM and VMEM.
    Tile order: partition 0 (top-left), 1 (top-right), 2 (bottom-left), 3 (bottom-right).
    """

    hbm_a: int = 0x0000   # base of packed A tiles in HBM
    hbm_b: int = 0x0200   # base of packed B tiles (4 * 8*8 = 256 bytes after A)
    hbm_c: int = 0x0400   # base of packed C tiles (4 * 8*8*4 = 1024 bytes after B)
    vmem_a: int = 0x0000
    vmem_b: int = 0x0200
    vmem_c: int = 0x0400
    tile_m: int = 8
    tile_n: int = 8
    tile_k: int = 8
    num_parts: int = 4

    @property
    def a_tile_bytes(self) -> int:
        return self.tile_m * self.tile_k  # int8

    @property
    def b_tile_bytes(self) -> int:
        return self.tile_k * self.tile_n  # int8

    @property
    def c_tile_bytes(self) -> int:
        return self.tile_m * self.tile_n * 4  # int32

    @property
    def total_a_bytes(self) -> int:
        return self.num_parts * self.a_tile_bytes

    @property
    def total_b_bytes(self) -> int:
        return self.num_parts * self.b_tile_bytes

    @property
    def total_c_bytes(self) -> int:
        return self.num_parts * self.c_tile_bytes


def split_matmul_8_program(layout: SplitMatmul8Layout | None = None) -> list[Instruction]:
    """Four independent 8x8x8 int8 matmuls dispatched as a single split 2x2 instruction.

    Demonstrates the split array: four separate A/B pairs are multiplied concurrently,
    producing four separate C results.  The hardware executes all four in parallel with
    the same latency as a single 8x8x8 matmul (k cycles of MAC), not 4x that.

    Memory flow:
      HBM[hbm_a..hbm_a+256] -> VMEM[vmem_a..vmem_a+256]  (4 A tiles, int8)
      HBM[hbm_b..hbm_b+256] -> VMEM[vmem_b..vmem_b+256]  (4 B tiles, int8)
      MATMUL split 2x2  (4 concurrent 8x8x8 matmuls)
      VMEM[vmem_c..vmem_c+1024] -> HBM[hbm_c..hbm_c+1024] (4 C tiles, int32)
    """
    layout = layout or SplitMatmul8Layout()
    return [
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_a),
            length=layout.total_a_bytes,
        ),
        dma_copy(
            dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b),
            src=MemoryRef(AddressSpace.HBM, layout.hbm_b),
            length=layout.total_b_bytes,
        ),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.total_c_bytes),
        split_matmul(
            dst_addr=layout.vmem_c,
            src_a_addr=layout.vmem_a,
            src_b_addr=layout.vmem_b,
            m=layout.tile_m,
            n=layout.tile_n,
            k=layout.tile_k,
            target=0x10,
        ),
        barrier(UnitMask.MXU),
        dma_copy(
            dst=MemoryRef(AddressSpace.HBM, layout.hbm_c),
            src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c),
            length=layout.total_c_bytes,
        ),
        barrier(UnitMask.DMA),
        halt(),
    ]


def multi_mxu_tiled_matmul_program(layout: TiledMatmulLayout | None = None) -> list[Instruction]:
    """Packed tiled matmul using the TC0 all-MXU target mask for each tile command."""

    program = matmul_tiled_packed_program(layout)
    # clone every instruction but widen matmul targets to 0x1f (all mxus on tc0)
    return [
        Instruction(
            opcode=instr.opcode,
            flags=instr.flags,
            target=0x1F if instr.opcode == 0x04 else instr.target,  # 0x04 = Opcode.MATMUL
            reserved=instr.reserved,
            dst=instr.dst,
            src0=instr.src0,
            src1=instr.src1,
            imm0=instr.imm0,
            imm1=instr.imm1,
            imm2=instr.imm2,
        )
        for instr in program
    ]


def mlp_single_tile_program(
    *,
    hbm_x: int = 0x0000,
    hbm_w: int = 0x0100,
    hbm_bias_expanded: int = 0x0200,  # bias broadcast to 16x16 int32 for vadd
    hbm_y: int = 0x0600,
    vmem_x: int = 0x0000,
    vmem_w: int = 0x0100,
    vmem_y: int = 0x0200,
    vmem_bias: int = 0x0600,
) -> list[Instruction]:
    """one 16x16 tile: y = relu(x @ w + bias), then store y to hbm."""

    result_bytes = 16 * 16 * 4
    return [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_x), src=MemoryRef(AddressSpace.HBM, hbm_x), length=16 * 16),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_w), src=MemoryRef(AddressSpace.HBM, hbm_w), length=16 * 16),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_bias), src=MemoryRef(AddressSpace.HBM, hbm_bias_expanded), length=result_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, vmem_y), length=result_bytes),
        matmul(dst_addr=vmem_y, src_a_addr=vmem_x, src_b_addr=vmem_w, m=16, n=16, k=16),  # linear layer
        barrier(UnitMask.MXU),
        vector_op(dst_addr=vmem_y, src0_addr=vmem_y, src1_addr=vmem_bias, length=16 * 16, op=VectorOp.VADD),  # + bias
        barrier(UnitMask.VPU),
        vector_op(dst_addr=vmem_y, src0_addr=vmem_y, length=16 * 16, op=VectorOp.VRELU),  # activation
        barrier(UnitMask.VPU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, hbm_y), src=MemoryRef(AddressSpace.VMEM0, vmem_y), length=result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]
