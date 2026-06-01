// Module: fp32_add
// Purpose: Combinational IEEE-754 single-precision add with round-to-nearest-even.
// Public TPU inspiration: fp32 accumulation of products inside matrix and vector units.
// Educational simplification: subnormal inputs/outputs flush to zero; NaN payloads not preserved.
// Inputs: two fp32 bit patterns a, b.
// Outputs: fp32 bit pattern s = round(a + b).
module fp32_add (
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] s
);
  // Working significand layout (W=28 bits): [27]=carry, [26:3]=24-bit significand
  // (implicit 1 at bit 26), [2:0]=guard/round/sticky.
  localparam int W = 28;

  logic        sa, sb;
  logic [7:0]  ea, eb;
  logic [22:0] ma, mb;
  logic        a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  logic [30:0] mag_a, mag_b;

  logic        big_sign, small_sign;
  logic [7:0]  big_exp;
  logic [23:0] big_sig, small_sig;
  logic [7:0]  exp_diff;

  logic [W-1:0] big_w, small_w0, small_aligned, lost_mask;
  logic         sticky_align;
  logic [W-1:0] sum;
  logic         res_sign;
  logic signed [11:0] exp_res;
  logic         dropped_lsb;

  integer       lz, i;
  logic         guard, round_bit, sticky_bit, round_up;
  logic [24:0]  mant_r;

  always_comb begin
    sa = a[31]; ea = a[30:23]; ma = a[22:0];
    sb = b[31]; eb = b[30:23]; mb = b[22:0];

    a_zero = (ea == 8'd0);            // flush subnormals to zero
    b_zero = (eb == 8'd0);
    a_inf  = (ea == 8'hFF) && (ma == 23'd0);
    b_inf  = (eb == 8'hFF) && (mb == 23'd0);
    a_nan  = (ea == 8'hFF) && (ma != 23'd0);
    b_nan  = (eb == 8'hFF) && (mb != 23'd0);

    mag_a = a[30:0];
    mag_b = b[30:0];

    // Defaults / declarations
    s = 32'd0;
    big_sign = 1'b0; small_sign = 1'b0; big_exp = 8'd0;
    big_sig = 24'd0; small_sig = 24'd0; exp_diff = 8'd0;
    big_w = '0; small_w0 = '0; small_aligned = '0; lost_mask = '0;
    sticky_align = 1'b0; sum = '0; res_sign = 1'b0; exp_res = 12'sd0;
    dropped_lsb = 1'b0; lz = 0; guard = 1'b0; round_bit = 1'b0;
    sticky_bit = 1'b0; round_up = 1'b0; mant_r = 25'd0;

    if (a_nan || b_nan || (a_inf && b_inf && (sa != sb))) begin
      s = {1'b0, 8'hFF, 23'h400000};                 // NaN
    end else if (a_inf) begin
      s = {sa, 8'hFF, 23'd0};
    end else if (b_inf) begin
      s = {sb, 8'hFF, 23'd0};
    end else if (a_zero && b_zero) begin
      s = {sa & sb, 31'd0};                          // -0 only if both -0
    end else if (a_zero) begin
      s = b;
    end else if (b_zero) begin
      s = a;
    end else begin
      // Order by magnitude so subtraction is non-negative.
      if (mag_a >= mag_b) begin
        big_sign = sa; big_exp = ea; big_sig = {1'b1, ma};
        small_sign = sb; small_sig = {1'b1, mb};
        exp_diff = ea - eb;
      end else begin
        big_sign = sb; big_exp = eb; big_sig = {1'b1, mb};
        small_sign = sa; small_sig = {1'b1, ma};
        exp_diff = eb - ea;
      end

      big_w    = {1'b0, big_sig, 3'b000};            // [26]=implicit 1
      small_w0 = {1'b0, small_sig, 3'b000};

      if (exp_diff >= W[7:0]) begin
        small_aligned = '0;
        sticky_align  = (small_sig != 24'd0);
      end else begin
        small_aligned = small_w0 >> exp_diff;
        lost_mask     = (({{(W-1){1'b0}}, 1'b1}) << exp_diff) - {{(W-1){1'b0}}, 1'b1};
        sticky_align  = |(small_w0 & lost_mask);
      end
      small_aligned[0] = small_aligned[0] | sticky_align;

      res_sign = big_sign;
      exp_res  = $signed({4'd0, big_exp});

      if (big_sign == small_sign) begin
        sum = big_w + small_aligned;
        if (sum[27]) begin                           // addition carry
          dropped_lsb = sum[0];
          sum = sum >> 1;
          sum[0] = sum[0] | dropped_lsb;
          exp_res = exp_res + 12'sd1;
        end
      end else begin
        sum = big_w - small_aligned;                 // non-negative
      end

      if (sum == '0) begin
        s = 32'd0;                                   // exact cancellation -> +0
      end else begin
        // Normalize: bring leading 1 to bit 26.
        lz = 0;
        for (i = 0; i < 27; i = i + 1) begin
          if (sum[26] == 1'b0) begin
            sum = sum << 1;
            lz  = lz + 1;
          end
        end
        exp_res = exp_res - lz[11:0];

        guard      = sum[2];
        round_bit  = sum[1];
        sticky_bit = sum[0];
        round_up   = guard && (round_bit || sticky_bit || sum[3]);
        mant_r     = {1'b0, sum[26:3]} + {24'd0, round_up};
        if (mant_r[24]) begin                        // rounding overflow
          mant_r  = mant_r >> 1;
          exp_res = exp_res + 12'sd1;
        end

        if (exp_res >= 12'sd255) begin
          s = {res_sign, 8'hFF, 23'd0};              // overflow -> inf
        end else if (exp_res <= 12'sd0) begin
          s = {res_sign, 31'd0};                     // underflow -> flush
        end else begin
          s = {res_sign, exp_res[7:0], mant_r[22:0]};
        end
      end
    end
  end
endmodule
