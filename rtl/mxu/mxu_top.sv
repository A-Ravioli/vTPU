// Module: mxu_top
// Purpose: VMEM-backed matrix unit. Loads A/B (and C for accumulate) tiles from VMEM once,
//   runs a parallel systolic array (int8 or bf16), then stores the C tile back.
// Public TPU inspiration: TensorCores stream operand tiles into a PE array that computes in parallel.
// Why this shape: the previous scalar engine re-read operands m*n*k times and did one MAC per
//   ~6 cycles; loading each element once and using the array drops cycles-per-tile by ~10-30x.
// Inputs: mxu_cmd_t command and VMEM response.
// Outputs: VMEM request and unit_status_t.
// State: IDLE -> LOAD_A -> LOAD_B -> (LOAD_C) -> RUN -> STORE_C -> DONE/ERROR.
// Numerics: int8->int32 (systolic_array) or bf16->fp32 (systolic_array_bf16), output-stationary,
//   so each output accumulates products sequentially over k (bit-identical to the unit tests).
// Backpressure: cmd_ready high only in IDLE.
// Error behavior: bad dims/bounds or VMEM response errors enter ERROR.
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
    ST_LOAD_A_REQ, ST_LOAD_A_WAIT,
    ST_LOAD_B_REQ, ST_LOAD_B_WAIT,
    ST_LOAD_C_REQ, ST_LOAD_C_WAIT,
    ST_RUN_START,  ST_RUN_WAIT,
    ST_STORE_REQ,  ST_STORE_WAIT,
    ST_DONE, ST_ERROR
  } state_t;

  localparam logic [15:0] ARRAY_M_U16 = ARRAY_M[15:0];
  localparam logic [15:0] ARRAY_N_U16 = ARRAY_N[15:0];
  localparam logic [15:0] ARRAY_K_U16 = ARRAY_K[15:0];

  state_t state_q;
  vtpu_pkg::mxu_cmd_t cmd_q;
  logic [15:0] cnt_i_q;     // outer load/store counter
  logic [15:0] cnt_j_q;     // inner load/store counter
  logic [1:0]  byte_sel_q;
  logic [7:0]  error_code_q;
  vtpu_pkg::vmem_req_t vmem_req_q;

  // operand / result tiles (held stable while the array computes)
  logic signed [DATA_W-1:0] a_tile_i8 [0:ARRAY_M*ARRAY_K-1];
  logic signed [DATA_W-1:0] b_tile_i8 [0:ARRAY_K*ARRAY_N-1];
  logic signed [ACC_W-1:0]  c_in_i8   [0:ARRAY_M*ARRAY_N-1];
  logic signed [ACC_W-1:0]  c_out_i8  [0:ARRAY_M*ARRAY_N-1];
  logic [15:0] a_tile_bf [0:ARRAY_M*ARRAY_K-1];
  logic [15:0] b_tile_bf [0:ARRAY_K*ARRAY_N-1];
  logic [31:0] c_in_bf   [0:ARRAY_M*ARRAY_N-1];
  logic [31:0] c_out_bf  [0:ARRAY_M*ARRAY_N-1];

  logic array_start_q;
  logic start_i8, start_bf;
  logic busy_i8, done_i8, err_i8;
  logic busy_bf, done_bf, err_bf;
  logic [7:0] ec_i8, ec_bf;
  logic array_done;

  assign vmem_req = vmem_req_q;
  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? error_code_q : vtpu_pkg::ERR_NONE;

  assign start_i8 = array_start_q && !cmd_q.bf16;
  assign start_bf = array_start_q && cmd_q.bf16;
  assign array_done = cmd_q.bf16 ? done_bf : done_i8;

  // ---- addressing (identical element layout to the previous scalar engine) ----
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
      elem_idx = cmd_q.transpose_b
                 ? (({16'd0, col} * {16'd0, cmd_q.k}) + {16'd0, kk})
                 : (({16'd0, kk} * {16'd0, cmd_q.n}) + {16'd0, col});
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

  function automatic logic dimensions_ok(input vtpu_pkg::mxu_cmd_t lc);
    dimensions_ok = (lc.m != 16'd0) && (lc.n != 16'd0) && (lc.k != 16'd0) &&
                    (lc.m <= ARRAY_M_U16) && (lc.n <= ARRAY_N_U16) && (lc.k <= ARRAY_K_U16);
  endfunction

  function automatic logic ranges_ok(input vtpu_pkg::mxu_cmd_t lc);
    logic [31:0] a_bytes, b_bytes, c_bytes;
    begin
      a_bytes = {16'd0, lc.m} * {16'd0, lc.k} * (lc.bf16 ? 32'd2 : 32'd1);
      b_bytes = {16'd0, lc.k} * {16'd0, lc.n} * (lc.bf16 ? 32'd2 : 32'd1);
      c_bytes = {16'd0, lc.m} * {16'd0, lc.n} * 32'd4;
      ranges_ok = (({16'd0, lc.a_addr} + a_bytes) <= VMEM_BYTES) &&
                  (({16'd0, lc.b_addr} + b_bytes) <= VMEM_BYTES) &&
                  (({16'd0, lc.dst_addr} + c_bytes) <= VMEM_BYTES) &&
                  (lc.dst_addr[1:0] == 2'b00) &&
                  (!lc.bf16 || ((lc.a_addr[0] == 1'b0) && (lc.b_addr[0] == 1'b0)));
    end
  endfunction

  task automatic clear_req; begin vmem_req_q <= '0; end endtask
  task automatic drive_read(input logic [31:0] addr);
    begin vmem_req_q <= '{valid: 1'b1, write: 1'b0, addr: addr, wdata: 32'd0, wstrb: 4'h0}; end
  endtask
  task automatic drive_write(input logic [31:0] addr, input logic [31:0] data);
    begin vmem_req_q <= '{valid: 1'b1, write: 1'b1, addr: addr, wdata: data, wstrb: 4'hF}; end
  endtask
  task automatic enter_error(input logic [7:0] code);
    begin clear_req(); state_q <= ST_ERROR; error_code_q <= code; end
  endtask

  // array index helpers
  function automatic int unsigned a_idx(input logic [15:0] row, input logic [15:0] kk);
    a_idx = (int'(row) * ARRAY_K) + int'(kk);
  endfunction
  function automatic int unsigned bn_idx(input logic [15:0] kk, input logic [15:0] col);
    bn_idx = (int'(kk) * ARRAY_N) + int'(col);
  endfunction

  systolic_array #(
    .ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N), .ARRAY_K(ARRAY_K), .DATA_W(DATA_W), .ACC_W(ACC_W)
  ) u_arr_i8 (
    .clk(clk), .rst_n(rst_n), .start(start_i8), .accumulate(cmd_q.accumulate),
    .m(cmd_q.m), .n(cmd_q.n), .k(cmd_q.k),
    .a_tile(a_tile_i8), .b_tile(b_tile_i8), .c_in(c_in_i8), .c_out(c_out_i8),
    .busy(busy_i8), .done(done_i8), .error(err_i8), .error_code(ec_i8)
  );

  systolic_array_bf16 #(
    .ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N), .ARRAY_K(ARRAY_K)
  ) u_arr_bf (
    .clk(clk), .rst_n(rst_n), .start(start_bf), .accumulate(cmd_q.accumulate),
    .m(cmd_q.m), .n(cmd_q.n), .k(cmd_q.k),
    .a_tile(a_tile_bf), .b_tile(b_tile_bf), .c_in(c_in_bf), .c_out(c_out_bf),
    .busy(busy_bf), .done(done_bf), .error(err_bf), .error_code(ec_bf)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    logic [31:0] byte_addr;
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cmd_q <= '0;
      cnt_i_q <= 16'd0;
      cnt_j_q <= 16'd0;
      byte_sel_q <= 2'd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      array_start_q <= 1'b0;
      clear_req();
    end else begin
      array_start_q <= 1'b0;
      unique case (state_q)
        ST_IDLE: begin
          clear_req();
          if (cmd_valid) begin
            if (!dimensions_ok(cmd)) enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            else if (!ranges_ok(cmd)) enter_error(vtpu_pkg::ERR_BAD_ADDR);
            else begin
              cmd_q <= cmd;
              cnt_i_q <= 16'd0;
              cnt_j_q <= 16'd0;
              state_q <= ST_LOAD_A_REQ;
            end
          end
        end

        // ---- load A: row=cnt_i (0..m-1), kk=cnt_j (0..k-1) ----
        ST_LOAD_A_REQ: begin
          byte_addr = a_addr(cnt_i_q, cnt_j_q);
          if (vmem_req_q.valid && vmem_resp.ready) begin clear_req(); state_q <= ST_LOAD_A_WAIT; end
          else begin byte_sel_q <= byte_addr[1:0]; drive_read(align_word(byte_addr)); end
        end
        ST_LOAD_A_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) enter_error(vtpu_pkg::ERR_BAD_ADDR);
            else begin
              if (cmd_q.bf16) a_tile_bf[a_idx(cnt_i_q, cnt_j_q)] <= select_u16(vmem_resp.rdata, byte_sel_q[1]);
              else            a_tile_i8[a_idx(cnt_i_q, cnt_j_q)] <= select_i8(vmem_resp.rdata, byte_sel_q);
              if (cnt_j_q == (cmd_q.k - 16'd1)) begin
                cnt_j_q <= 16'd0;
                if (cnt_i_q == (cmd_q.m - 16'd1)) begin cnt_i_q <= 16'd0; state_q <= ST_LOAD_B_REQ; end
                else cnt_i_q <= cnt_i_q + 16'd1;
              end else cnt_j_q <= cnt_j_q + 16'd1;
              if (!((cnt_j_q == (cmd_q.k - 16'd1)) && (cnt_i_q == (cmd_q.m - 16'd1))))
                state_q <= ST_LOAD_A_REQ;
            end
          end
        end

        // ---- load B: kk=cnt_i (0..k-1), col=cnt_j (0..n-1) ----
        ST_LOAD_B_REQ: begin
          byte_addr = b_addr(cnt_i_q, cnt_j_q);
          if (vmem_req_q.valid && vmem_resp.ready) begin clear_req(); state_q <= ST_LOAD_B_WAIT; end
          else begin byte_sel_q <= byte_addr[1:0]; drive_read(align_word(byte_addr)); end
        end
        ST_LOAD_B_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) enter_error(vtpu_pkg::ERR_BAD_ADDR);
            else begin
              if (cmd_q.bf16) b_tile_bf[bn_idx(cnt_i_q, cnt_j_q)] <= select_u16(vmem_resp.rdata, byte_sel_q[1]);
              else            b_tile_i8[bn_idx(cnt_i_q, cnt_j_q)] <= select_i8(vmem_resp.rdata, byte_sel_q);
              if (cnt_j_q == (cmd_q.n - 16'd1)) begin
                cnt_j_q <= 16'd0;
                if (cnt_i_q == (cmd_q.k - 16'd1)) begin
                  cnt_i_q <= 16'd0;
                  state_q <= cmd_q.accumulate ? ST_LOAD_C_REQ : ST_RUN_START;
                end else cnt_i_q <= cnt_i_q + 16'd1;
              end else cnt_j_q <= cnt_j_q + 16'd1;
              if (!((cnt_j_q == (cmd_q.n - 16'd1)) && (cnt_i_q == (cmd_q.k - 16'd1))))
                state_q <= ST_LOAD_B_REQ;
            end
          end
        end

        // ---- load C (accumulate): row=cnt_i (0..m-1), col=cnt_j (0..n-1) ----
        ST_LOAD_C_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin clear_req(); state_q <= ST_LOAD_C_WAIT; end
          else drive_read(c_addr(cnt_i_q, cnt_j_q));
        end
        ST_LOAD_C_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) enter_error(vtpu_pkg::ERR_BAD_ADDR);
            else begin
              if (cmd_q.bf16) c_in_bf[bn_idx(cnt_i_q, cnt_j_q)] <= vmem_resp.rdata;
              else            c_in_i8[bn_idx(cnt_i_q, cnt_j_q)] <= $signed(vmem_resp.rdata);
              if (cnt_j_q == (cmd_q.n - 16'd1)) begin
                cnt_j_q <= 16'd0;
                if (cnt_i_q == (cmd_q.m - 16'd1)) begin cnt_i_q <= 16'd0; state_q <= ST_RUN_START; end
                else cnt_i_q <= cnt_i_q + 16'd1;
              end else cnt_j_q <= cnt_j_q + 16'd1;
              if (!((cnt_j_q == (cmd_q.n - 16'd1)) && (cnt_i_q == (cmd_q.m - 16'd1))))
                state_q <= ST_LOAD_C_REQ;
            end
          end
        end

        // ---- run the array ----
        ST_RUN_START: begin
          clear_req();
          array_start_q <= 1'b1;     // 1-cycle start pulse to the selected array
          state_q <= ST_RUN_WAIT;
        end
        ST_RUN_WAIT: begin
          clear_req();
          if (array_done) begin
            cnt_i_q <= 16'd0;
            cnt_j_q <= 16'd0;
            state_q <= ST_STORE_REQ;
          end
        end

        // ---- store C: row=cnt_i (0..m-1), col=cnt_j (0..n-1) ----
        ST_STORE_REQ: begin
          if (vmem_req_q.valid && vmem_resp.ready) begin clear_req(); state_q <= ST_STORE_WAIT; end
          else begin
            if (cmd_q.bf16)
              drive_write(c_addr(cnt_i_q, cnt_j_q), c_out_bf[bn_idx(cnt_i_q, cnt_j_q)]);
            else
              drive_write(c_addr(cnt_i_q, cnt_j_q), c_out_i8[bn_idx(cnt_i_q, cnt_j_q)]);
          end
        end
        ST_STORE_WAIT: begin
          clear_req();
          if (vmem_resp.valid) begin
            if (vmem_resp.error) enter_error(vtpu_pkg::ERR_BAD_ADDR);
            else begin
              if (cnt_j_q == (cmd_q.n - 16'd1)) begin
                cnt_j_q <= 16'd0;
                if (cnt_i_q == (cmd_q.m - 16'd1)) state_q <= ST_DONE;
                else begin cnt_i_q <= cnt_i_q + 16'd1; state_q <= ST_STORE_REQ; end
              end else begin cnt_j_q <= cnt_j_q + 16'd1; state_q <= ST_STORE_REQ; end
            end
          end
        end

        ST_DONE: begin clear_req(); state_q <= ST_IDLE; end
        ST_ERROR: begin clear_req(); end
        default: enter_error(vtpu_pkg::ERR_UNSUPPORTED);
      endcase
    end
  end
endmodule
