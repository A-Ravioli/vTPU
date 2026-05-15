// Module: pe_int8
// Purpose: One-cycle signed int8 multiply-accumulate processing element.
// Public TPU inspiration: Matrix multiply units use many small multiply-accumulate cells.
// Educational simplification: This PE uses deterministic int8 inputs and int32 accumulation.
// Inputs: valid_in, a_in, b_in, acc_in.
// Outputs: valid_out, a_out, b_out, acc_out.
// State: One registered pipeline stage.
// Latency: One cycle from valid_in to valid_out.
// Backpressure: None; upstream must provide one input per cycle.
// Error behavior: No local error cases.
// Tests: tests/cocotb/test_pe_int8.py and Python numeric golden tests.
module pe_int8 #(
  parameter int DATA_W = 8,
  parameter int ACC_W = 32
)(
  input  logic clk,
  input  logic rst_n,

  input  logic valid_in,
  input  logic signed [DATA_W-1:0] a_in,
  input  logic signed [DATA_W-1:0] b_in,
  input  logic signed [ACC_W-1:0]  acc_in,

  output logic valid_out,
  output logic signed [DATA_W-1:0] a_out,
  output logic signed [DATA_W-1:0] b_out,
  output logic signed [ACC_W-1:0]  acc_out
);
  logic signed [ACC_W-1:0] product_ext;

  always_comb begin
    product_ext = $signed(a_in) * $signed(b_in);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_out <= 1'b0;
      a_out <= '0;
      b_out <= '0;
      acc_out <= '0;
    end else begin
      valid_out <= valid_in;
      a_out <= a_in;
      b_out <= b_in;
      acc_out <= acc_in + product_ext;
    end
  end
endmodule
