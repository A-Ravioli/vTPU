// Module: systolic_array_128
// Purpose: 128x128x128 PE-grid wrapper around the parameterized systolic_array.
// This gives 16384 PEs (vs 256 for the 16x16 default) — 64x more compute per cycle.
// Tile sizes: A = 128*128 int8 = 16 KB, B = 16 KB, C = 128*128*4 = 64 KB.
// All tiles fit in a 256 KB VMEM, with ~160 KB remaining for other buffers.
// Interface is identical to systolic_array; only ARRAY_M/N/K change.
module systolic_array_128 #(
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
)(
  input  logic clk,
  input  logic rst_n,

  input  logic        start,
  input  logic        accumulate,
  input  logic [15:0] m,
  input  logic [15:0] n,
  input  logic [15:0] k,

  input  logic signed [DATA_W-1:0] a_tile [0:128*128-1],
  input  logic signed [DATA_W-1:0] b_tile [0:128*128-1],
  input  logic signed [ACC_W-1:0]  c_in   [0:128*128-1],
  output logic signed [ACC_W-1:0]  c_out  [0:128*128-1],

  output logic busy,
  output logic done,
  output logic error,
  output logic [7:0] error_code
);
  systolic_array #(
    .ARRAY_M(128),
    .ARRAY_N(128),
    .ARRAY_K(128),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
  ) u_sa (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (start),
    .accumulate (accumulate),
    .m          (m),
    .n          (n),
    .k          (k),
    .a_tile     (a_tile),
    .b_tile     (b_tile),
    .c_in       (c_in),
    .c_out      (c_out),
    .busy       (busy),
    .done       (done),
    .error      (error),
    .error_code (error_code)
  );
endmodule
