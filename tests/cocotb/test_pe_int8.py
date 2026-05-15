import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


@cocotb.test()
async def pe_int8_signed_multiply_accumulate(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.valid_in.value = 0
    dut.a_in.value = 0
    dut.b_in.value = 0
    dut.acc_in.value = 0
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cases = [
        (0, 99, 1234),
        (-3, 7, 10),
        (127, 127, 0),
        (-128, -128, -5),
        (-128, 127, 8192),
    ]
    for a_value, b_value, acc_value in cases:
        dut.valid_in.value = 1
        dut.a_in.value = a_value
        dut.b_in.value = b_value
        dut.acc_in.value = acc_value
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        assert dut.valid_out.value == 1
        assert dut.a_out.value.signed_integer == a_value
        assert dut.b_out.value.signed_integer == b_value
        assert dut.acc_out.value.signed_integer == acc_value + (a_value * b_value)

    dut.valid_in.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert dut.valid_out.value == 0
