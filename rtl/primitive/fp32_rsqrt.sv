// Module: fp32_rsqrt
// Purpose: Combinational fp32 inverse square root 1/sqrt(a) via fast-inverse-sqrt seed + 3 Newton steps.
// Public TPU inspiration: RMSNorm normalizes by 1/sqrt(mean(x^2)+eps).
// Educational simplification: assumes a > 0 (variance + eps); ~1e-6 relative accuracy after 3 steps.
// Newton iteration: y_{n+1} = y_n * (1.5 - 0.5*a*y_n*y_n).
// Tests: tests/cocotb/test_fp_transcendental.py (tolerance vs numpy).
module fp32_rsqrt (
  input  logic [31:0] a,
  output logic [31:0] y
);
  localparam logic [31:0] HALF       = 32'h3F00_0000;  // 0.5f
  localparam logic [31:0] THREE_HALF = 32'h3FC0_0000;  // 1.5f

  logic [31:0] seed, half_a;
  logic [31:0] s0, s1n, y1_t0, y1;
  logic [31:0] s2, s3n, y2_t0, y2;
  logic [31:0] s4, s5n, y3_t0, y3;

  assign seed = 32'h5F37_59DF - {1'b0, a[31:1]};       // i = magic - (a_bits >> 1)
  fp32_mul mha (.a(HALF), .b(a), .p(half_a));          // 0.5*a

  // y1 = seed*(1.5 - 0.5*a*seed*seed)
  fp32_mul m0 (.a(seed), .b(seed), .p(s0));
  fp32_mul m1 (.a(half_a), .b(s0), .p(s1n));
  fp32_add a0 (.a(THREE_HALF), .b({~s1n[31], s1n[30:0]}), .s(y1_t0));
  fp32_mul m2 (.a(seed), .b(y1_t0), .p(y1));

  // y2
  fp32_mul m3 (.a(y1), .b(y1), .p(s2));
  fp32_mul m4 (.a(half_a), .b(s2), .p(s3n));
  fp32_add a1 (.a(THREE_HALF), .b({~s3n[31], s3n[30:0]}), .s(y2_t0));
  fp32_mul m5 (.a(y1), .b(y2_t0), .p(y2));

  // y3
  fp32_mul m6 (.a(y2), .b(y2), .p(s4));
  fp32_mul m7 (.a(half_a), .b(s4), .p(s5n));
  fp32_add a2 (.a(THREE_HALF), .b({~s5n[31], s5n[30:0]}), .s(y3_t0));
  fp32_mul m8 (.a(y2), .b(y3_t0), .p(y3));

  assign y = y3;
endmodule
