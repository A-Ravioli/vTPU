// Module: fp_trans_probe
// Purpose: Test-only wrapper exposing fp32 reciprocal, rsqrt, and exp cores for cocotb verification.
module fp_trans_probe (
  input  logic [31:0] a,
  output logic [31:0] recip_y,
  output logic [31:0] rsqrt_y,
  output logic [31:0] exp_y
);
  fp32_recip u_recip (.a(a), .y(recip_y));
  fp32_rsqrt u_rsqrt (.a(a), .y(rsqrt_y));
  fp32_exp   u_exp   (.x(a), .y(exp_y));
endmodule
