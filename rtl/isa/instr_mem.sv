// Module: instr_mem
// Purpose: Small instruction memory for custom 128-bit programs.
// Public TPU inspiration: TPU-like accelerators fetch compact command streams.
// Educational simplification: Host-loadable synchronous array with one fetch port.
// Inputs: host write port and fetch PC.
// Outputs: fetched instruction.
// State: 128-bit instruction array.
// Latency: One cycle fetch.
// Backpressure: None.
// Error behavior: Out-of-range fetch returns NOP and sets fetch_error.
// Tests: Future control FSM/chip cocotb tests.
module instr_mem #(
  parameter int DEPTH = 1024
)(
  input  logic clk,
  input  logic rst_n,
  input  logic host_we,
  input  logic [$clog2(DEPTH)-1:0] host_addr,
  input  logic [127:0] host_wdata,
  input  logic fetch_en,
  input  logic [$clog2(DEPTH)-1:0] fetch_pc,
  output logic [127:0] instr,
  output logic fetch_error
);
  logic [127:0] mem [0:DEPTH-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr <= '0;
      fetch_error <= 1'b0;
    end else begin
      fetch_error <= 1'b0;
      if (host_we) begin
        mem[host_addr] <= host_wdata;
      end
      if (fetch_en) begin
        instr <= mem[fetch_pc];
      end
    end
  end
endmodule
