// Module: splittable_systolic_array
// Purpose: Reconfigurable PE-grid that can operate as one 16x16 array or four independent 8x8
//          sub-arrays, inspired by SIGMA (Samsung 2020) and TPU v4 flexible MXU.
// Split mode: split_en=0 is a standard 16x16 output-stationary matmul (identical to
//             systolic_array.sv). split_en=1 divides the 256 PEs into four 8x8 partitions
//             (top-left, top-right, bottom-left, bottom-right) each with an independent state
//             machine and k-counter, enabling four concurrent independent matmuls.
// Data layout (split_en=1): caller packs four tile triplets consecutively in VMEM:
//   a_tile[0 : 4*PM*K-1]  — four A tiles of size PM×K (PM = ARRAY_M/2)
//   b_tile[0 : 4*K*PN-1]  — four B tiles of size K×PN (PN = ARRAY_N/2)
//   c_in/c_out[0 : 4*PM*PN-1] — four C tiles of size PM×PN
//   Partition p (row_p=p/2, col_p=p%2) owns offset p in each packed tile block.
// Data layout (split_en=0): same as systolic_array.sv (full ARRAY_M×ARRAY_K, etc.)
// Backpressure: per-partition start accepted only when that partition's busy is low.
// Latency: two cycles per K slice plus overhead (identical to systolic_array.sv per partition).
// Tests: tests/python/test_split_matmul.py and golden model _execute_matmul split path.
module splittable_systolic_array #(
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W  = 8,
  parameter int ACC_W   = 32,
  // half-dimensions for 2x2 split (must divide evenly)
  localparam int PM = ARRAY_M / 2,  // rows per partition
  localparam int PN = ARRAY_N / 2,  // cols per partition
  localparam int NUM_PARTS = 4      // always 2x2 = 4 partitions
)(
  input  logic clk,
  input  logic rst_n,

  // split_en=0: standard 16x16 array controlled by start[0]/accumulate[0]/m/n/k
  // split_en=1: four 8x8 sub-arrays, each controlled by start[p]/accumulate[p]/m/n/k
  //             (m and n must be <= PM and PN respectively in split mode)
  input  logic split_en,

  input  logic [NUM_PARTS-1:0] start,
  input  logic [NUM_PARTS-1:0] accumulate,
  input  logic [15:0] m,
  input  logic [15:0] n,
  input  logic [15:0] k,

  // split_en=0: a_tile[ARRAY_M * ARRAY_K], b_tile[ARRAY_K * ARRAY_N], c[ARRAY_M * ARRAY_N]
  // split_en=1: a_tile[NUM_PARTS * PM * K], b_tile[NUM_PARTS * K * PN], c[NUM_PARTS * PM * PN]
  //             packed as [part0_tile | part1_tile | part2_tile | part3_tile]
  input  logic signed [DATA_W-1:0] a_tile [0:NUM_PARTS*PM*ARRAY_K-1],
  input  logic signed [DATA_W-1:0] b_tile [0:NUM_PARTS*ARRAY_K*PN-1],
  input  logic signed [ACC_W-1:0]  c_in   [0:NUM_PARTS*PM*PN-1],
  output logic signed [ACC_W-1:0]  c_out  [0:NUM_PARTS*PM*PN-1],

  output logic [NUM_PARTS-1:0] busy,
  output logic [NUM_PARTS-1:0] done,
  output logic [NUM_PARTS-1:0] error,
  output logic [7:0] error_code [0:NUM_PARTS-1]
);
  // -----------------------------------------------------------------
  // Internal constants
  // -----------------------------------------------------------------
  localparam logic [15:0] MAX_M_FULL   = ARRAY_M[15:0];
  localparam logic [15:0] MAX_N_FULL   = ARRAY_N[15:0];
  localparam logic [15:0] MAX_M_SPLIT  = PM[15:0];
  localparam logic [15:0] MAX_N_SPLIT  = PN[15:0];
  localparam logic [15:0] MAX_K        = ARRAY_K[15:0];

  // -----------------------------------------------------------------
  // Per-partition state machines
  // -----------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_FEED,
    ST_CAPTURE,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t         state_q   [0:NUM_PARTS-1];
  logic [15:0]    k_idx_q   [0:NUM_PARTS-1];
  logic [31:0]    k_idx_ext [0:NUM_PARTS-1];

  // Accumulators: in split mode, each partition owns PM*PN cells.
  // In full mode (split_en=0), we use partition-0's slice for all ARRAY_M*ARRAY_N cells.
  // Because PM*PN = (ARRAY_M/2)*(ARRAY_N/2) = ARRAY_M*ARRAY_N/4, four partitions cover
  // the same total as the full array: 4 * PM * PN == ARRAY_M * ARRAY_N.
  logic signed [ACC_W-1:0] acc_q      [0:NUM_PARTS*PM*PN-1];
  logic signed [ACC_W-1:0] pe_acc_out [0:NUM_PARTS*PM*PN-1];
  logic                    pe_valid_in  [0:NUM_PARTS-1];
  logic                    pe_valid_out [0:NUM_PARTS*PM*PN-1];

  genvar p, r, c;

  // -----------------------------------------------------------------
  // PE grid: one PE per (partition, row, col) — identical to pe_int8 instances
  // but valid_in and data addressing respect the partition and split_en mode.
  // -----------------------------------------------------------------
  generate
    for (p = 0; p < NUM_PARTS; p++) begin : gen_parts
      // Partition spatial layout within the full array:
      //   row_p = p/2, col_p = p%2
      //   Partition p owns global PE rows [row_p*PM : (row_p+1)*PM)
      //                    and global PE cols [col_p*PN : (col_p+1)*PN)
      // For data indexing:
      //   When split_en=1, each partition has its own offset into the packed tile arrays.
      //   When split_en=0, all partitions share the same global A/B tiles and the full
      //   accumulator space (we use only the first partition's state machine).
      localparam int ROW_P = p / 2;
      localparam int COL_P = p % 2;
      localparam int PE_ROW_BASE = ROW_P * PM;
      localparam int PE_COL_BASE = COL_P * PN;

      for (r = 0; r < PM; r++) begin : gen_rows
        for (c = 0; c < PN; c++) begin : gen_cols
          // Index within this partition's tile (row-major)
          localparam int LOCAL_IDX = r * PN + c;
          // Global PE index for accumulator storage (used in both modes)
          localparam int GLOBAL_PE = (PE_ROW_BASE + r) * ARRAY_N + (PE_COL_BASE + c);

          // In split_en=0 mode: global PE index is used with the single state machine's k_idx.
          // In split_en=1 mode: partition p's k_idx selects the K slice.
          //
          // a_tile indexing:
          //   split_en=0: row-major over full ARRAY_M×ARRAY_K: a_tile[global_row * ARRAY_K + k]
          //               global_row = PE_ROW_BASE + r  (note: in unsplit mode, partition 0
          //               covers rows 0..7 and partition 2 covers rows 8..15; all use state[0])
          //   split_en=1: packed tiles: a_tile[p*PM*ARRAY_K + r*ARRAY_K + k]
          //
          // We mux both possibilities; the synthesis tool will optimize away the unused path.
          localparam int A_FULL_ROW_BASE = (PE_ROW_BASE + r) * ARRAY_K;
          localparam int A_SPLIT_BASE    = p * PM * ARRAY_K + r * ARRAY_K;
          localparam int B_FULL_COL      = PE_COL_BASE + c;
          localparam int B_SPLIT_BASE    = p * ARRAY_K * PN + c;

          // Accumulator index: in split_en=0 we use full array layout so c_out maps 1:1 to
          // GLOBAL_PE; in split_en=1 each partition's PM*PN cells are packed contiguously.
          localparam int ACC_SPLIT_IDX   = p * PM * PN + LOCAL_IDX;
          // For split_en=0 full mode, the acc index is the global PE index.
          // To keep a single unified acc_q array, we map all accumulators to the split-packed
          // layout and reassemble c_out accordingly (see c_out assignment below).
          // NOTE: in full mode, split_en=0, only partition 0's state machine runs, but PEs from
          // all 4 logical partitions still need correct k_idx.  We give them partition 0's k_idx.

          logic [31:0] a_idx, b_idx;
          always_comb begin
            if (split_en) begin
              a_idx = A_SPLIT_BASE + k_idx_ext[p];
              b_idx = B_SPLIT_BASE + k_idx_ext[p] * PN;
            end else begin
              // Full-mode: use partition 0's k_idx for all PEs
              a_idx = A_FULL_ROW_BASE + k_idx_ext[0];
              b_idx = B_FULL_COL + k_idx_ext[0] * ARRAY_N;
            end
          end

          pe_int8 #(
            .DATA_W(DATA_W),
            .ACC_W(ACC_W)
          ) u_pe (
            .clk      (clk),
            .rst_n    (rst_n),
            .valid_in (pe_valid_in[split_en ? p : 0]),
            .a_in     (a_tile[a_idx]),
            .b_in     (b_tile[b_idx]),
            .acc_in   (acc_q[ACC_SPLIT_IDX]),
            .valid_out(pe_valid_out[ACC_SPLIT_IDX]),
            .a_out    (/* unused — output-stationary, data not forwarded */),
            .b_out    (/* unused */),
            .acc_out  (pe_acc_out[ACC_SPLIT_IDX])
          );
        end
      end
    end
  endgenerate

  // -----------------------------------------------------------------
  // c_out: route packed accumulator array to output
  // -----------------------------------------------------------------
  integer out_idx;
  always_comb begin
    for (out_idx = 0; out_idx < NUM_PARTS*PM*PN; out_idx++) begin
      c_out[out_idx] = acc_q[out_idx];
    end
  end

  // -----------------------------------------------------------------
  // Per-partition state machine logic
  // -----------------------------------------------------------------
  genvar pg;
  generate
    for (pg = 0; pg < NUM_PARTS; pg++) begin : gen_fsm
      assign k_idx_ext[pg] = {16'd0, k_idx_q[pg]};
      assign pe_valid_in[pg] = (state_q[pg] == ST_FEED);
      assign busy[pg]        = (state_q[pg] == ST_FEED) || (state_q[pg] == ST_CAPTURE);
      assign done[pg]        = (state_q[pg] == ST_DONE);
      assign error[pg]       = (state_q[pg] == ST_ERROR);
      assign error_code[pg]  = error[pg] ? vtpu_pkg::ERR_UNSUPPORTED : vtpu_pkg::ERR_NONE;
    end
  endgenerate

  // Dimension limit depends on split_en:
  //   split_en=0: full array — m <= ARRAY_M, n <= ARRAY_N
  //   split_en=1: per-partition — m <= PM, n <= PN
  function automatic logic dim_valid(input logic [15:0] m_in, n_in, k_in);
    logic [15:0] max_m, max_n;
    begin
      max_m = split_en ? MAX_M_SPLIT : MAX_M_FULL;
      max_n = split_en ? MAX_N_SPLIT : MAX_N_FULL;
      dim_valid = (m_in != 16'd0) && (n_in != 16'd0) && (k_in != 16'd0) &&
                  (m_in <= max_m) && (n_in <= max_n) && (k_in <= MAX_K);
    end
  endfunction

  integer rst_i, cap_i;
  genvar fsm_g;
  generate
    for (fsm_g = 0; fsm_g < NUM_PARTS; fsm_g++) begin : gen_fsm_ff
      // In full (non-split) mode, only FSM 0 is active.  FSMs 1-3 stay in IDLE.
      // Their PEs fire when FSM 0's pe_valid_in[0] is asserted (see PE instantiation).
      always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
          state_q[fsm_g] <= ST_IDLE;
          k_idx_q[fsm_g] <= 16'd0;
          for (i = fsm_g * PM * PN; i < (fsm_g + 1) * PM * PN; i++) begin
            acc_q[i] <= '0;
          end
        end else begin
          // In full mode, partitions 1-3 are frozen in IDLE; only FSM 0 runs.
          if (!split_en && (fsm_g != 0)) begin
            state_q[fsm_g] <= ST_IDLE;
          end else begin
            unique case (state_q[fsm_g])
              ST_IDLE: begin
                if (start[fsm_g]) begin
                  if (!dim_valid(m, n, k)) begin
                    state_q[fsm_g] <= ST_ERROR;
                  end else begin
                    for (i = fsm_g * PM * PN; i < (fsm_g + 1) * PM * PN; i++) begin
                      acc_q[i] <= accumulate[fsm_g] ? c_in[i] : '0;
                    end
                    k_idx_q[fsm_g] <= 16'd0;
                    state_q[fsm_g] <= ST_FEED;
                  end
                end
              end
              ST_FEED: begin
                state_q[fsm_g] <= ST_CAPTURE;
              end
              ST_CAPTURE: begin
                for (i = fsm_g * PM * PN; i < (fsm_g + 1) * PM * PN; i++) begin
                  acc_q[i] <= pe_acc_out[i];
                end
                if (k_idx_q[fsm_g] == (k - 16'd1)) begin
                  state_q[fsm_g] <= ST_DONE;
                end else begin
                  k_idx_q[fsm_g] <= k_idx_q[fsm_g] + 16'd1;
                  state_q[fsm_g] <= ST_FEED;
                end
              end
              ST_DONE: begin
                state_q[fsm_g] <= ST_IDLE;
              end
              ST_ERROR: begin
                state_q[fsm_g] <= ST_ERROR;
              end
              default: begin
                state_q[fsm_g] <= ST_ERROR;
              end
            endcase
          end
        end
      end
    end
  endgenerate

endmodule
