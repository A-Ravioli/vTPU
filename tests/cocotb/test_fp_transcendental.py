import numpy as np
import cocotb
from cocotb.triggers import Timer


def f32_bits(x) -> int:
    return int(np.float32(x).view(np.uint32))


def bits_f32(b: int):
    return np.uint32(b & 0xFFFFFFFF).view(np.float32)


async def probe(dut, val):
    dut.a.value = f32_bits(np.float32(val))
    await Timer(1, unit="ns")
    return (
        float(bits_f32(int(dut.recip_y.value))),
        float(bits_f32(int(dut.rsqrt_y.value))),
        float(bits_f32(int(dut.exp_y.value))),
    )


@cocotb.test()
async def fp_recip(dut):
    rng = np.random.default_rng(1)
    vals = [0.5, 1.0, 2.0, -3.0, 7.5, -0.25, 100.0, -100.0, 0.01]
    vals += list(rng.uniform(0.02, 50.0, 60) * rng.choice([-1, 1], 60))
    worst = 0.0
    for v in vals:
        r, _, _ = await probe(dut, v)
        ref = 1.0 / v
        rel = abs(r - ref) / abs(ref)
        worst = max(worst, rel)
        assert rel < 2e-3, f"recip({v}) = {r}, ref {ref}, rel {rel}"
    dut._log.info(f"recip worst rel err {worst:.2e}")


@cocotb.test()
async def fp_rsqrt(dut):
    rng = np.random.default_rng(2)
    vals = [1.0, 2.0, 4.0, 0.25, 9.0, 100.0, 0.01, 1e-3]
    vals += list(rng.uniform(1e-3, 100.0, 60))
    worst = 0.0
    for v in vals:
        _, rs, _ = await probe(dut, v)
        ref = 1.0 / np.sqrt(v)
        rel = abs(rs - ref) / abs(ref)
        worst = max(worst, rel)
        assert rel < 2e-3, f"rsqrt({v}) = {rs}, ref {ref}, rel {rel}"
    dut._log.info(f"rsqrt worst rel err {worst:.2e}")


@cocotb.test()
async def fp_exp(dut):
    rng = np.random.default_rng(3)
    vals = [0.0, 1.0, -1.0, 2.5, -2.5, 5.0, -5.0, 10.0, -10.0, 0.1, -0.1]
    vals += list(rng.uniform(-20.0, 20.0, 80))
    worst = 0.0
    for v in vals:
        _, _, e = await probe(dut, v)
        ref = float(np.exp(np.float32(v)))
        rel = abs(e - ref) / max(abs(ref), 1e-30)
        worst = max(worst, rel)
        assert rel < 2e-3, f"exp({v}) = {e}, ref {ref}, rel {rel}"
    dut._log.info(f"exp worst rel err {worst:.2e}")
