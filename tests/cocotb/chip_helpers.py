import numpy as np
from cocotb.triggers import RisingEdge, Timer

REG_CONTROL = 0x0000
REG_STATUS = 0x0004
REG_ERROR_CODE = 0x0008
REG_PC = 0x000C
INSTR_BASE = 0x1000
HBM_BASE = 0x0010_0000


def pack_host_req(write: int, addr: int, wdata: int = 0) -> int:
    return (1 << 65) | ((write & 1) << 64) | ((addr & 0xFFFFFFFF) << 32) | (wdata & 0xFFFFFFFF)


def unpack_host_resp(value: int) -> tuple[int, bool]:
    return (value >> 1) & 0xFFFFFFFF, bool(value & 1)


async def reset(dut, cycles: int = 3) -> None:
    dut.rst_n.value = 0
    dut.host_req_valid.value = 0
    dut.host_req.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def mmio_write(dut, addr: int, value: int) -> bool:
    dut.host_req.value = pack_host_req(1, addr, value)
    dut.host_req_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    resp = int(dut.host_resp.value)
    dut.host_req_valid.value = 0
    dut.host_req.value = 0
    return unpack_host_resp(resp)[1]


async def mmio_read(dut, addr: int) -> tuple[int, bool]:
    dut.host_req.value = pack_host_req(0, addr, 0)
    dut.host_req_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    resp = int(dut.host_resp.value)
    dut.host_req_valid.value = 0
    dut.host_req.value = 0
    return unpack_host_resp(resp)


async def load_program(dut, program) -> None:
    for pc, instr in enumerate(program):
        encoded = instr.encode()
        for lane in range(4):
            word = (encoded >> (lane * 32)) & 0xFFFFFFFF
            assert not await mmio_write(dut, INSTR_BASE + (pc * 16) + (lane * 4), word)


async def write_hbm_bytes(dut, addr: int, payload: bytes) -> None:
    padded = payload + (b"\x00" * ((4 - (len(payload) % 4)) % 4))
    for offset in range(0, len(padded), 4):
        word = int.from_bytes(padded[offset : offset + 4], byteorder="little", signed=False)
        assert not await mmio_write(dut, HBM_BASE + addr + offset, word)


async def read_hbm_bytes(dut, addr: int, length: int) -> bytes:
    chunks = []
    padded_len = length + ((4 - (length % 4)) % 4)
    for offset in range(0, padded_len, 4):
        word, err = await mmio_read(dut, HBM_BASE + addr + offset)
        assert not err
        chunks.append(word.to_bytes(4, byteorder="little", signed=False))
    return b"".join(chunks)[:length]


async def start_and_wait(dut, timeout_cycles: int = 20000) -> tuple[int, int]:
    assert not await mmio_write(dut, REG_CONTROL, 1)
    for _ in range(timeout_cycles):
        status, err = await mmio_read(dut, REG_STATUS)
        assert not err
        if status & 0b101:
            error_code, code_err = await mmio_read(dut, REG_ERROR_CODE)
            assert not code_err
            return status, error_code
        await RisingEdge(dut.clk)
    pc, _ = await mmio_read(dut, REG_PC)
    raise AssertionError(f"chip timed out at pc={pc}")


def matrix_i8_bytes(matrix: np.ndarray) -> bytes:
    return np.asarray(matrix, dtype=np.int8, order="C").tobytes(order="C")


def matrix_i32_from_bytes(payload: bytes, rows: int = 16, cols: int = 16) -> np.ndarray:
    return np.frombuffer(payload, dtype=np.int32).reshape(rows, cols).copy()
