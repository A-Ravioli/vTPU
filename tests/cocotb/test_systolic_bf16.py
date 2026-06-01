import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

ARRAY = 16  # ARRAY_M = ARRAY_N = ARRAY_K default


def f32_to_bf16_bits(x) -> int:
    bits = np.uint32(np.float32(x).view(np.uint32))
    bias = np.uint32(0x7FFF) + ((bits >> np.uint32(16)) & np.uint32(1))
    return int(((bits + bias) >> np.uint32(16)) & np.uint16(0xFFFF))


def bf16_bits_to_f32(b: int):
    return np.uint32((b & 0xFFFF) << 16).view(np.float32)


def f32_bits(x) -> int:
    return int(np.float32(x).view(np.uint32))


def seq_fp32_dot(a_row_bf, b_col_bf, k):
    """Sequential fp32 accumulation in k order — matches the output-stationary array."""
    acc = np.float32(0.0)
    for kk in range(k):
        a_f = bf16_bits_to_f32(a_row_bf[kk])
        b_f = bf16_bits_to_f32(b_col_bf[kk])
        acc = np.float32(acc + np.float32(a_f * b_f))
    return acc


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.accumulate.value = 0
    for idx in range(ARRAY * ARRAY):
        dut.a_tile[idx].value = 0
        dut.b_tile[idx].value = 0
        dut.c_in[idx].value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


@cocotb.test()
async def systolic_bf16_matmul(dut):
    await reset(dut)
    rng = np.random.default_rng(0x5A5A)

    shapes = [(2, 2, 2), (4, 3, 5), (16, 16, 16), (8, 1, 16), (1, 16, 7)]
    for (m, n, k) in shapes:
        a = (rng.standard_normal((m, k)) * 4.0).astype(np.float32)
        b = (rng.standard_normal((k, n)) * 4.0).astype(np.float32)
        a_bf = np.vectorize(f32_to_bf16_bits)(a).astype(np.int64)
        b_bf = np.vectorize(f32_to_bf16_bits)(b).astype(np.int64)

        for idx in range(ARRAY * ARRAY):
            dut.a_tile[idx].value = 0
            dut.b_tile[idx].value = 0
            dut.c_in[idx].value = 0
        for i in range(m):
            for kk in range(k):
                dut.a_tile[i * ARRAY + kk].value = int(a_bf[i, kk])
        for kk in range(k):
            for j in range(n):
                dut.b_tile[kk * ARRAY + j].value = int(b_bf[kk, j])

        dut.m.value = m
        dut.n.value = n
        dut.k.value = k
        dut.accumulate.value = 0
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        for _ in range(4 * k + 50):
            await Timer(1, unit="ps")
            if int(dut.done.value):
                break
            await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        assert int(dut.done.value) == 1, f"timeout for shape {(m,n,k)}"
        assert int(dut.error.value) == 0

        for i in range(m):
            for j in range(n):
                expect = seq_fp32_dot(a_bf[i, :k], b_bf[:k, j], k)
                got = int(dut.c_out[i * ARRAY + j].value)
                assert got == f32_bits(expect), (
                    f"shape {(m,n,k)} out[{i},{j}]: got 0x{got:08x} "
                    f"({bf16_bits_to_f32(got >> 16)}) expected 0x{f32_bits(expect):08x} ({expect})"
                )
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
