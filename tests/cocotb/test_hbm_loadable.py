import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def pack_mem_req(valid, write, space, addr, wdata=0, wstrb=0):
    return ((valid & 1) << 72) | ((write & 1) << 71) | ((space & 0x7) << 68) | \
           ((addr & 0xFFFFFFFF) << 36) | ((wdata & 0xFFFFFFFF) << 4) | (wstrb & 0xF)


def unpack_mem_resp(value):
    return {
        "ready": (value >> 42) & 1,
        "valid": (value >> 41) & 1,
        "rdata": (value >> 9) & 0xFFFFFFFF,
        "error": (value >> 8) & 1,
    }


async def read_word(dut, addr, timeout=200):
    dut.req.value = pack_mem_req(1, 0, 0, addr)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    dut.req.value = 0
    for _ in range(timeout):
        resp = unpack_mem_resp(int(dut.resp.value))
        if resp["valid"]:
            return resp["rdata"], resp["error"]
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    raise AssertionError(f"no HBM response for addr {addr:#x}")


@cocotb.test()
async def hbm_loadable_preload(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.req.value = 0
    dut.host_we.value = 0
    dut.host_addr.value = 0
    dut.host_wdata.value = 0
    dut.host_wstrb.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")

    image = open(os.environ["HBM_TEST_IMAGE"], "rb").read()
    # check a spread of word addresses against the little-endian image words
    for addr in range(0, min(len(image), 512), 4):
        expected = int.from_bytes(image[addr : addr + 4], "little")
        got, err = await read_word(dut, addr)
        assert not err, f"error reading addr {addr:#x}"
        assert got == expected, f"addr {addr:#x}: got {got:#010x} expected {expected:#010x}"
