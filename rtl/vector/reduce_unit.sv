// Module: reduce_unit
// Purpose: VMEM-connected datapath for documented int32 reductions.
// Public TPU inspiration: TensorCore-adjacent units perform reductions for ML kernels.
// Educational simplification: One scalar input is processed at a time through a 32-bit VMEM port.
// Inputs: reduce_cmd_t command and VMEM response.
// Outputs: VMEM request and unit status.
// State: IDLE -> read input/prior -> write partial/final -> DONE/ERROR.
// Latency: Memory-response dependent, one element at a time.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Unsupported op, bad shape, alignment, bounds, or VMEM errors enter ERROR.
module reduce_unit #(
  parameter int LANES = 16,
  parameter int VMEM_BYTES = 262144
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::reduce_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  output vtpu_pkg::vmem_req_t vmem_req,
  input  vtpu_pkg::vmem_resp_t vmem_resp,
  output vtpu_pkg::unit_status_t status
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_READ_VALUE_REQ,
    ST_READ_VALUE_WAIT,
    ST_READ_PRIOR_REQ,
    ST_READ_PRIOR_WAIT,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;
  vtpu_pkg::reduce_cmd_t cmd_q;
  logic [31:0] index_q;
  logic signed [31:0] acc_q;
  logic signed [31:0] value_q;
  logic signed [31:0] write_value_q;
  logic [31:0] write_addr_q;
  logic [7:0] error_code_q;
  vtpu_pkg::vmem_req_t vmem_req_q;

  assign vmem_req = vmem_req_q;
  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? error_code_q : vtpu_pkg::ERR_NONE;

  // int row/col ops (2-5) plus fp row ops (9,10) need a column count and per-group output.
  function automatic logic row_col_op(input logic [7:0] op);
    row_col_op = ((op >= 8'd2) && (op <= 8'd5)) || (op == 8'd9) || (op == 8'd10);
  endfunction

  // fp reductions: FSUM_ALL(6),FMAX_ALL(7),FSUMSQ_ALL(8),FSUM_ROWS(9),FMAX_ROWS(10)
  function automatic logic op_is_fp(input logic [7:0] op);
    op_is_fp = (op >= 8'd6) && (op <= 8'd10);
  endfunction

  // whole-buffer reductions accumulate into one scalar: SUM_ALL/MAX_ALL + FSUM/FMAX/FSUMSQ_ALL
  function automatic logic is_all_op(input logic [7:0] op);
    is_all_op = (op <= 8'd1) || ((op >= 8'd6) && (op <= 8'd8));
  endfunction

  // fp max ops (FMAX_ALL=7, FMAX_ROWS=10) reduce by maximum; others by sum
  function automatic logic op_is_max(input logic [7:0] op);
    op_is_max = (op == 8'd7) || (op == 8'd10);
  endfunction

  function automatic logic fp_gt(input logic [31:0] xv, input logic [31:0] yv);
    begin
      if (xv[31] != yv[31]) fp_gt = (yv[31] && !xv[31]);
      else if (!xv[31])     fp_gt = (xv[30:0] > yv[30:0]);
      else                  fp_gt = (xv[30:0] < yv[30:0]);
    end
  endfunction

  function automatic logic [31:0] rows(input logic [15:0] length, input logic [15:0] columns);
    rows = (columns == 16'd0) ? 32'd0 : ({16'd0, length} / {16'd0, columns});
  endfunction

  function automatic logic [31:0] output_length(input logic [7:0] op, input logic [15:0] length, input logic [15:0] columns);
    if (is_all_op(op)) begin
      output_length = 32'd1;
    end else if ((op == 8'd2) || (op == 8'd3) || (op == 8'd9) || (op == 8'd10)) begin
      output_length = rows(length, columns);
    end else begin
      output_length = {16'd0, columns};
    end
  endfunction

  function automatic logic range_ok(input logic [15:0] addr, input logic [31:0] words);
    range_ok = (({16'd0, addr} + (words * 32'd4)) <= VMEM_BYTES);
  endfunction

  function automatic logic shape_ok(input vtpu_pkg::reduce_cmd_t local_cmd);
    shape_ok = (local_cmd.op <= 8'd10) &&
               (local_cmd.length != 16'd0) &&
               (!row_col_op(local_cmd.op) ||
                ((local_cmd.columns != 16'd0) &&
                 ((local_cmd.length % local_cmd.columns) == 16'd0)));
  endfunction

  function automatic logic [31:0] col_index(input logic [31:0] idx, input logic [15:0] columns);
    col_index = (columns == 16'd0) ? 32'd0 : (idx % {16'd0, columns});
  endfunction

  function automatic logic [31:0] row_index(input logic [31:0] idx, input logic [15:0] columns);
    row_index = (columns == 16'd0) ? 32'd0 : (idx / {16'd0, columns});
  endfunction

  function automatic logic first_in_group(input logic [7:0] op, input logic [31:0] idx, input logic [15:0] columns);
    if ((op == 8'd2) || (op == 8'd3) || (op == 8'd9) || (op == 8'd10)) begin
      first_in_group = (col_index(idx, columns) == 32'd0);
    end else if ((op == 8'd4) || (op == 8'd5)) begin
      first_in_group = (row_index(idx, columns) == 32'd0);
    end else begin
      first_in_group = (idx == 32'd0);
    end
  endfunction

  function automatic logic [31:0] out_index(input logic [7:0] op, input logic [31:0] idx, input logic [15:0] columns);
    if ((op == 8'd2) || (op == 8'd3) || (op == 8'd9) || (op == 8'd10)) begin
      out_index = row_index(idx, columns);
    end else if ((op == 8'd4) || (op == 8'd5)) begin
      out_index = col_index(idx, columns);
    end else begin
      out_index = 32'd0;
    end
  endfunction

  function automatic logic signed [31:0] reduce_pair(
    input logic [7:0] op,
    input logic signed [31:0] prior,
    input logic signed [31:0] value
  );
    if ((op == 8'd1) || (op == 8'd3) || (op == 8'd5)) begin
      reduce_pair = (value > prior) ? value : prior;
    end else begin
      reduce_pair = prior + value;
    end
  endfunction

  // ---- fp32 reduction datapath (combinational; valid in the relevant WAIT states) ----
  logic [31:0] fp_val_raw, fp_sq, fp_addend, fp_prior, fp_sum, fp_combined, fp_init;
  assign fp_val_raw = (state_q == ST_READ_VALUE_WAIT) ? vmem_resp.rdata : value_q;
  assign fp_prior   = (state_q == ST_READ_PRIOR_WAIT) ? vmem_resp.rdata : acc_q;
  fp32_mul u_sq  (.a(fp_val_raw), .b(fp_val_raw), .p(fp_sq));
  assign fp_addend = (cmd_q.op == 8'd8) ? fp_sq : fp_val_raw;       // FSUMSQ squares the element
  fp32_add u_sum (.a(fp_prior), .b(fp_addend), .s(fp_sum));
  assign fp_combined = op_is_max(cmd_q.op)
                       ? (fp_gt(fp_addend, fp_prior) ? fp_addend : fp_prior)
                       : fp_sum;
  assign fp_init = (cmd_q.op == 8'd8) ? fp_sq : fp_val_raw;          // first element seed

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
    logic [31:0] out_idx;
    logic first;

    if (!rst_n) begin
      state_q <= ST_IDLE;
      cmd_q <= '0;
      index_q <= 32'd0;
      acc_q <= 32'sd0;
      value_q <= 32'sd0;
      write_value_q <= 32'sd0;
      write_addr_q <= 32'd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      clear_req();
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          clear_req();
          if (cmd_valid) begin
            if (!shape_ok(cmd)) begin
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end else if ((cmd.dst_addr[1:0] != 2'b00) || (cmd.src_addr[1:0] != 2'b00)) begin
              enter_error(vtpu_pkg::ERR_UNALIGNED);
            end else if (!range_ok(cmd.src_addr, {16'd0, cmd.length}) ||
                         !range_ok(cmd.dst_addr, output_length(cmd.op, cmd.length, cmd.columns))) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              cmd_q <= cmd;
              index_q <= 32'd0;
              acc_q <= 32'sd0;
              state_q <= ST_READ_VALUE_REQ;
            end
          end
        end
        ST_READ_VALUE_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ_VALUE_WAIT;
          end else begin
            drive_read({16'd0, cmd_q.src_addr} + (index_q * 32'd4));
          end
        end
        ST_READ_VALUE_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              value_q <= $signed(vmem_resp.rdata);
              if (is_all_op(cmd_q.op)) begin
                if (index_q == 32'd0) begin
                  acc_q <= op_is_fp(cmd_q.op) ? fp_init : $signed(vmem_resp.rdata);
                end else begin
                  acc_q <= op_is_fp(cmd_q.op) ? fp_combined
                                              : reduce_pair(cmd_q.op, acc_q, $signed(vmem_resp.rdata));
                end
                if (index_q == ({16'd0, cmd_q.length} - 32'd1)) begin
                  write_addr_q <= {16'd0, cmd_q.dst_addr};
                  if (index_q == 32'd0) begin
                    write_value_q <= op_is_fp(cmd_q.op) ? fp_init : $signed(vmem_resp.rdata);
                  end else begin
                    write_value_q <= op_is_fp(cmd_q.op) ? fp_combined
                                                        : reduce_pair(cmd_q.op, acc_q, $signed(vmem_resp.rdata));
                  end
                  state_q <= ST_WRITE_REQ;
                end else begin
                  index_q <= index_q + 32'd1;
                  state_q <= ST_READ_VALUE_REQ;
                end
              end else begin
                out_idx = out_index(cmd_q.op, index_q, cmd_q.columns);
                first = first_in_group(cmd_q.op, index_q, cmd_q.columns);
                write_addr_q <= {16'd0, cmd_q.dst_addr} + (out_idx * 32'd4);
                if (first) begin
                  write_value_q <= $signed(vmem_resp.rdata);
                  state_q <= ST_WRITE_REQ;
                end else begin
                  state_q <= ST_READ_PRIOR_REQ;
                end
              end
            end
          end
        end
        ST_READ_PRIOR_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ_PRIOR_WAIT;
          end else begin
            drive_read(write_addr_q);
          end
        end
        ST_READ_PRIOR_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              write_value_q <= op_is_fp(cmd_q.op)
                               ? fp_combined
                               : reduce_pair(cmd_q.op, $signed(vmem_resp.rdata), value_q);
              state_q <= ST_WRITE_REQ;
            end
          end
        end
        ST_WRITE_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_WRITE_WAIT;
          end else begin
            drive_write(write_addr_q, write_value_q);
          end
        end
        ST_WRITE_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else if ((cmd_q.op <= 8'd1) || (index_q == ({16'd0, cmd_q.length} - 32'd1))) begin
              state_q <= ST_DONE;
            end else begin
              index_q <= index_q + 32'd1;
              state_q <= ST_READ_VALUE_REQ;
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
