import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def pack_vmem_req(valid: int, write: int, addr: int, wdata: int = 0, wstrb: int = 0) -> int:
    return ((valid & 1) << 69) | ((write & 1) << 68) | ((addr & 0xFFFFFFFF) << 36) | ((wdata & 0xFFFFFFFF) << 4) | (wstrb & 0xF)


def unpack_vmem_resp(value: int) -> tuple[int, int, int, int]:
    ready = (value >> 34) & 1
    valid = (value >> 33) & 1
    rdata = (value >> 1) & 0xFFFFFFFF
    error = value & 1
    return ready, valid, rdata, error


async def reset(dut) -> None:
    dut.rst_n.value = 0
    for name in ("req_dma", "req_vector", "req_reduce", "req_tc0", "req_tc1"):
        if hasattr(dut, name):
            getattr(dut, name).value = 0
    if hasattr(dut, "req_mxu"):
        for idx in range(len(dut.req_mxu)):
            dut.req_mxu[idx].value = 0
    if hasattr(dut, "fast_mxu_cmd"):
        dut.fast_mxu_cmd.value = 0
        dut.fast_mxu_cmd_valid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


@cocotb.test()
async def vmem_read_write_and_conflict(dut):
    if not hasattr(dut, "req_mxu"):
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.req_dma.value = pack_vmem_req(1, 1, 0x0000, 0x11223344, 0xF)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert unpack_vmem_resp(int(dut.resp_dma.value))[1:] == (1, 0, 0)
    dut.req_dma.value = 0

    dut.req_mxu[0].value = pack_vmem_req(1, 0, 0x0000)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    ready, valid, rdata, error = unpack_vmem_resp(int(dut.resp_mxu[0].value))
    assert ready
    assert valid
    assert rdata == 0x11223344
    assert not error

    dut.req_mxu[0].value = pack_vmem_req(1, 0, 0x0000)
    dut.req_mxu[1].value = pack_vmem_req(1, 0, 0x0000)
    dut.req_dma.value = pack_vmem_req(1, 0, 0x0000)
    await Timer(1, unit="ps")
    assert unpack_vmem_resp(int(dut.resp_mxu[0].value))[0] == 1
    assert unpack_vmem_resp(int(dut.resp_mxu[1].value))[0] == 0
    assert unpack_vmem_resp(int(dut.resp_dma.value))[0] == 0


@cocotb.test()
async def cmem_read_write_and_conflict(dut):
    if not hasattr(dut, "req_tc0"):
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.req_dma.value = pack_vmem_req(1, 1, 0x0000, 0x55667788, 0xF)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert unpack_vmem_resp(int(dut.resp_dma.value))[1:] == (1, 0, 0)
    dut.req_dma.value = 0

    dut.req_tc0.value = pack_vmem_req(1, 0, 0x0000)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    ready, valid, rdata, error = unpack_vmem_resp(int(dut.resp_tc0.value))
    assert ready
    assert valid
    assert rdata == 0x55667788
    assert not error

    dut.req_tc0.value = pack_vmem_req(1, 0, 0x0000)
    dut.req_dma.value = pack_vmem_req(1, 0, 0x0000)
    await Timer(1, unit="ps")
    assert unpack_vmem_resp(int(dut.resp_tc0.value))[0] == 1
    assert unpack_vmem_resp(int(dut.resp_dma.value))[0] == 0
