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
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def accepted_response() -> None:
    await RisingEdge(cocotb.top.clk)
    await Timer(1, unit="ps")


@cocotb.test()
async def vmem_physical_read_write_strobes_and_conflicts(dut):
    if not hasattr(dut, "req_mxu"):
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.req_dma.value = pack_vmem_req(1, 1, 0x0000, 0x11223344, 0xF)
    await accepted_response()
    dut.req_dma.value = 0
    await accepted_response()
    assert unpack_vmem_resp(int(dut.resp_dma.value))[1:] == (1, 0, 0)

    dut.req_dma.value = pack_vmem_req(1, 1, 0x0000, 0xAAAA0000, 0xC)
    await accepted_response()
    dut.req_dma.value = 0
    await accepted_response()
    assert unpack_vmem_resp(int(dut.resp_dma.value))[1:] == (1, 0, 0)

    dut.req_mxu[0].value = pack_vmem_req(1, 0, 0x0000)
    await accepted_response()
    dut.req_mxu[0].value = 0
    await accepted_response()
    ready, valid, rdata, error = unpack_vmem_resp(int(dut.resp_mxu[0].value))
    assert ready
    assert valid
    assert rdata == 0xAAAA3344
    assert not error

    dut.req_mxu[0].value = pack_vmem_req(1, 0, 0x0000)
    dut.req_mxu[1].value = pack_vmem_req(1, 0, 0x0000)
    dut.req_dma.value = pack_vmem_req(1, 0, 0x0000)
    await Timer(1, unit="ps")
    assert unpack_vmem_resp(int(dut.resp_mxu[0].value))[0] == 1
    assert unpack_vmem_resp(int(dut.resp_mxu[1].value))[0] == 0
    assert unpack_vmem_resp(int(dut.resp_dma.value))[0] == 0

    dut.req_mxu[0].value = pack_vmem_req(1, 0, 0x0002)
    dut.req_mxu[1].value = 0
    dut.req_dma.value = 0
    await accepted_response()
    dut.req_mxu[0].value = 0
    await accepted_response()
    assert unpack_vmem_resp(int(dut.resp_mxu[0].value))[3] == 1


@cocotb.test()
async def cmem_physical_read_write_and_conflicts(dut):
    if not hasattr(dut, "req_tc0"):
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.req_dma.value = pack_vmem_req(1, 1, 0x0000, 0x55667788, 0xF)
    await accepted_response()
    dut.req_dma.value = 0
    await accepted_response()
    assert unpack_vmem_resp(int(dut.resp_dma.value))[1:] == (1, 0, 0)

    dut.req_tc0.value = pack_vmem_req(1, 0, 0x0000)
    await accepted_response()
    dut.req_tc0.value = 0
    await accepted_response()
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


@cocotb.test()
async def instr_mem_physical_host_lanes_fetch_128b(dut):
    if not hasattr(dut, "host_lane"):
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.host_we.value = 0
    dut.host_addr.value = 0
    dut.host_lane.value = 0
    dut.host_wdata.value = 0
    dut.fetch_en.value = 0
    dut.fetch_pc.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    words = [0x00112233, 0x44556677, 0x8899AABB, 0xCCDDEEFF]
    for lane, word in enumerate(words):
        dut.host_we.value = 1
        dut.host_addr.value = 0
        dut.host_lane.value = lane
        dut.host_wdata.value = word
        await RisingEdge(dut.clk)
    dut.host_we.value = 0

    dut.fetch_en.value = 1
    dut.fetch_pc.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    expected = (words[3] << 96) | (words[2] << 64) | (words[1] << 32) | words[0]
    assert int(dut.instr.value) == expected
    assert int(dut.fetch_error.value) == 0
