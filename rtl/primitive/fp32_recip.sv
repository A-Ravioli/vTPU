// Module: fp32_recip
// Purpose: Combinational fp32 reciprocal 1/a via magic-constant seed + 2 Newton-Raphson steps.
// Public TPU inspiration: softmax normalization and sigmoid need fast reciprocal.
// Educational simplification: subnormal/zero inputs flush toward +/-inf; ~1e-6 relative accuracy.
// Newton iteration: y_{n+1} = y_n * (2 - a*y_n).
// Tests: tests/cocotb/test_fp_transcendental.py (tolerance vs numpy).
module fp32_recip (
  input  logic [31:0] a,
  output logic [31:0] y
);
  localparam logic [31:0] TWO = 32'h4000_0000;     // 2.0f

  logic        sgn;
  logic [31:0] amag, seed;
  logic [31:0] t0, t1n, y1, t2, t3n, y2;

  assign sgn  = a[31];
  assign amag = {1'b0, a[30:0]};                   // |a|
  // Newton-tuned magic seed for 1/x.
  assign seed = 32'h7EF1_27EA - amag;

  // iteration 1
  fp32_mul m0 (.a(amag), .b(seed), .p(t0));
  fp32_add a0 (.a(TWO), .b({~t0[31], t0[30:0]}), .s(t1n)); // 2 - amag*seed
  fp32_mul m1 (.a(seed), .b(t1n), .p(y1));
  // iteration 2
  fp32_mul m2 (.a(amag), .b(y1), .p(t2));
  fp32_add a1 (.a(TWO), .b({~t2[31], t2[30:0]}), .s(t3n));
  fp32_mul m3 (.a(y1), .b(t3n), .p(y2));

  assign y = {sgn, y2[30:0]};                      // apply original sign
endmodule
