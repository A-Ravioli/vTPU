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
