// Module: pe_bf16
// Purpose: One-cycle bf16 x bf16 -> fp32 multiply-accumulate processing element.
// Public TPU inspiration: bf16 matrix units multiply in bf16 and accumulate in fp32.
// Educational simplification: combinational fp32 multiply/add with RNE; subnormals flush to zero.
// Inputs: valid_in, a_in/b_in (bf16 bit patterns), acc_in (fp32 bit pattern).
// Outputs: valid_out, a_out/b_out (forwarded bf16), acc_out (fp32 = acc_in + a*b).
// State: One registered pipeline stage.
// Latency: One cycle from valid_in to valid_out.
// Tests: tests/cocotb/test_pe_bf16.py compares against numpy fp32.
module pe_bf16 (
  input  logic clk,
  input  logic rst_n,

  input  logic valid_in,
  input  logic [15:0] a_in,        // bf16
  input  logic [15:0] b_in,        // bf16
  input  logic [31:0] acc_in,      // fp32

  output logic valid_out,
  output logic [15:0] a_out,
  output logic [15:0] b_out,
  output logic [31:0] acc_out      // fp32
);
  logic [31:0] a_f32, b_f32, product, sum;

  // bf16 -> fp32 is an exact zero-extend of the mantissa.
  assign a_f32 = {a_in, 16'h0000};
  assign b_f32 = {b_in, 16'h0000};

  fp32_mul u_mul (.a(a_f32), .b(b_f32), .p(product));
  fp32_add u_add (.a(acc_in), .b(product), .s(sum));

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
      acc_out <= sum;
    end
  end
endmodule
