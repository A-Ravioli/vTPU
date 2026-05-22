// Module: perf_counters
// Purpose: Shared monotonically-incremented performance counter block.
// Inputs: per-counter increment values and a reset pulse.
// Outputs: indexed 64-bit counter read data.
// State: 64-bit counter array.
// Latency: Counter updates on the next clock; reads are combinational.
// Error behavior: None; out-of-range reads return zero.
module perf_counters #(
  parameter int NUM_COUNTERS = vtpu_pkg::VTPU_NUM_COUNTERS
)(
  input  logic clk,
  input  logic rst_n,
  input  logic clear,
  input  logic [63:0] inc [0:NUM_COUNTERS-1],
  input  logic [$clog2(NUM_COUNTERS)-1:0] read_index,
  output logic [63:0] read_value
);
  logic [63:0] counters_q [0:NUM_COUNTERS-1];
  integer idx;

  assign read_value = counters_q[read_index];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (idx = 0; idx < NUM_COUNTERS; idx++) begin
        counters_q[idx] <= 64'd0;
      end
    end else if (clear) begin
      for (idx = 0; idx < NUM_COUNTERS; idx++) begin
        counters_q[idx] <= 64'd0;
      end
    end else begin
      for (idx = 0; idx < NUM_COUNTERS; idx++) begin
        counters_q[idx] <= counters_q[idx] + inc[idx];
      end
    end
  end
endmodule
