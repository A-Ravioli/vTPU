import numpy as np
import cocotb
from cocotb.clock import Clock

from chip_helpers import (
    COUNTER_BARRIER_WAIT,
    COUNTER_CMEM_ACCESSES,
    COUNTER_DMA_BYTES,
    COUNTER_ERRORS,
    COUNTER_INSTRUCTIONS,
    COUNTER_MXU_ACTIVE,
    COUNTER_REDUCE_ACTIVE,
    COUNTER_TC0_ACTIVE,
    COUNTER_TC0_MXU0_ACTIVE,
    COUNTER_TC0_MXU1_ACTIVE,
    COUNTER_TC0_MXU2_ACTIVE,
    COUNTER_TC0_MXU3_ACTIVE,
    COUNTER_VECTOR_ACTIVE,
    matrix_i32_from_bytes,
    matrix_i8_bytes,
    load_program,
    read_hbm_bytes,
    read_counter,
    reset,
    reset_counters,
    start_and_wait,
    write_hbm_bytes,
)
from virtual_tpu.isa import (
    AddressSpace,
    Instruction,
    MATMUL_FLAG_BF16,
    MemoryRef,
    Opcode,
    ReduceOp,
    UnitMask,
    barrier,
    clear,
    dma_copy,
    halt,
    matmul,
    reduce_op,
)
from virtual_tpu.programs import Matmul16Layout, mlp_single_tile_program, matmul_16_program


async def run_matmul_case(dut, a: np.ndarray, b: np.ndarray) -> None:
    layout = Matmul16Layout()
    await reset(dut)
    await load_program(dut, matmul_16_program(layout))
    await write_hbm_bytes(dut, layout.hbm_a, matrix_i8_bytes(a))
    await write_hbm_bytes(dut, layout.hbm_b, matrix_i8_bytes(b))
    status, error_code = await start_and_wait(dut)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    assert not (status & 0b100), f"unexpected error_code={error_code:#x}"
    payload = await read_hbm_bytes(dut, layout.hbm_c, layout.result_bytes)
    np.testing.assert_array_equal(matrix_i32_from_bytes(payload), a.astype(np.int32) @ b.astype(np.int32))


@cocotb.test()
async def chip_16x16_random_matmul(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = np.random.default_rng(123)
    a = rng.integers(-128, 127, size=(16, 16), dtype=np.int8)
    b = rng.integers(-128, 127, size=(16, 16), dtype=np.int8)
    await run_matmul_case(dut, a, b)


@cocotb.test()
async def chip_16x16_zero_and_identity(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    a = np.arange(256, dtype=np.int16).reshape(16, 16).astype(np.int8)
    await run_matmul_case(dut, a, np.eye(16, dtype=np.int8))
    await run_matmul_case(dut, a, np.zeros((16, 16), dtype=np.int8))


@cocotb.test()
async def chip_16x16_minmax_matmul(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    a = np.full((16, 16), -128, dtype=np.int8)
    b = np.full((16, 16), 127, dtype=np.int8)
    await run_matmul_case(dut, a, b)


@cocotb.test()
async def chip_rejects_unsupported_bf16_flag(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    instr = matmul(dst_addr=0x0200, src_a_addr=0x0000, src_b_addr=0x0100, m=16, n=16, k=16)
    bad = Instruction(
        opcode=Opcode.MATMUL.value,
        flags=instr.flags | MATMUL_FLAG_BF16,
        target=instr.target,
        dst=instr.dst,
        src0=instr.src0,
        src1=instr.src1,
        imm0=instr.imm0,
        imm1=instr.imm1,
        imm2=instr.imm2,
    )
    await load_program(dut, [bad, halt()])
    status, error_code = await start_and_wait(dut)
    assert status & 0b100
    assert error_code != 0


@cocotb.test()
async def chip_rejects_unaligned_dma_without_corrupting_hbm(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    sentinel = (123456).to_bytes(4, byteorder="little", signed=True)
    await write_hbm_bytes(dut, 0x0200, sentinel)
    bad_dma = dma_copy(
        dst=MemoryRef(AddressSpace.VMEM0, 1),
        src=MemoryRef(AddressSpace.HBM, 0),
        length=4,
    )
    await load_program(dut, [bad_dma, halt()])
    status, error_code = await start_and_wait(dut)
    assert status & 0b100
    assert error_code != 0
    assert await read_hbm_bytes(dut, 0x0200, 4) == sentinel


@cocotb.test()
async def chip_tc1_vmem1_matmul(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    layout = Matmul16Layout(hbm_c=0x0800)
    rng = np.random.default_rng(321)
    a = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)
    b = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)
    program = [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_a), src=MemoryRef(AddressSpace.HBM, layout.hbm_a), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_b), src=MemoryRef(AddressSpace.HBM, layout.hbm_b), length=layout.tile_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM1, layout.vmem_c), length=layout.result_bytes),
        matmul(dst_addr=layout.vmem_c, src_a_addr=layout.vmem_a, src_b_addr=layout.vmem_b, m=16, n=16, k=16, target=0x20),
        barrier(UnitMask.MXU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, layout.hbm_c), src=MemoryRef(AddressSpace.VMEM1, layout.vmem_c), length=layout.result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]
    await load_program(dut, program)
    await write_hbm_bytes(dut, layout.hbm_a, matrix_i8_bytes(a))
    await write_hbm_bytes(dut, layout.hbm_b, matrix_i8_bytes(b))
    status, error_code = await start_and_wait(dut)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    payload = await read_hbm_bytes(dut, layout.hbm_c, layout.result_bytes)
    np.testing.assert_array_equal(matrix_i32_from_bytes(payload), a.astype(np.int32) @ b.astype(np.int32))


@cocotb.test()
async def chip_cmem_staged_matmul_and_counters(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await reset_counters(dut)
    layout = Matmul16Layout(hbm_c=0x0C00)
    a = np.eye(16, dtype=np.int8)
    b = np.arange(256, dtype=np.int16).reshape(16, 16).astype(np.int8)
    program = [
        dma_copy(dst=MemoryRef(AddressSpace.CMEM, 0x0000), src=MemoryRef(AddressSpace.HBM, layout.hbm_a), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.CMEM, 0x0100), src=MemoryRef(AddressSpace.HBM, layout.hbm_b), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_a), src=MemoryRef(AddressSpace.CMEM, 0x0000), length=layout.tile_bytes),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_b), src=MemoryRef(AddressSpace.CMEM, 0x0100), length=layout.tile_bytes),
        barrier(UnitMask.DMA),
        clear(dst=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        matmul(dst_addr=layout.vmem_c, src_a_addr=layout.vmem_a, src_b_addr=layout.vmem_b, m=16, n=16, k=16, target=0x1F),
        barrier(UnitMask.MXU),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, layout.hbm_c), src=MemoryRef(AddressSpace.VMEM0, layout.vmem_c), length=layout.result_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]
    await load_program(dut, program)
    await write_hbm_bytes(dut, layout.hbm_a, matrix_i8_bytes(a))
    await write_hbm_bytes(dut, layout.hbm_b, matrix_i8_bytes(b))
    status, error_code = await start_and_wait(dut)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    payload = await read_hbm_bytes(dut, layout.hbm_c, layout.result_bytes)
    np.testing.assert_array_equal(matrix_i32_from_bytes(payload), b.astype(np.int32))
    assert await read_counter(dut, COUNTER_INSTRUCTIONS) == len(program)
    assert await read_counter(dut, COUNTER_DMA_BYTES) == (4 * layout.tile_bytes) + layout.result_bytes
    assert await read_counter(dut, COUNTER_CMEM_ACCESSES) > 0
    assert await read_counter(dut, COUNTER_MXU_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_TC0_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_TC0_MXU0_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_BARRIER_WAIT) > 0
    assert await read_counter(dut, COUNTER_ERRORS) == 0


@cocotb.test()
async def chip_auto_schedules_four_mxus(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await reset_counters(dut)
    tile_bytes = 4
    result_bytes = 16
    hbm_a = 0x1000
    hbm_b = 0x1100
    hbm_c = 0x1200
    program = []
    expected = []

    for tile in range(4):
        vbase = tile * 0x80
        a = np.array([[1 + tile, 2], [3, 4]], dtype=np.int8)
        b = np.array([[5, 6], [7, 8]], dtype=np.int8)
        expected.append(a.astype(np.int32) @ b.astype(np.int32))
        await write_hbm_bytes(dut, hbm_a + (tile * tile_bytes), matrix_i8_bytes(a))
        await write_hbm_bytes(dut, hbm_b + (tile * tile_bytes), matrix_i8_bytes(b))
        program.append(dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vbase), src=MemoryRef(AddressSpace.HBM, hbm_a + (tile * tile_bytes)), length=tile_bytes))
        program.append(dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vbase + 0x10), src=MemoryRef(AddressSpace.HBM, hbm_b + (tile * tile_bytes)), length=tile_bytes))

    program.append(barrier(UnitMask.DMA))
    for tile in range(4):
        vbase = tile * 0x80
        program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, vbase + 0x20), length=result_bytes))
    for tile in range(4):
        vbase = tile * 0x80
        program.append(matmul(dst_addr=vbase + 0x20, src_a_addr=vbase, src_b_addr=vbase + 0x10, m=2, n=2, k=2, target=0x10))
    program.append(barrier(UnitMask.MXU))
    for tile in range(4):
        vbase = tile * 0x80
        program.append(dma_copy(dst=MemoryRef(AddressSpace.HBM, hbm_c + (tile * result_bytes)), src=MemoryRef(AddressSpace.VMEM0, vbase + 0x20), length=result_bytes))
    program.append(barrier(UnitMask.DMA))
    program.append(halt())

    await load_program(dut, program)
    status, error_code = await start_and_wait(dut)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    assert not (status & 0b100), f"unexpected error_code={error_code:#x}"
    for tile in range(4):
        payload = await read_hbm_bytes(dut, hbm_c + (tile * result_bytes), result_bytes)
        observed = np.frombuffer(payload, dtype=np.int32).reshape(2, 2).copy()
        np.testing.assert_array_equal(observed, expected[tile])
    assert await read_counter(dut, COUNTER_TC0_MXU0_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_TC0_MXU1_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_TC0_MXU2_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_TC0_MXU3_ACTIVE) > 0
    assert await read_counter(dut, COUNTER_ERRORS) == 0


@cocotb.test()
async def chip_mlp_vector_datapath(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(456)
    x = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)
    w = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)
    bias = rng.integers(-20, 20, size=(16, 16), dtype=np.int32)
    await load_program(dut, mlp_single_tile_program())
    await write_hbm_bytes(dut, 0x0000, matrix_i8_bytes(x))
    await write_hbm_bytes(dut, 0x0100, matrix_i8_bytes(w))
    await write_hbm_bytes(dut, 0x0200, np.asarray(bias, dtype=np.int32).tobytes())
    status, error_code = await start_and_wait(dut, timeout_cycles=30000)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    payload = await read_hbm_bytes(dut, 0x0600, 16 * 16 * 4)
    np.testing.assert_array_equal(matrix_i32_from_bytes(payload), np.maximum(x.astype(np.int32) @ w.astype(np.int32) + bias, 0))
    assert await read_counter(dut, COUNTER_VECTOR_ACTIVE) > 0


@cocotb.test()
async def chip_reduce_datapath(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    matrix = np.array([[1, -2, 3], [4, 5, -6]], dtype=np.int32)
    program = [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, 0x0000), src=MemoryRef(AddressSpace.HBM, 0x0000), length=matrix.size * 4),
        barrier(UnitMask.DMA),
        reduce_op(dst_addr=0x0040, src_addr=0x0000, length=matrix.size, columns=3, op=ReduceOp.SUM_ROWS),
        barrier(UnitMask.REDUCE),
        reduce_op(dst_addr=0x0080, src_addr=0x0000, length=matrix.size, columns=3, op=ReduceOp.MAX_COLS),
        barrier(UnitMask.REDUCE),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, 0x0100), src=MemoryRef(AddressSpace.VMEM0, 0x0040), length=2 * 4),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, 0x0200), src=MemoryRef(AddressSpace.VMEM0, 0x0080), length=3 * 4),
        barrier(UnitMask.DMA),
        halt(),
    ]
    await load_program(dut, program)
    await write_hbm_bytes(dut, 0x0000, matrix.reshape(-1).astype(np.int32).tobytes())
    status, error_code = await start_and_wait(dut)
    assert status & 0b001, f"expected done, status={status:#x} error_code={error_code:#x}"
    rows = np.frombuffer(await read_hbm_bytes(dut, 0x0100, 8), dtype=np.int32)
    cols = np.frombuffer(await read_hbm_bytes(dut, 0x0200, 12), dtype=np.int32)
    np.testing.assert_array_equal(rows, matrix.sum(axis=1))
    np.testing.assert_array_equal(cols, matrix.max(axis=0))
    assert await read_counter(dut, COUNTER_REDUCE_ACTIVE) > 0
