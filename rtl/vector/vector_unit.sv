// Module: vector_unit
// Purpose: VMEM-connected datapath for documented int32 vector operations.
// Public TPU inspiration: TensorCore vector units operate beside MXUs on local memory.
// Educational simplification: One scalar element is processed at a time through a 32-bit VMEM port.
// Inputs: vector_cmd_t command and VMEM response.
// Outputs: VMEM request and unit status.
// State: IDLE -> read operands -> write result -> DONE/ERROR.
// Latency: Memory-response dependent, one element at a time.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Unsupported op, bad alignment, zero length, bounds, or VMEM errors enter ERROR.
module vector_unit #(
  parameter int LANES = 16,
  parameter int VMEM_BYTES = 262144
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::vector_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  output vtpu_pkg::vmem_req_t vmem_req,
  input  vtpu_pkg::vmem_resp_t vmem_resp,
  output vtpu_pkg::unit_status_t status
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_READ0_REQ,
    ST_READ0_WAIT,
    ST_READ1_REQ,
    ST_READ1_WAIT,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;
  vtpu_pkg::vector_cmd_t cmd_q;
  logic [31:0] index_q;
  logic signed [31:0] lhs_q;
  logic signed [31:0] rhs_q;
  logic signed [31:0] result_q;
  logic [7:0] error_code_q;
  vtpu_pkg::vmem_req_t vmem_req_q;

  assign vmem_req = vmem_req_q;
  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? error_code_q : vtpu_pkg::ERR_NONE;

  // Ops with a second read phase: int VADD/VMUL/VMAX, fp FADD/FMUL/FMAX, FSCALE_BCAST,
  // and FQUANT_BF16 (which reads a second fp32 from src0 to pack a pair).
  function automatic logic op_needs_rhs(input logic [7:0] op);
    op_needs_rhs = (op == 8'd0) || (op == 8'd1) || (op == 8'd5) ||
                   (op == 8'd6) || (op == 8'd7) || (op == 8'd8) ||
                   (op == 8'd14) || (op == 8'd15);
  endfunction

  // fp ops operate on fp32 VMEM data (op codes >= 6).
  function automatic logic op_is_fp(input logic [7:0] op);
    op_is_fp = (op >= 8'd6) && (op <= 8'd15);
  endfunction

  // FQUANT_BF16: cast a pair of fp32 -> two packed bf16 per output word.
  function automatic logic op_is_quant(input logic [7:0] op);
    op_is_quant = (op == 8'd15);
  endfunction

  // ops that actually read src1 (FQUANT reads its second operand from src0 instead).
  function automatic logic op_reads_src1(input logic [7:0] op);
    op_reads_src1 = op_needs_rhs(op) && (op != 8'd15);
  endfunction

  // number of output words produced (FQUANT packs 2 inputs -> 1 word).
  function automatic logic [31:0] out_words(input logic [7:0] op, input logic [15:0] length);
    out_words = op_is_quant(op) ? ({16'd0, length} >> 1) : {16'd0, length};
  endfunction

  // round-to-nearest-even f32 bit pattern -> bf16 (matches numeric.float32_to_bf16).
  function automatic logic [15:0] f32_to_bf16(input logic [31:0] bits);
    logic [31:0] bias;
    logic [31:0] rounded;
    begin
      bias = 32'h0000_7FFF + {31'd0, bits[16]};
      rounded = (bits + bias) >> 16;
      f32_to_bf16 = rounded[15:0];
    end
  endfunction

  // fp32 greater-than (sign-magnitude aware), used by FMAX.
  function automatic logic fp_gt(input logic [31:0] xv, input logic [31:0] yv);
    begin
      if (xv[31] != yv[31]) fp_gt = (yv[31] && !xv[31]);      // positive > negative
      else if (!xv[31])     fp_gt = (xv[30:0] > yv[30:0]);    // both >=0
      else                  fp_gt = (xv[30:0] < yv[30:0]);    // both <0
    end
  endfunction

  function automatic logic range_ok(input logic [15:0] addr, input logic [15:0] length);
    logic [31:0] bytes;
    begin
      bytes = {16'd0, length} * 32'd4;
      range_ok = (({16'd0, addr} + bytes) <= VMEM_BYTES);
    end
  endfunction

  function automatic logic signed [31:0] sign_extend_imm(input logic [15:0] imm);
    sign_extend_imm = $signed({{16{imm[15]}}, imm});
  endfunction

  function automatic logic signed [31:0] abs_i32(input logic signed [31:0] value);
    abs_i32 = (value < 0) ? -value : value;
  endfunction

  function automatic logic signed [31:0] compute_result(
    input logic signed [31:0] lhs,
    input logic signed [31:0] rhs,
    input logic [7:0] op,
    input logic [15:0] imm
  );
    logic signed [31:0] limit;
    begin
      limit = abs_i32(sign_extend_imm(imm));
      unique case (op)
        8'd0: compute_result = lhs + rhs;
        8'd1: compute_result = lhs * rhs;
        8'd2: compute_result = lhs * sign_extend_imm(imm);
        8'd3: compute_result = (lhs < 0) ? 32'sd0 : lhs;
        8'd4: begin
          if (lhs > limit) compute_result = limit;
          else if (lhs < -limit) compute_result = -limit;
          else compute_result = lhs;
        end
        8'd5: compute_result = (lhs > rhs) ? lhs : rhs;
        default: compute_result = 32'sd0;
      endcase
    end
  endfunction

  // ---- fp32 datapath (combinational; valid in the operand-WAIT states) ----
  localparam logic [31:0] FP_ONE = 32'h3F80_0000;  // 1.0f
  logic [31:0] fp_lhs, fp_rhs;
  logic [31:0] exp_arg, exp_y, denom, recip_arg, recip_y, rsqrt_y;
  logic [31:0] fadd_y, fmul_b, fmul_y, fp_result;

  // freshly-read operand in the WAIT cycle, else the latched value
  assign fp_lhs = (state_q == ST_READ0_WAIT) ? vmem_resp.rdata : lhs_q;
  assign fp_rhs = (state_q == ST_READ1_WAIT) ? vmem_resp.rdata : rhs_q;

  // exp arg: e^x for FEXP, e^-x for sigmoid/silu
  assign exp_arg   = (cmd_q.op == 8'd9) ? fp_lhs : {~fp_lhs[31], fp_lhs[30:0]};
  fp32_exp   u_exp   (.x(exp_arg), .y(exp_y));
  fp32_add   u_denom (.a(FP_ONE), .b(exp_y), .s(denom));        // 1 + e^-x
  assign recip_arg = (cmd_q.op == 8'd10) ? fp_lhs : denom;      // FRECIP uses x, sigmoid/silu use denom
  fp32_recip u_recip (.a(recip_arg), .y(recip_y));
  fp32_rsqrt u_rsqrt (.a(fp_lhs), .y(rsqrt_y));
  fp32_add   u_fadd  (.a(fp_lhs), .b(fp_rhs), .s(fadd_y));
  assign fmul_b    = (cmd_q.op == 8'd13) ? recip_y : fp_rhs;    // FSILU: x*sigmoid(x)
  fp32_mul   u_fmul  (.a(fp_lhs), .b(fmul_b), .p(fmul_y));

  always_comb begin
    unique case (cmd_q.op)
      8'd6:    fp_result = fadd_y;                              // FADD
      8'd7:    fp_result = fmul_y;                              // FMUL
      8'd8:    fp_result = fp_gt(fp_lhs, fp_rhs) ? fp_lhs : fp_rhs; // FMAX
      8'd9:    fp_result = exp_y;                               // FEXP
      8'd10:   fp_result = recip_y;                             // FRECIP
      8'd11:   fp_result = rsqrt_y;                             // FRSQRT
      8'd12:   fp_result = recip_y;                             // FSIGMOID
      8'd13:   fp_result = fmul_y;                              // FSILU (x * sigmoid)
      8'd14:   fp_result = fmul_y;                              // FSCALE_BCAST (x * scalar)
      8'd15:   fp_result = {f32_to_bf16(fp_rhs), f32_to_bf16(fp_lhs)}; // FQUANT_BF16 pack pair
      default: fp_result = 32'd0;
    endcase
  end

  task automatic clear_req;
    begin
      vmem_req_q <= '0;
    end
  endtask

  task automatic drive_read(input logic [31:0] addr);
    begin
      vmem_req_q <= '{valid: 1'b1, write: 1'b0, addr: addr, wdata: 32'd0, wstrb: 4'h0};
    end
  endtask

  task automatic drive_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      vmem_req_q <= '{valid: 1'b1, write: 1'b1, addr: addr, wdata: data, wstrb: 4'hF};
    end
  endtask

  task automatic enter_error(input logic [7:0] code);
    begin
      clear_req();
      state_q <= ST_ERROR;
      error_code_q <= code;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cmd_q <= '0;
      index_q <= 32'd0;
      lhs_q <= 32'sd0;
      rhs_q <= 32'sd0;
      result_q <= 32'sd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      clear_req();
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          clear_req();
          if (cmd_valid) begin
            if ((cmd.op > 8'd15) || (cmd.length == 16'd0) ||
                (op_is_quant(cmd.op) && (cmd.length[0] != 1'b0))) begin  // FQUANT length must be even
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end else if ((cmd.dst_addr[1:0] != 2'b00) ||
                         (cmd.src0_addr[1:0] != 2'b00) ||
                         (op_reads_src1(cmd.op) && (cmd.src1_addr[1:0] != 2'b00))) begin
              enter_error(vtpu_pkg::ERR_UNALIGNED);
            end else if (!range_ok(cmd.dst_addr, out_words(cmd.op, cmd.length)[15:0]) ||
                         !range_ok(cmd.src0_addr, cmd.length) ||
                         // FSCALE_BCAST reads only src1[0]; other binary ops read length elements
                         (op_reads_src1(cmd.op) &&
                          !range_ok(cmd.src1_addr, (cmd.op == 8'd14) ? 16'd1 : cmd.length))) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              cmd_q <= cmd;
              index_q <= 32'd0;
              state_q <= ST_READ0_REQ;
            end
          end
        end
        ST_READ0_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ0_WAIT;
          end else begin
            // FQUANT reads two consecutive fp32 from src0 (pair 2*index, 2*index+1)
            drive_read({16'd0, cmd_q.src0_addr} +
                       (op_is_quant(cmd_q.op) ? (index_q * 32'd8) : (index_q * 32'd4)));
          end
        end
        ST_READ0_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              lhs_q <= $signed(vmem_resp.rdata);
              if (op_needs_rhs(cmd_q.op)) begin
                state_q <= ST_READ1_REQ;
              end else begin
                // unary: fp ops use the combinational fp_result (fp_lhs == fresh rdata here)
                result_q <= op_is_fp(cmd_q.op)
                            ? fp_result
                            : compute_result($signed(vmem_resp.rdata), 32'sd0, cmd_q.op, cmd_q.imm);
                state_q <= ST_WRITE_REQ;
              end
            end
          end
        end
        ST_READ1_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ1_WAIT;
          end else begin
            // FQUANT: second fp32 of the pair from src0 (2*index+1); FSCALE_BCAST: src1[0];
            // other binary ops: src1 indexed elementwise
            if (op_is_quant(cmd_q.op))
              drive_read({16'd0, cmd_q.src0_addr} + (index_q * 32'd8) + 32'd4);
            else
              drive_read({16'd0, cmd_q.src1_addr} +
                         ((cmd_q.op == 8'd14) ? 32'd0 : (index_q * 32'd4)));
          end
        end
        ST_READ1_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              rhs_q <= $signed(vmem_resp.rdata);
              // binary: fp ops use fp_result (fp_lhs==lhs_q, fp_rhs==fresh rdata here)
              result_q <= op_is_fp(cmd_q.op)
                          ? fp_result
                          : compute_result(lhs_q, $signed(vmem_resp.rdata), cmd_q.op, cmd_q.imm);
              state_q <= ST_WRITE_REQ;
            end
          end
        end
        ST_WRITE_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_WRITE_WAIT;
          end else begin
            drive_write({16'd0, cmd_q.dst_addr} + (index_q * 32'd4), result_q);
          end
        end
        ST_WRITE_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else if (index_q == (out_words(cmd_q.op, cmd_q.length) - 32'd1)) begin
              state_q <= ST_DONE;
            end else begin
              index_q <= index_q + 32'd1;
              state_q <= ST_READ0_REQ;
            end
          end
        end
        ST_DONE: begin
          clear_req();
          state_q <= ST_IDLE;
        end
        ST_ERROR: begin
          clear_req();
        end
        default: begin
          enter_error(vtpu_pkg::ERR_UNSUPPORTED);
        end
      endcase
    end
  end
endmodule
