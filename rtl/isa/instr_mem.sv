// Module: instr_mem
// Purpose: Host-loadable instruction memory for custom 128-bit programs.
// Public TPU inspiration: TPU-like accelerators fetch compact command streams.
// Educational simplification: One async fetch port plus one 32-bit MMIO lane port.
// Inputs: host 32-bit lane write/read address and fetch PC.
// Outputs: fetched instruction and selected host read lane.
// State: 128-bit instruction array.
// Latency: Host writes commit on the clock; fetch/read data is combinational.
// Backpressure: None.
// Error behavior: Address widths keep accesses in range.
// Tests: Chip-level cocotb loads programs through the same module the control path fetches.
module instr_mem #(
  parameter int DEPTH = 1024
)(
  input  logic clk,
  input  logic rst_n,

  input  logic host_we,
  input  logic [$clog2(DEPTH)-1:0] host_addr,
  input  logic [1:0] host_lane,
  input  logic [31:0] host_wdata,
  output logic [31:0] host_rdata,

  input  logic fetch_en,
  input  logic [$clog2(DEPTH)-1:0] fetch_pc,
  output logic [127:0] instr,
  output logic fetch_error
);
  logic [127:0] mem [0:DEPTH-1];

  assign instr = fetch_en ? mem[fetch_pc] : mem[fetch_pc];
  assign host_rdata = mem[host_addr][host_lane * 32 +: 32];
  assign fetch_error = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Instruction contents are intentionally not reset; host code owns program load.
    end else if (host_we) begin
      mem[host_addr][host_lane * 32 +: 32] <= host_wdata;
    end
  end
endmodule
