// Module: systolic_array_bf16
// Purpose: Parameterized output-stationary bf16 x bf16 -> fp32 PE-grid tile multiply block.
// Public TPU inspiration: bf16 matrix units multiply in bf16 and accumulate partial sums in fp32.
// Educational simplification: The grid is output-stationary and advances one K slice per two cycles.
// Inputs: start, accumulate, flattened bf16 A/B tiles and fp32 C tile.
// Outputs: flattened fp32 C tile plus busy/done/error status.
// Numerics: each output accumulates products sequentially over k in fp32 RNE (see pe_bf16),
//           so results are bit-identical to a sequential fp32 dot product in the same k order.
// State: IDLE -> FEED -> CAPTURE -> DONE or ERROR.
// Tests: tests/cocotb/test_systolic_bf16.py compares against a sequential fp32 numpy reference.
module systolic_array_bf16 #(
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16
)(
  input  logic clk,
  input  logic rst_n,

  input  logic start,
  input  logic accumulate,
  input  logic [15:0] m,
  input  logic [15:0] n,
  input  logic [15:0] k,

  input  logic [15:0] a_tile [0:ARRAY_M*ARRAY_K-1],   // bf16
  input  logic [15:0] b_tile [0:ARRAY_K*ARRAY_N-1],   // bf16
  input  logic [31:0] c_in   [0:ARRAY_M*ARRAY_N-1],   // fp32
  output logic [31:0] c_out  [0:ARRAY_M*ARRAY_N-1],   // fp32

  output logic busy,
  output logic done,
  output logic error,
  output logic [7:0] error_code
);
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_FEED,
    ST_CAPTURE,
    ST_DONE,
    ST_ERROR
  } state_t;

  localparam logic [15:0] ARRAY_M_U16 = ARRAY_M[15:0];
  localparam logic [15:0] ARRAY_N_U16 = ARRAY_N[15:0];
  localparam logic [15:0] ARRAY_K_U16 = ARRAY_K[15:0];

  state_t state_q;
  logic [15:0] k_idx_q;
  logic [31:0] k_idx_ext;
  logic pe_valid_in;
  logic pe_valid_out [0:ARRAY_M*ARRAY_N-1];
  logic [31:0] acc_q [0:ARRAY_M*ARRAY_N-1];
  logic [31:0] pe_acc_out [0:ARRAY_M*ARRAY_N-1];
  logic [15:0] pe_a_out [0:ARRAY_M*ARRAY_N-1];
  logic [15:0] pe_b_out [0:ARRAY_M*ARRAY_N-1];
  integer comb_idx;
  integer reset_idx;
  integer start_idx;
  integer capture_idx;

  assign k_idx_ext = {16'd0, k_idx_q};

  genvar row_g;
  genvar col_g;
  generate
    for (row_g = 0; row_g < ARRAY_M; row_g++) begin : gen_rows
      for (col_g = 0; col_g < ARRAY_N; col_g++) begin : gen_cols
        localparam int PE_IDX = (row_g * ARRAY_N) + col_g;
        pe_bf16 u_pe (
          .clk(clk),
          .rst_n(rst_n),
          .valid_in(pe_valid_in),
          .a_in(a_tile[(row_g * ARRAY_K) + k_idx_ext]),
          .b_in(b_tile[(k_idx_ext * ARRAY_N) + col_g]),
          .acc_in(acc_q[PE_IDX]),
          .valid_out(pe_valid_out[PE_IDX]),
          .a_out(pe_a_out[PE_IDX]),
          .b_out(pe_b_out[PE_IDX]),
          .acc_out(pe_acc_out[PE_IDX])
        );
      end
    end
  endgenerate

  assign pe_valid_in = (state_q == ST_FEED);
  assign busy = (state_q == ST_FEED) || (state_q == ST_CAPTURE);
  assign done = (state_q == ST_DONE);
  assign error = (state_q == ST_ERROR);
  assign error_code = error ? vtpu_pkg::ERR_UNSUPPORTED : vtpu_pkg::ERR_NONE;

  always_comb begin
    for (comb_idx = 0; comb_idx < ARRAY_M*ARRAY_N; comb_idx++) begin
      c_out[comb_idx] = acc_q[comb_idx];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      k_idx_q <= 16'd0;
      for (reset_idx = 0; reset_idx < ARRAY_M*ARRAY_N; reset_idx++) begin
        acc_q[reset_idx] <= '0;
      end
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (start) begin
            if ((m == 16'd0) || (n == 16'd0) || (k == 16'd0) ||
                (m > ARRAY_M_U16) || (n > ARRAY_N_U16) || (k > ARRAY_K_U16)) begin
              state_q <= ST_ERROR;
            end else begin
              for (start_idx = 0; start_idx < ARRAY_M*ARRAY_N; start_idx++) begin
                acc_q[start_idx] <= accumulate ? c_in[start_idx] : 32'd0;  // 32'd0 == +0.0f
              end
              k_idx_q <= 16'd0;
              state_q <= ST_FEED;
            end
          end
        end
        ST_FEED: begin
          state_q <= ST_CAPTURE;
        end
        ST_CAPTURE: begin
          for (capture_idx = 0; capture_idx < ARRAY_M*ARRAY_N; capture_idx++) begin
            acc_q[capture_idx] <= pe_acc_out[capture_idx];
          end
          if (k_idx_q == (k - 16'd1)) begin
            state_q <= ST_DONE;
          end else begin
            k_idx_q <= k_idx_q + 16'd1;
            state_q <= ST_FEED;
          end
        end
        ST_DONE: begin
          state_q <= ST_IDLE;
        end
        ST_ERROR: begin
          state_q <= ST_ERROR;
        end
        default: begin
          state_q <= ST_ERROR;
        end
      endcase
    end
  end
endmodule
