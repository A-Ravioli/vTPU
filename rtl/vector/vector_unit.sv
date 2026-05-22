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

  function automatic logic op_needs_rhs(input logic [7:0] op);
    op_needs_rhs = (op == 8'd0) || (op == 8'd1) || (op == 8'd5);
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
            if ((cmd.op > 8'd5) || (cmd.length == 16'd0)) begin
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end else if ((cmd.dst_addr[1:0] != 2'b00) ||
                         (cmd.src0_addr[1:0] != 2'b00) ||
                         (op_needs_rhs(cmd.op) && (cmd.src1_addr[1:0] != 2'b00))) begin
              enter_error(vtpu_pkg::ERR_UNALIGNED);
            end else if (!range_ok(cmd.dst_addr, cmd.length) ||
                         !range_ok(cmd.src0_addr, cmd.length) ||
                         (op_needs_rhs(cmd.op) && !range_ok(cmd.src1_addr, cmd.length))) begin
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
            drive_read({16'd0, cmd_q.src0_addr} + (index_q * 32'd4));
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
                result_q <= compute_result($signed(vmem_resp.rdata), 32'sd0, cmd_q.op, cmd_q.imm);
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
            drive_read({16'd0, cmd_q.src1_addr} + (index_q * 32'd4));
          end
        end
        ST_READ1_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              rhs_q <= $signed(vmem_resp.rdata);
              result_q <= compute_result(lhs_q, $signed(vmem_resp.rdata), cmd_q.op, cmd_q.imm);
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
            end else if (index_q == ({16'd0, cmd_q.length} - 32'd1)) begin
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
