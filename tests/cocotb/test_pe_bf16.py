import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def f32_to_bits(x: np.float32) -> int:
    return int(np.float32(x).view(np.uint32))


def bits_to_f32(b: int) -> np.float32:
    return np.uint32(b & 0xFFFFFFFF).view(np.float32)


def f32_to_bf16_bits(x: np.float32) -> int:
    """Round-to-nearest-even f32 -> bf16 bit pattern (uint16)."""
    bits = np.uint32(np.float32(x).view(np.uint32))
    bias = np.uint32(0x7FFF) + ((bits >> np.uint32(16)) & np.uint32(1))
    return int(((bits + bias) >> np.uint32(16)) & np.uint16(0xFFFF))


def bf16_bits_to_f32(b: int) -> np.float32:
    return np.uint32((b & 0xFFFF) << 16).view(np.float32)


@cocotb.test()
async def pe_bf16_multiply_accumulate(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.valid_in.value = 0
    dut.a_in.value = 0
    dut.b_in.value = 0
    dut.acc_in.value = 0
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    rng = np.random.default_rng(0xBF16)
    # mix of structured edge cases and random values
    cases = [
        (0.0, 1.5, 3.25),
        (1.0, 1.0, 0.0),
        (-2.0, 0.5, 10.0),
        (3.5, -4.0, -1.0),
        (0.0, 0.0, 7.0),
        (123.0, -0.0078125, 0.5),
    ]
    cases += [
        (
            float(rng.standard_normal() * rng.choice([1.0, 8.0, 64.0])),
            float(rng.standard_normal() * rng.choice([1.0, 8.0, 64.0])),
            float(rng.standard_normal() * rng.choice([1.0, 32.0, 256.0])),
        )
        for _ in range(200)
    ]

    mismatches = 0
    for a_val, b_val, acc_val in cases:
        a_bf = f32_to_bf16_bits(np.float32(a_val))
        b_bf = f32_to_bf16_bits(np.float32(b_val))
        acc_f = f32_to_bf16_bits(np.float32(acc_val))  # accumulator carried as exact bf16-rep value
        acc_bits = f32_to_bits(bf16_bits_to_f32(acc_f))

        dut.valid_in.value = 1
        dut.a_in.value = a_bf
        dut.b_in.value = b_bf
        dut.acc_in.value = acc_bits
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")

        a_f = bf16_bits_to_f32(a_bf)
        b_f = bf16_bits_to_f32(b_bf)
        acc_in_f = bits_to_f32(acc_bits)
        # numpy fp32 reference: product is exact in fp32, add rounds RNE
        expect = np.float32(acc_in_f) + (np.float32(a_f) * np.float32(b_f))
        got_bits = int(dut.acc_out.value)
        exp_bits = f32_to_bits(expect)
        if got_bits != exp_bits:
            mismatches += 1
            if mismatches <= 10:
                dut._log.error(
                    f"a={a_f} b={b_f} acc={acc_in_f} -> got {bits_to_f32(got_bits)} "
                    f"(0x{got_bits:08x}) expected {expect} (0x{exp_bits:08x})"
                )
    assert mismatches == 0, f"{mismatches} fp32 MAC mismatches vs numpy"
