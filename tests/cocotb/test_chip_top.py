import numpy as np
import cocotb
from cocotb.clock import Clock

from chip_helpers import (
    matrix_i32_from_bytes,
    matrix_i8_bytes,
    load_program,
    read_hbm_bytes,
    reset,
    start_and_wait,
    write_hbm_bytes,
)
from virtual_tpu.isa import AddressSpace, Instruction, MATMUL_FLAG_BF16, MemoryRef, Opcode, dma_copy, halt, matmul
from virtual_tpu.programs import Matmul16Layout, matmul_16_program


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
