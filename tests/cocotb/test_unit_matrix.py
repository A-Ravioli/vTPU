import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MEM_HBM = 0
MEM_CMEM = 1
MEM_VMEM0 = 2
OP_MATMUL = 0x04
OP_BARRIER = 0x07


def top_name(dut) -> str:
    return getattr(dut, "_name", "")


def pack_vmem_req(valid: int, write: int, addr: int, wdata: int = 0, wstrb: int = 0) -> int:
    return ((valid & 1) << 69) | ((write & 1) << 68) | ((addr & 0xFFFFFFFF) << 36) | ((wdata & 0xFFFFFFFF) << 4) | (wstrb & 0xF)


def unpack_vmem_req(value: int) -> tuple[int, int, int, int, int]:
    valid = (value >> 69) & 1
    write = (value >> 68) & 1
    addr = (value >> 36) & 0xFFFFFFFF
    wdata = (value >> 4) & 0xFFFFFFFF
    wstrb = value & 0xF
    return valid, write, addr, wdata, wstrb


def pack_vmem_resp(ready: int, valid: int, rdata: int = 0, error: int = 0) -> int:
    return ((ready & 1) << 34) | ((valid & 1) << 33) | ((rdata & 0xFFFFFFFF) << 1) | (error & 1)


def pack_mem_req(valid: int, write: int, space: int, addr: int, wdata: int = 0, wstrb: int = 0) -> int:
    return ((valid & 1) << 72) | ((write & 1) << 71) | ((space & 0x7) << 68) | ((addr & 0xFFFFFFFF) << 36) | ((wdata & 0xFFFFFFFF) << 4) | (wstrb & 0xF)


def unpack_mem_req(value: int) -> tuple[int, int, int, int, int, int]:
    valid = (value >> 72) & 1
    write = (value >> 71) & 1
    space = (value >> 68) & 0x7
    addr = (value >> 36) & 0xFFFFFFFF
    wdata = (value >> 4) & 0xFFFFFFFF
    wstrb = value & 0xF
    return valid, write, space, addr, wdata, wstrb


def pack_mem_resp(ready: int, valid: int, rdata: int = 0, error: int = 0, error_code: int = 0) -> int:
    return ((ready & 1) << 42) | ((valid & 1) << 41) | ((rdata & 0xFFFFFFFF) << 9) | ((error & 1) << 8) | (error_code & 0xFF)


def pack_unit_status(busy: int = 0, done: int = 0, error: int = 0, code: int = 0) -> int:
    return ((busy & 1) << 10) | ((done & 1) << 9) | ((error & 1) << 8) | (code & 0xFF)


def pack_dma_cmd(src_space: int, dst_space: int, src_addr: int, dst_addr: int, length: int) -> int:
    return ((src_space & 0x7) << 99) | ((dst_space & 0x7) << 96) | ((src_addr & 0xFFFFFFFF) << 64) | ((dst_addr & 0xFFFFFFFF) << 32) | (length & 0xFFFFFFFF)


def pack_mxu_cmd(dst: int, a: int, b: int, m: int, n: int, k: int, accumulate: int = 0) -> int:
    return ((dst & 0xFFFF) << 81) | ((a & 0xFFFF) << 65) | ((b & 0xFFFF) << 49) | ((m & 0xFFFF) << 33) | ((n & 0xFFFF) << 17) | ((k & 0xFFFF) << 1) | (accumulate & 1)


def pack_vector_cmd(dst: int, src0: int, src1: int, length: int, op: int, imm: int = 0) -> int:
    return ((dst & 0xFFFF) << 72) | ((src0 & 0xFFFF) << 56) | ((src1 & 0xFFFF) << 40) | ((length & 0xFFFF) << 24) | ((op & 0xFF) << 16) | (imm & 0xFFFF)


def pack_reduce_cmd(dst: int, src: int, length: int, op: int, columns: int = 0) -> int:
    return ((dst & 0xFFFF) << 56) | ((src & 0xFFFF) << 40) | ((length & 0xFFFF) << 24) | ((op & 0xFF) << 16) | (columns & 0xFFFF)


def pack_tc_cmd(opcode: int, flags: int, target: int, dst: int, src0: int, src1: int, imm0: int, imm1: int, imm2: int) -> int:
    return ((opcode & 0xFF) << 112) | ((flags & 0xFF) << 104) | ((target & 0xFF) << 96) | ((dst & 0xFFFF) << 80) | ((src0 & 0xFFFF) << 64) | ((src1 & 0xFFFF) << 48) | ((imm0 & 0xFFFF) << 32) | ((imm1 & 0xFFFF) << 16) | (imm2 & 0xFFFF)


def pack_instr(opcode: int, flags: int = 0, target: int = 0, dst: int = 0, src0: int = 0, src1: int = 0, imm0: int = 0, imm1: int = 0, imm2: int = 0) -> int:
    return ((opcode & 0xFF) << 120) | ((flags & 0xFF) << 112) | ((target & 0xFF) << 104) | ((dst & 0xFFFF) << 80) | ((src0 & 0xFFFF) << 64) | ((src1 & 0xFFFF) << 48) | ((imm0 & 0xFFFF) << 32) | ((imm1 & 0xFFFF) << 16) | (imm2 & 0xFFFF)


def word_from_i8(values) -> int:
    result = 0
    for idx, value in enumerate(values):
        result |= (value & 0xFF) << (idx * 8)
    return result


async def reset_clocked(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def run_vmem_responder(dut, req, resp, memory: dict[int, int]):
    resp.value = pack_vmem_resp(1, 0)
    pending_valid = 0
    pending_rdata = 0
    pending_error = 0
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        resp.value = pack_vmem_resp(1, pending_valid, pending_rdata, pending_error)
        pending_valid = 0
        pending_rdata = 0
        pending_error = 0
        valid, write, addr, wdata, _wstrb = unpack_vmem_req(int(req.value))
        if valid:
            if write:
                memory[addr] = wdata
                pending_valid = 1
            else:
                pending_valid = 1
                pending_rdata = memory.get(addr, 0)


async def run_mem_responder(dut, req, resp, memory: dict[int, int]):
    resp.value = pack_mem_resp(1, 0)
    pending_valid = 0
    pending_rdata = 0
    pending_error = 0
    pending_error_code = 0
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        resp.value = pack_mem_resp(1, pending_valid, pending_rdata, pending_error, pending_error_code)
        pending_valid = 0
        pending_rdata = 0
        pending_error = 0
        pending_error_code = 0
        valid, write, _space, addr, wdata, _wstrb = unpack_mem_req(int(req.value))
        if valid:
            if write:
                memory[addr] = wdata
                pending_valid = 1
            else:
                pending_valid = 1
                pending_rdata = memory.get(addr, 0)


async def issue_cmd(dut, packed_cmd: int):
    dut.cmd.value = packed_cmd
    dut.cmd_valid.value = 0
    await Timer(1, unit="ps")
    for _ in range(2000):
        if int(dut.cmd_ready.value):
            dut.cmd_valid.value = 1
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            dut.cmd_valid.value = 0
            dut.cmd.value = 0
            return
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    raise AssertionError("unit command was never ready")


async def wait_done_status(dut, max_cycles: int = 2000):
    saw_busy = False
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        status = int(dut.status.value)
        if (status >> 8) & 1:
            raise AssertionError(f"unit errored, status=0x{status:x}")
        if (status >> 9) & 1:
            return
        if (status >> 10) & 1:
            saw_busy = True
        elif saw_busy:
            return
    raise AssertionError("unit timed out")


@cocotb.test()
async def systolic_array_smoke(dut):
    if top_name(dut) != "systolic_array":
        return
    await reset_clocked(dut)
    dut.accumulate.value = 0
    dut.m.value = 1
    dut.n.value = 1
    dut.k.value = 1
    for idx, value in enumerate([1, 0, 0, 0]):
        dut.a_tile[idx].value = value
    for idx, value in enumerate([5, 0, 0, 0]):
        dut.b_tile[idx].value = value
    for idx in range(4):
        dut.c_in[idx].value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.done.value):
            assert int(dut.c_out[0].value.to_signed()) == 5
            return
    raise AssertionError("systolic array timed out")


@cocotb.test()
async def mxu_top_vmem_smoke(dut):
    if top_name(dut) != "mxu_top":
        return
    await reset_clocked(dut)
    memory = {0: word_from_i8([1, 2, 3, 4]), 16: word_from_i8([5, 6, 7, 8])}
    dut.vmem_resp.value = pack_vmem_resp(1, 0)
    cocotb.start_soon(run_vmem_responder(dut, dut.vmem_req, dut.vmem_resp, memory))
    await Timer(1, unit="ps")
    await issue_cmd(dut, pack_mxu_cmd(dst=32, a=0, b=16, m=2, n=2, k=2))
    await wait_done_status(dut)
    assert [memory[32 + (i * 4)] for i in range(4)] == [19, 22, 43, 50]


@cocotb.test()
async def vector_unit_vmem_smoke(dut):
    if top_name(dut) != "vector_unit":
        return
    await reset_clocked(dut)
    memory = {0: 1, 4: 2, 8: 3, 12: 4, 32: 10, 36: 20, 40: 30, 44: 40}
    dut.vmem_resp.value = pack_vmem_resp(1, 0)
    cocotb.start_soon(run_vmem_responder(dut, dut.vmem_req, dut.vmem_resp, memory))
    await Timer(1, unit="ps")
    await issue_cmd(dut, pack_vector_cmd(dst=64, src0=0, src1=32, length=4, op=0))
    await wait_done_status(dut)
    assert [memory[64 + (i * 4)] for i in range(4)] == [11, 22, 33, 44]


@cocotb.test()
async def reduce_unit_vmem_smoke(dut):
    if top_name(dut) != "reduce_unit":
        return
    await reset_clocked(dut)
    memory = {0: 1, 4: 0xFFFFFFFE, 8: 3, 12: 4, 16: 5, 20: 0xFFFFFFFA}
    dut.vmem_resp.value = pack_vmem_resp(1, 0)
    cocotb.start_soon(run_vmem_responder(dut, dut.vmem_req, dut.vmem_resp, memory))
    await Timer(1, unit="ps")
    await issue_cmd(dut, pack_reduce_cmd(dst=64, src=0, length=6, op=2, columns=3))
    await wait_done_status(dut)
    assert memory[64] == 2
    assert memory[68] == 3


@cocotb.test()
async def dma_engine_data_move_smoke(dut):
    if top_name(dut) != "dma_engine":
        return
    await reset_clocked(dut)
    hbm = {0: 0xAABBCCDD}
    cmem = {}
    vmem0 = {}
    vmem1 = {}
    dut.hbm_resp.value = pack_mem_resp(1, 0)
    dut.cmem_resp.value = pack_vmem_resp(1, 0)
    dut.vmem0_resp.value = pack_vmem_resp(1, 0)
    dut.vmem1_resp.value = pack_vmem_resp(1, 0)
    cocotb.start_soon(run_mem_responder(dut, dut.hbm_req, dut.hbm_resp, hbm))
    cocotb.start_soon(run_vmem_responder(dut, dut.cmem_req, dut.cmem_resp, cmem))
    cocotb.start_soon(run_vmem_responder(dut, dut.vmem0_req, dut.vmem0_resp, vmem0))
    cocotb.start_soon(run_vmem_responder(dut, dut.vmem1_req, dut.vmem1_resp, vmem1))
    await Timer(1, unit="ps")
    dut.cmd.value = pack_dma_cmd(MEM_HBM, MEM_VMEM0, 0, 0, 4)
    dut.cmd_valid.value = 1
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0
    await wait_done_status(dut)
    assert vmem0[0] == 0xAABBCCDD


@cocotb.test()
async def hbm_model_smoke(dut):
    if top_name(dut) != "hbm_model":
        return
    await reset_clocked(dut)
    dut.host_we.value = 0
    dut.host_addr.value = 0
    dut.host_wdata.value = 0
    dut.host_wstrb.value = 0
    dut.req.value = pack_mem_req(1, 1, MEM_HBM, 0, 0x12345678, 0xF)
    await RisingEdge(dut.clk)
    dut.req.value = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        if (int(dut.resp.value) >> 41) & 1:
            break
    dut.req.value = pack_mem_req(1, 0, MEM_HBM, 0, 0, 0)
    await RisingEdge(dut.clk)
    dut.req.value = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        resp = int(dut.resp.value)
        if (resp >> 41) & 1:
            assert ((resp >> 9) & 0xFFFFFFFF) == 0x12345678
            return
    raise AssertionError("HBM read timed out")


@cocotb.test()
async def instr_decoder_smoke(dut):
    if top_name(dut) != "instr_decoder":
        return
    dut.instr_raw.value = pack_instr(OP_MATMUL, flags=0x08, target=0x10, dst=0x200, src0=0, src1=0x100, imm0=16, imm1=16, imm2=16)
    await Timer(1, unit="ps")
    assert int(dut.illegal.value) == 0
    dut.instr_raw.value = pack_instr(0xFE)
    await Timer(1, unit="ps")
    assert int(dut.illegal.value) == 1


@cocotb.test()
async def control_fsm_barrier_smoke(dut):
    if top_name(dut) != "control_fsm":
        return
    await reset_clocked(dut)
    dut.start.value = 0
    dut.decoded.value = pack_tc_cmd(OP_BARRIER, 0, 0, 0, 0, 0, 1, 0, 0)
    dut.illegal.value = 0
    dut.decode_error_code.value = 0
    dut.dma_cmd_ready.value = 1
    dut.dma_status.value = pack_unit_status(busy=1)
    for idx in range(len(dut.tc_cmd_ready)):
        dut.tc_cmd_ready[idx].value = 1
        dut.tc_status[idx].value = pack_unit_status()
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.pc.value) == 0
    assert int(dut.barrier_wait.value) == 1
    dut.dma_status.value = pack_unit_status()
    for _ in range(5):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.pc.value) == 1:
            return
    raise AssertionError("control FSM did not retire barrier")


@cocotb.test()
async def tensor_core_multi_mxu_smoke(dut):
    if top_name(dut) != "tensor_core":
        return
    await reset_clocked(dut)
    dut.dma_req.value = 0
    # Four small independent 2x2 matmuls in one VMEM.
    for tile in range(4):
        base = tile * 128
        dut.dma_req.value = pack_vmem_req(1, 1, base, word_from_i8([1 + tile, 2, 3, 4]), 0xF)
        await RisingEdge(dut.clk)
        dut.dma_req.value = 0
        await RisingEdge(dut.clk)
        dut.dma_req.value = pack_vmem_req(1, 1, base + 16, word_from_i8([5, 6, 7, 8]), 0xF)
        await RisingEdge(dut.clk)
        dut.dma_req.value = 0
        await RisingEdge(dut.clk)

    for tile in range(4):
        base = tile * 128
        await issue_cmd(dut, pack_tc_cmd(OP_MATMUL, 0x08, 0x10, base + 32, base, base + 16, 2, 2, 2))

    saw_parallel = False
    for _ in range(400):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        busy_bits = int(dut.mxu_busy.value)
        if busy_bits.bit_count() >= 2:
            saw_parallel = True
        if saw_parallel and not ((int(dut.status.value) >> 10) & 1):
            break
    assert saw_parallel
