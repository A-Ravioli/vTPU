// Module: fp32_exp
// Purpose: Combinational fp32 e^x via range reduction x = k*ln2 + r and a degree-5 Taylor on r.
// Public TPU inspiration: softmax and SiLU/sigmoid need exp.
// Educational simplification: inputs clamped to ~[-127,127]; ~1e-6 relative accuracy on the reduced range.
// Method: y=x*log2e; k=round(y); r=x-k*ln2 (|r|<=ln2/2); e^x = 2^k * poly(r).
// Tests: tests/cocotb/test_fp_transcendental.py (tolerance vs numpy).
module fp32_exp (
  input  logic [31:0] x,
  output logic [31:0] y
);
  localparam logic [31:0] LOG2E = 32'h3FB8_AA3B;   // 1.4426950
  localparam logic [31:0] LN2   = 32'h3F31_7218;   // 0.6931472
  localparam logic [31:0] C0    = 32'h3F80_0000;   // 1.0
  localparam logic [31:0] C1    = 32'h3F80_0000;   // 1.0
  localparam logic [31:0] C2    = 32'h3F00_0000;   // 1/2
  localparam logic [31:0] C3    = 32'h3E2A_AAAB;   // 1/6
  localparam logic [31:0] C4    = 32'h3D2A_AAAB;   // 1/24
  localparam logic [31:0] C5    = 32'h3C08_8889;   // 1/120
  localparam logic [31:0] CLAMP = 32'h42FE_0000;   // 127.0

  // ---- range reduction ----
  logic [31:0] xc;                                 // clamped x
  logic [31:0] yv;                                 // x*log2e
  logic signed [31:0] k;                           // round(yv)
  logic [31:0] kf;                                 // (fp32)k
  logic [31:0] ktimes, r;
  // ---- polynomial (Horner) ----
  logic [31:0] p0, p0a, p1, p1a, p2, p2a, p3, p3a, p4, p4a, p5;
  // ---- scaling ----
  logic signed [31:0] ek;
  logic [31:0] pow2k;

  // clamp |x| <= 127.0
  always_comb begin
    if ((x[30:0] > CLAMP[30:0])) xc = {x[31], CLAMP[30:0]};
    else                          xc = x;
  end

  fp32_mul mlog (.a(xc), .b(LOG2E), .p(yv));

  function automatic logic signed [31:0] f32_to_int_round(input logic [31:0] bits);
    logic        sgn;
    logic [7:0]  e;
    logic [23:0] mant;
    logic signed [9:0] eu;
    integer      shift;
    logic [31:0] intval;
    begin
      sgn  = bits[31];
      e    = bits[30:23];
      mant = {1'b1, bits[22:0]};
      eu   = $signed({2'b0, e}) - 10'sd127;
      if (eu < -10'sd1) begin
        f32_to_int_round = 32'sd0;                 // |y| < 0.5
      end else begin
        shift = 23 - int'(eu);                     // > 0 for our clamped range
        if (shift <= 0) begin
          intval = {8'd0, mant} << (-shift);
        end else if (shift > 31) begin
          intval = 32'd0;
        end else begin
          intval = ({8'd0, mant} >> shift) + {31'd0, mant[shift-1]};  // round half up
        end
        f32_to_int_round = sgn ? -$signed(intval) : $signed(intval);
      end
    end
  endfunction

  function automatic logic [31:0] int_to_f32(input logic signed [31:0] n);
    logic        sgn;
    logic [31:0] m;
    integer      p;
    integer      i;
    logic [7:0]  exp;
    logic [31:0] shifted;
    begin
      if (n == 32'sd0) begin
        int_to_f32 = 32'd0;
      end else begin
        sgn = n[31];
        m   = sgn ? $unsigned(-n) : $unsigned(n);
        p   = 0;
        for (i = 1; i < 32; i = i + 1) begin
          if (m[i]) p = i;
        end
        exp     = 8'd127 + p[7:0];
        shifted = (p >= 23) ? (m >> (p - 23)) : (m << (23 - p));
        int_to_f32 = {sgn, exp, shifted[22:0]};
      end
    end
  endfunction

  assign k  = f32_to_int_round(yv);
  assign kf = int_to_f32(k);

  fp32_mul mk (.a(kf), .b(LN2), .p(ktimes));
  fp32_add ar (.a(xc), .b({~ktimes[31], ktimes[30:0]}), .s(r));   // r = x - k*ln2

  // poly = ((((C5*r + C4)*r + C3)*r + C2)*r + C1)*r + C0
  fp32_mul h0  (.a(C5),  .b(r), .p(p0));
  fp32_add h0a (.a(p0),  .b(C4), .s(p0a));
  fp32_mul h1  (.a(p0a), .b(r), .p(p1));
  fp32_add h1a (.a(p1),  .b(C3), .s(p1a));
  fp32_mul h2  (.a(p1a), .b(r), .p(p2));
  fp32_add h2a (.a(p2),  .b(C2), .s(p2a));
  fp32_mul h3  (.a(p2a), .b(r), .p(p3));
  fp32_add h3a (.a(p3),  .b(C1), .s(p3a));
  fp32_mul h4  (.a(p3a), .b(r), .p(p4));
  fp32_add h4a (.a(p4),  .b(C0), .s(p4a));
  assign p5 = p4a;

  // 2^k as fp32
  always_comb begin
    ek = k + 32'sd127;
    if (ek <= 32'sd0)        pow2k = 32'd0;                  // underflow
    else if (ek >= 32'sd255) pow2k = 32'h7F80_0000;          // overflow -> inf
    else                     pow2k = {1'b0, ek[7:0], 23'd0};
  end

  fp32_mul mout (.a(p5), .b(pow2k), .p(y));
endmodule
