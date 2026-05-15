// Module: mxu_top
// Purpose: Command wrapper around the initial tiled systolic-array model.
// Public TPU inspiration: A TensorCore dispatches matrix commands to MXU units.
// Educational simplification: Tile data is exposed as flattened ports for early verification before VMEM streaming.
// Inputs: mxu_cmd_t command plus A/B/C tiles.
// Outputs: C tile and unit_status_t.
// State: Delegates state to systolic_array.
// Latency: Same as systolic_array for legal commands.
// Backpressure: cmd_ready is high only when the array is idle.
// Error behavior: Unsupported dimensions are reported by the array status.
// Tests: Python golden tests now; cocotb MXU tests should drive this wrapper later.
module mxu_top #(
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W = 8,
  parameter int ACC_W = 32
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mxu_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,

  input  logic signed [DATA_W-1:0] a_tile [0:ARRAY_M*ARRAY_K-1],
  input  logic signed [DATA_W-1:0] b_tile [0:ARRAY_K*ARRAY_N-1],
  input  logic signed [ACC_W-1:0]  c_in   [0:ARRAY_M*ARRAY_N-1],
  output logic signed [ACC_W-1:0]  c_out  [0:ARRAY_M*ARRAY_N-1],

  output vtpu_pkg::unit_status_t status
);
  logic start;
  logic array_busy;
  logic array_done;
  logic array_error;
  logic [7:0] array_error_code;

  assign cmd_ready = !array_busy;
  assign start = cmd_valid && cmd_ready;

  systolic_array #(
    .ARRAY_M(ARRAY_M),
    .ARRAY_N(ARRAY_N),
    .ARRAY_K(ARRAY_K),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
  ) u_array (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .accumulate(cmd.accumulate),
    .m(cmd.m),
    .n(cmd.n),
    .k(cmd.k),
    .a_tile(a_tile),
    .b_tile(b_tile),
    .c_in(c_in),
    .c_out(c_out),
    .busy(array_busy),
    .done(array_done),
    .error(array_error),
    .error_code(array_error_code)
  );

  assign status.busy = array_busy;
  assign status.done = array_done;
  assign status.error = array_error;
  assign status.error_code = array_error_code;
endmodule
