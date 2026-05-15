from __future__ import annotations

from dataclasses import dataclass

from virtual_tpu.isa import (
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
    hbm_a: int = 0x0000
    hbm_b: int = 0x0100
    hbm_c: int = 0x0200
    vmem_a: int = 0x0000
    vmem_b: int = 0x0100
    vmem_c: int = 0x0200
    tile_bytes: int = 16 * 16
    result_bytes: int = 16 * 16 * 4


def matmul_16_program(layout: Matmul16Layout | None = None) -> list[Instruction]:
    layout = layout or Matmul16Layout()
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
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        matmul(
            dst_addr=layout.vmem_c,
            src_a_addr=layout.vmem_a,
            src_b_addr=layout.vmem_b,
            m=16,
            n=16,
            k=16,
            target=0x10,
            accumulate=False,
        ),
        barrier(UnitMask.MXU),
        dma_copy(
            dst=MemoryRef(AddressSpace.HBM, layout.hbm_c),
            src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c),
            length=layout.result_bytes,
        ),
        barrier(UnitMask.DMA),
        halt(),
    ]


@dataclass(frozen=True)
class TiledMatmulLayout:
    m: int = 64
    n: int = 64
    k: int = 64
    tile: int = 16
    hbm_a: int = 0x0000
    hbm_b: int = 0x2000
    hbm_c: int = 0x4000
    vmem_a: int = 0x0000
    vmem_b: int = 0x0100
    vmem_c: int = 0x0200

    @property
    def a_tile_bytes(self) -> int:
        return self.tile * self.tile

    @property
    def b_tile_bytes(self) -> int:
        return self.tile * self.tile

    @property
    def c_tile_bytes(self) -> int:
        return self.tile * self.tile * 4


def packed_tile_offset(tile_row: int, tile_col: int, tiles_per_row: int, tile_bytes: int, base: int = 0) -> int:
    return base + ((tile_row * tiles_per_row) + tile_col) * tile_bytes


def matmul_tiled_packed_program(layout: TiledMatmulLayout | None = None) -> list[Instruction]:
    """Serial tiled matmul for compiler-managed packed 16x16 HBM tile layout."""

    layout = layout or TiledMatmulLayout()
    if layout.m % layout.tile or layout.n % layout.tile or layout.k % layout.tile:
        raise ValueError("packed tiled MVP requires dimensions to be multiples of tile size")

    program: list[Instruction] = []
    mt = layout.m // layout.tile
    nt = layout.n // layout.tile
    kt = layout.k // layout.tile
    for m_tile in range(mt):
        for n_tile in range(nt):
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.c_tile_bytes))
            for k_tile in range(kt):
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
                        accumulate=k_tile != 0,
                    )
                )
                program.append(barrier(UnitMask.MXU))
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


def mlp_single_tile_program(
    *,
    hbm_x: int = 0x0000,
    hbm_w: int = 0x0100,
    hbm_bias_expanded: int = 0x0200,
    hbm_y: int = 0x0600,
    vmem_x: int = 0x0000,
    vmem_w: int = 0x0100,
    vmem_y: int = 0x0200,
    vmem_bias: int = 0x0600,
) -> list[Instruction]:
    result_bytes = 16 * 16 * 4
    return [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_x), src=MemoryRef(AddressSpace.HBM, hbm_x), length=16 * 16),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_w), src=MemoryRef(AddressSpace.HBM, hbm_w), length=16 * 16),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_bias), src=MemoryRef(AddressSpace.HBM, hbm_bias_expanded), length=result_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, vmem_y), length=result_bytes),
        matmul(dst_addr=vmem_y, src_a_addr=vmem_x, src_b_addr=vmem_w, m=16, n=16, k=16),
        barrier(UnitMask.MXU),
        vector_op(dst_addr=vmem_y, src0_addr=vmem_y, src1_addr=vmem_bias, length=16 * 16, op=VectorOp.VADD),
        barrier(UnitMask.VPU),
        vector_op(dst_addr=vmem_y, src0_addr=vmem_y, length=16 * 16, op=VectorOp.VRELU),
        barrier(UnitMask.VPU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, hbm_y), src=MemoryRef(AddressSpace.VMEM0, vmem_y), length=result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]
