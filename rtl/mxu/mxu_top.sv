// Module: mxu_top
// Purpose: VMEM-backed int8/int32 and simulation BF16/FP32 matrix unit command wrapper.
// Public TPU inspiration: TensorCores dispatch matrix commands to MXU units.
// Educational simplification: The backing datapath performs one scalar multiply-accumulate at a time.
// Inputs: mxu_cmd_t command and VMEM response.
// Outputs: VMEM request and unit_status_t.
// State: IDLE -> optional C read -> A/B element reads -> C write -> DONE/ERROR.
// Latency: Memory-response dependent; ARRAY_M*ARRAY_N*ARRAY_K scalar MACs.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Unsupported dimensions, bad bounds, or VMEM response errors enter ERROR.
module mxu_top #(
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W = 8,
  parameter int ACC_W = 32,
  parameter int VMEM_BYTES = 262144
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mxu_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,

  output vtpu_pkg::vmem_req_t vmem_req,
  input  vtpu_pkg::vmem_resp_t vmem_resp,

  output vtpu_pkg::unit_status_t status
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_READ_C_REQ,
    ST_READ_C_WAIT,
    ST_READ_A_REQ,
    ST_READ_A_WAIT,
    ST_READ_B_REQ,
    ST_READ_B_WAIT,
    ST_WRITE_C_REQ,
    ST_WRITE_C_WAIT,
    ST_DONE,
    ST_ERROR
  } state_t;

  localparam logic [15:0] ARRAY_M_U16 = ARRAY_M[15:0];
  localparam logic [15:0] ARRAY_N_U16 = ARRAY_N[15:0];
  localparam logic [15:0] ARRAY_K_U16 = ARRAY_K[15:0];

  state_t state_q;
  vtpu_pkg::mxu_cmd_t cmd_q;
  logic [15:0] row_q;
  logic [15:0] col_q;
  logic [15:0] k_q;
  logic signed [DATA_W-1:0] a_q;
  logic signed [ACC_W-1:0] acc_q;
  real a_f32_q;
  real acc_f32_q;
  logic [1:0] byte_sel_q;
  logic [7:0] error_code_q;
  vtpu_pkg::vmem_req_t vmem_req_q;

  assign vmem_req = vmem_req_q;
  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? error_code_q : vtpu_pkg::ERR_NONE;

  function automatic logic [31:0] a_addr(input logic [15:0] row, input logic [15:0] kk);
    logic [31:0] elem_idx;
    begin
      elem_idx = ({16'd0, row} * {16'd0, cmd_q.k}) + {16'd0, kk};
      a_addr = {16'd0, cmd_q.a_addr} + (cmd_q.bf16 ? (elem_idx * 32'd2) : elem_idx);
    end
  endfunction

  function automatic logic [31:0] b_addr(input logic [15:0] kk, input logic [15:0] col);
    logic [31:0] elem_idx;
    begin
      elem_idx = ({16'd0, kk} * {16'd0, cmd_q.n}) + {16'd0, col};
      b_addr = {16'd0, cmd_q.b_addr} + (cmd_q.bf16 ? (elem_idx * 32'd2) : elem_idx);
    end
  endfunction

  function automatic logic [31:0] c_addr(input logic [15:0] row, input logic [15:0] col);
    c_addr = {16'd0, cmd_q.dst_addr} + ((({16'd0, row} * {16'd0, cmd_q.n}) + {16'd0, col}) * 32'd4);
  endfunction

  function automatic logic [31:0] align_word(input logic [31:0] addr);
    align_word = {addr[31:2], 2'b00};
  endfunction

  function automatic logic signed [7:0] select_i8(input logic [31:0] word, input logic [1:0] sel);
    unique case (sel)
      2'd0: select_i8 = $signed(word[7:0]);
      2'd1: select_i8 = $signed(word[15:8]);
      2'd2: select_i8 = $signed(word[23:16]);
      default: select_i8 = $signed(word[31:24]);
    endcase
  endfunction

  function automatic logic [15:0] select_u16(input logic [31:0] word, input logic sel);
    select_u16 = sel ? word[31:16] : word[15:0];
  endfunction

  function automatic real f32_bits_to_real(input logic [31:0] bits);
    int unsigned exp;
    int unsigned mant;
    int shift;
    real value;
    begin
      exp = {24'd0, bits[30:23]};
      mant = {9'd0, bits[22:0]};
      if (exp == 0 && mant == 0) begin
        value = 0.0;
      end else if (exp == 0) begin
        value = real'(mant) / 8388608.0;
        shift = -126;
        while (shift < 0) begin
          value = value / 2.0;
          shift = shift + 1;
        end
      end else begin
        value = 1.0 + (real'(mant) / 8388608.0);
        shift = int'(exp) - 127;
        while (shift > 0) begin
          value = value * 2.0;
          shift = shift - 1;
        end
        while (shift < 0) begin
          value = value / 2.0;
          shift = shift + 1;
        end
      end
      f32_bits_to_real = bits[31] ? -value : value;
    end
  endfunction

  function automatic real bf16_to_f32(input logic [15:0] bits);
    bf16_to_f32 = f32_bits_to_real({bits, 16'h0000});
  endfunction

  function automatic logic [31:0] real_to_f32_bits(input real value);
    logic sign;
    int exp;
    int unsigned exp_bits;
    int unsigned mant;
    real magnitude;
    real normalized;
    real scaled;
    begin
      if (value == 0.0) begin
        real_to_f32_bits = 32'd0;
      end else begin
        sign = value < 0.0;
        magnitude = sign ? -value : value;
        exp = 0;
        normalized = magnitude;
        while (normalized >= 2.0) begin
          normalized = normalized / 2.0;
          exp = exp + 1;
        end
        while (normalized < 1.0) begin
          normalized = normalized * 2.0;
          exp = exp - 1;
        end
        scaled = (normalized - 1.0) * 8388608.0;
        mant = int'(scaled + 0.5);
        if (mant >= 8388608) begin
          mant = 0;
          exp = exp + 1;
        end
        exp_bits = exp + 127;
        real_to_f32_bits = {sign, exp_bits[7:0], mant[22:0]};
      end
    end
  endfunction

  function automatic logic dimensions_ok(input vtpu_pkg::mxu_cmd_t local_cmd);
    dimensions_ok = (local_cmd.m != 16'd0) &&
                    (local_cmd.n != 16'd0) &&
                    (local_cmd.k != 16'd0) &&
                    (local_cmd.m <= ARRAY_M_U16) &&
                    (local_cmd.n <= ARRAY_N_U16) &&
                    (local_cmd.k <= ARRAY_K_U16);
  endfunction

  function automatic logic ranges_ok(input vtpu_pkg::mxu_cmd_t local_cmd);
    logic [31:0] a_bytes;
    logic [31:0] b_bytes;
    logic [31:0] c_bytes;
    begin
      a_bytes = {16'd0, local_cmd.m} * {16'd0, local_cmd.k} * (local_cmd.bf16 ? 32'd2 : 32'd1);
      b_bytes = {16'd0, local_cmd.k} * {16'd0, local_cmd.n} * (local_cmd.bf16 ? 32'd2 : 32'd1);
      c_bytes = {16'd0, local_cmd.m} * {16'd0, local_cmd.n} * 32'd4;
      ranges_ok = (({16'd0, local_cmd.a_addr} + a_bytes) <= VMEM_BYTES) &&
                  (({16'd0, local_cmd.b_addr} + b_bytes) <= VMEM_BYTES) &&
                  (({16'd0, local_cmd.dst_addr} + c_bytes) <= VMEM_BYTES) &&
                  (local_cmd.dst_addr[1:0] == 2'b00) &&
                  (!local_cmd.bf16 || ((local_cmd.a_addr[0] == 1'b0) && (local_cmd.b_addr[0] == 1'b0)));
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

  task automatic advance_element;
    begin
      k_q <= 16'd0;
      acc_q <= 32'sd0;
      acc_f32_q <= 0.0;
      if ((row_q == (cmd_q.m - 16'd1)) && (col_q == (cmd_q.n - 16'd1))) begin
        state_q <= ST_DONE;
      end else if (col_q == (cmd_q.n - 16'd1)) begin
        col_q <= 16'd0;
        row_q <= row_q + 16'd1;
        state_q <= cmd_q.accumulate ? ST_READ_C_REQ : ST_READ_A_REQ;
      end else begin
        col_q <= col_q + 16'd1;
        state_q <= cmd_q.accumulate ? ST_READ_C_REQ : ST_READ_A_REQ;
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    logic [31:0] byte_addr;
    logic signed [7:0] b_value;
    logic [15:0] b_bf16;
    logic signed [ACC_W-1:0] next_acc;
    real b_f32;
    real next_acc_f32;

    if (!rst_n) begin
      state_q <= ST_IDLE;
      cmd_q <= '0;
      row_q <= 16'd0;
      col_q <= 16'd0;
      k_q <= 16'd0;
      a_q <= '0;
      acc_q <= '0;
      a_f32_q <= 0.0;
      acc_f32_q <= 0.0;
      byte_sel_q <= 2'd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      clear_req();
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          clear_req();
          if (cmd_valid) begin
            if (!dimensions_ok(cmd)) begin
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end else if (!ranges_ok(cmd)) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              cmd_q <= cmd;
              row_q <= 16'd0;
              col_q <= 16'd0;
              k_q <= 16'd0;
              acc_q <= 32'sd0;
              acc_f32_q <= 0.0;
              state_q <= cmd.accumulate ? ST_READ_C_REQ : ST_READ_A_REQ;
            end
          end
        end
        ST_READ_C_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ_C_WAIT;
          end else begin
            drive_read(c_addr(row_q, col_q));
          end
        end
        ST_READ_C_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              if (cmd_q.bf16) begin
                acc_f32_q <= f32_bits_to_real(vmem_resp.rdata);
              end else begin
                acc_q <= $signed(vmem_resp.rdata);
              end
              state_q <= ST_READ_A_REQ;
            end
          end
        end
        ST_READ_A_REQ: begin
          byte_addr = a_addr(row_q, k_q);
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ_A_WAIT;
          end else begin
            byte_sel_q <= byte_addr[1:0];
            drive_read(align_word(byte_addr));
          end
        end
        ST_READ_A_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              if (cmd_q.bf16) begin
                a_f32_q <= bf16_to_f32(select_u16(vmem_resp.rdata, byte_sel_q[1]));
              end else begin
                a_q <= select_i8(vmem_resp.rdata, byte_sel_q);
              end
              state_q <= ST_READ_B_REQ;
            end
          end
        end
        ST_READ_B_REQ: begin
          byte_addr = b_addr(k_q, col_q);
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_READ_B_WAIT;
          end else begin
            byte_sel_q <= byte_addr[1:0];
            drive_read(align_word(byte_addr));
          end
        end
        ST_READ_B_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              if (cmd_q.bf16) begin
                b_bf16 = select_u16(vmem_resp.rdata, byte_sel_q[1]);
                b_f32 = bf16_to_f32(b_bf16);
                next_acc_f32 = acc_f32_q + (a_f32_q * b_f32);
                acc_f32_q <= next_acc_f32;
              end else begin
                b_value = select_i8(vmem_resp.rdata, byte_sel_q);
                next_acc = acc_q + (a_q * b_value);
                acc_q <= next_acc;
              end
              if (k_q == (cmd_q.k - 16'd1)) begin
                state_q <= ST_WRITE_C_REQ;
              end else begin
                k_q <= k_q + 16'd1;
                state_q <= ST_READ_A_REQ;
              end
            end
          end
        end
        ST_WRITE_C_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin
            clear_req();
            state_q <= ST_WRITE_C_WAIT;
          end else begin
            if (cmd_q.bf16) begin
              drive_write(c_addr(row_q, col_q), real_to_f32_bits(acc_f32_q));
            end else begin
              drive_write(c_addr(row_q, col_q), acc_q);
            end
          end
        end
        ST_WRITE_C_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              advance_element();
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
