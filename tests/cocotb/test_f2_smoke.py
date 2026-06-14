import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from chip_helpers import (
    COUNTER_BASE,
    HBM_BASE,
    INSTR_BASE,
    REG_CONTROL,
    REG_ERROR_CODE,
    REG_STATUS,
    matrix_i32_from_bytes,
    matrix_i8_bytes,
)
from virtual_tpu.programs import Matmul16Layout, matmul_16_program


async def reset(dut, cycles: int = 4) -> None:
    dut.rst_n.value = 0
    dut.s_ocl_awaddr.value = 0
    dut.s_ocl_awvalid.value = 0
    dut.s_ocl_wdata.value = 0
    dut.s_ocl_wstrb.value = 0
    dut.s_ocl_wvalid.value = 0
    dut.s_ocl_bready.value = 1
    dut.s_ocl_araddr.value = 0
    dut.s_ocl_arvalid.value = 0
    dut.s_ocl_rready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def axil_write(dut, addr: int, value: int, wstrb: int = 0xF) -> int:
    dut.s_ocl_awaddr.value = addr
    dut.s_ocl_wdata.value = value
    dut.s_ocl_wstrb.value = wstrb
    dut.s_ocl_awvalid.value = 1
    dut.s_ocl_wvalid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.s_ocl_awready.value), f"AXI-Lite AW not ready addr={addr:#x}"
    assert int(dut.s_ocl_wready.value), f"AXI-Lite W not ready addr={addr:#x}"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    dut.s_ocl_awvalid.value = 0
    dut.s_ocl_wvalid.value = 0
    for _ in range(200):
        if int(dut.s_ocl_bvalid.value):
            break
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    assert int(dut.s_ocl_bvalid.value), f"AXI-Lite write timed out addr={addr:#x}"
    resp = int(dut.s_ocl_bresp.value)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    return resp


async def axil_read(dut, addr: int) -> tuple[int, int]:
    dut.s_ocl_araddr.value = addr
    dut.s_ocl_arvalid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.s_ocl_arready.value), f"AXI-Lite AR not ready addr={addr:#x}"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    dut.s_ocl_arvalid.value = 0
    for _ in range(200):
        if int(dut.s_ocl_rvalid.value):
            break
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    assert int(dut.s_ocl_rvalid.value), f"AXI-Lite read timed out addr={addr:#x}"
    value = int(dut.s_ocl_rdata.value)
    resp = int(dut.s_ocl_rresp.value)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    return value, resp


async def write_bytes(dut, base: int, payload: bytes) -> None:
    padded = payload + b"\x00" * ((4 - (len(payload) % 4)) % 4)
    for offset in range(0, len(padded), 4):
        word = int.from_bytes(padded[offset: offset + 4], byteorder="little")
        assert await axil_write(dut, base + offset, word) == 0


async def read_bytes(dut, base: int, length: int) -> bytes:
    chunks = []
    padded_len = length + ((4 - (length % 4)) % 4)
    for offset in range(0, padded_len, 4):
        word, resp = await axil_read(dut, base + offset)
        assert resp == 0
        chunks.append(word.to_bytes(4, byteorder="little"))
    return b"".join(chunks)[:length]


async def load_program(dut, program) -> None:
    for pc, instr in enumerate(program):
        encoded = instr.encode()
        for lane in range(4):
            word = (encoded >> (lane * 32)) & 0xFFFFFFFF
            assert await axil_write(dut, INSTR_BASE + (pc * 16) + (lane * 4), word) == 0


async def start_and_wait(dut, timeout_cycles: int = 50000) -> None:
    assert await axil_write(dut, REG_CONTROL, 1) == 0
    for _ in range(timeout_cycles):
        status, resp = await axil_read(dut, REG_STATUS)
        assert resp == 0
        if status & 0x4:
            code, _ = await axil_read(dut, REG_ERROR_CODE)
            raise AssertionError(f"vTPU error status={status:#x} code={code:#x}")
        if (status & 0x1) and not (status & 0x2):
            return
        await RisingEdge(dut.clk)
    raise AssertionError("timed out waiting for F2 smoke wrapper")


@cocotb.test()
async def f2_ocl_registers_and_hbm_window(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    status, resp = await axil_read(dut, REG_STATUS)
    assert resp == 0
    assert status == 0

    payload = bytes(range(96))
    await write_bytes(dut, HBM_BASE + 0x40, payload)
    got = await read_bytes(dut, HBM_BASE + 0x40, len(payload))
    assert got == payload

    _, counter_resp = await axil_read(dut, COUNTER_BASE)
    assert counter_resp == 0
    assert await axil_write(dut, HBM_BASE + 1, 0x1234) != 0


@cocotb.test()
async def f2_external_hbm_matmul_smoke(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    assert await axil_write(dut, REG_CONTROL, 2) == 0
    layout = Matmul16Layout()
    rng = np.random.default_rng(2026)
    a = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)
    b = rng.integers(-16, 16, size=(16, 16), dtype=np.int8)

    await load_program(dut, matmul_16_program(layout))
    await write_bytes(dut, HBM_BASE + layout.hbm_a, matrix_i8_bytes(a))
    await write_bytes(dut, HBM_BASE + layout.hbm_b, matrix_i8_bytes(b))
    await start_and_wait(dut)

    raw = await read_bytes(dut, HBM_BASE + layout.hbm_c, layout.result_bytes)
    np.testing.assert_array_equal(matrix_i32_from_bytes(raw), a.astype(np.int32) @ b.astype(np.int32))
    instr_lo, resp = await axil_read(dut, COUNTER_BASE + 8)
    assert resp == 0
    assert instr_lo == len(matmul_16_program(layout))
