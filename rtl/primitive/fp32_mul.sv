// Module: fp32_mul
// Purpose: Combinational IEEE-754 single-precision multiply with round-to-nearest-even.
// Public TPU inspiration: bf16xbf16 products accumulate in fp32 inside matrix units.
// Educational simplification: subnormal inputs/outputs flush to zero; NaN payloads are not preserved.
// Inputs: two fp32 bit patterns a, b.
// Outputs: fp32 bit pattern p = round(a * b).
// Notes: A bf16xbf16 product is exact in fp32, so this also serves the bf16 datapath when
//        operands are bf16 values widened to fp32 ({bf16, 16'b0}).
module fp32_mul (
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] p
);
  logic        sa, sb, sp;
  logic [7:0]  ea, eb;
  logic [22:0] ma, mb;
  logic        a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  logic [23:0] sig_a, sig_b;        // 1.xxx significands (normals)
  logic [47:0] prod;                // 24x24 product
  logic signed [11:0] exp_sum;      // ea + eb - bias, with headroom
  logic [22:0] mant_norm;
  logic        guard, round_bit, sticky, round_up;
  logic [24:0] mant_rounded;        // 23 mantissa + carry headroom
  logic signed [11:0] exp_final;

  always_comb begin
    sa = a[31]; ea = a[30:23]; ma = a[22:0];
    sb = b[31]; eb = b[30:23]; mb = b[22:0];
    sp = sa ^ sb;

    a_zero = (ea == 8'd0);            // flush subnormals to zero
    b_zero = (eb == 8'd0);
    a_inf  = (ea == 8'hFF) && (ma == 23'd0);
    b_inf  = (eb == 8'hFF) && (mb == 23'd0);
    a_nan  = (ea == 8'hFF) && (ma != 23'd0);
    b_nan  = (eb == 8'hFF) && (mb != 23'd0);

    sig_a = {1'b1, ma};
    sig_b = {1'b1, mb};
    prod  = sig_a * sig_b;           // in [2^46, 2^48)

    // defaults (avoid inferred latches in the special-case paths)
    p = 32'd0;
    exp_sum = 12'sd0;
    mant_norm = 23'd0;
    guard = 1'b0; round_bit = 1'b0; sticky = 1'b0; round_up = 1'b0;
    mant_rounded = 25'd0;
    exp_final = 12'sd0;

    if (a_nan || b_nan || (a_inf && b_zero) || (b_inf && a_zero)) begin
      p = {sp, 8'hFF, 23'h400000};   // canonical qNaN
    end else if (a_inf || b_inf) begin
      p = {sp, 8'hFF, 23'd0};        // signed infinity
    end else if (a_zero || b_zero) begin
      p = {sp, 31'd0};               // signed zero
    end else begin
      exp_sum = $signed({4'd0, ea}) + $signed({4'd0, eb}) - 12'sd127;
      // Normalize: leading 1 at bit47 means value in [2,4); at bit46 means [1,2).
      if (prod[47]) begin
        mant_norm = prod[46:24];
        guard     = prod[23];
        round_bit = prod[22];
        sticky    = |prod[21:0];
        exp_final = exp_sum + 12'sd1;
      end else begin
        mant_norm = prod[45:23];
        guard     = prod[22];
        round_bit = prod[21];
        sticky    = |prod[20:0];
        exp_final = exp_sum;
      end

      round_up = guard && (round_bit || sticky || mant_norm[0]);
      // mant_norm is the 23-bit fraction (implicit 1 dropped). A carry out of bit 23
      // means 1.111..1 + ulp -> 10.000..0, i.e. fraction becomes 0 and exponent += 1.
      // (No right shift here, unlike fp32_add where the significand includes the implicit 1.)
      mant_rounded = {2'b0, mant_norm} + {24'd0, round_up};
      if (mant_rounded[23]) begin
        exp_final = exp_final + 12'sd1;  // mant_rounded[22:0] is already 0 in this case
      end

      if (exp_final >= 12'sd255) begin
        p = {sp, 8'hFF, 23'd0};      // overflow -> infinity
      end else if (exp_final <= 12'sd0) begin
        p = {sp, 31'd0};             // underflow -> flush to zero
      end else begin
        p = {sp, exp_final[7:0], mant_rounded[22:0]};
      end
    end
  end
endmodule
