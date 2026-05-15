// Module: hbm_model
// Purpose: Simulated HBM memory for RTL tests.
// Public TPU inspiration: TPU v4-style chips use HBM as global tensor storage.
// Educational simplification: Small 32-bit word memory with fixed response latency.
// Inputs: mem_req_t request.
// Outputs: mem_resp_t response.
// State: Word memory, busy counter, captured request.
// Latency: READ_LATENCY or WRITE_LATENCY cycles.
// Backpressure: One outstanding request.
// Error behavior: Unaligned or out-of-range accesses set response error.
// Tests: Future DMA/chip cocotb tests.
module hbm_model #(
  parameter int HBM_BYTES = 1048576,
  parameter int DATA_W = 32,
  parameter int READ_LATENCY = vtpu_pkg::VTPU_HBM_READ_LATENCY,
  parameter int WRITE_LATENCY = vtpu_pkg::VTPU_HBM_WRITE_LATENCY
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::mem_req_t req,
  output vtpu_pkg::mem_resp_t resp
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = HBM_BYTES / WORD_BYTES;

  logic [DATA_W-1:0] mem [0:WORDS-1];
  vtpu_pkg::mem_resp_t resp_q;
  vtpu_pkg::mem_req_t req_q;
  logic busy_q;
  int unsigned cycles_left_q;
  int unsigned word_addr;

  assign resp = resp_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0, error_code: 8'h00};
      req_q <= '0;
      busy_q <= 1'b0;
      cycles_left_q <= 0;
    end else begin
      resp_q.valid <= 1'b0;
      resp_q.ready <= !busy_q;
      if (!busy_q && req.valid) begin
        req_q <= req;
        busy_q <= 1'b1;
        cycles_left_q <= req.write ? WRITE_LATENCY : READ_LATENCY;
      end else if (busy_q) begin
        if (cycles_left_q == 0) begin
          busy_q <= 1'b0;
          resp_q.ready <= 1'b1;
          resp_q.valid <= 1'b1;
          resp_q.error <= 1'b0;
          resp_q.error_code <= vtpu_pkg::ERR_NONE;
          resp_q.rdata <= '0;
          word_addr = req_q.addr / WORD_BYTES;
          if (((req_q.addr % WORD_BYTES) != 0) || (word_addr >= WORDS)) begin
            resp_q.error <= 1'b1;
            resp_q.error_code <= vtpu_pkg::ERR_BAD_ADDR;
          end else if (req_q.write) begin
            if (req_q.wstrb[0]) mem[word_addr][7:0] <= req_q.wdata[7:0];
            if (req_q.wstrb[1]) mem[word_addr][15:8] <= req_q.wdata[15:8];
            if (req_q.wstrb[2]) mem[word_addr][23:16] <= req_q.wdata[23:16];
            if (req_q.wstrb[3]) mem[word_addr][31:24] <= req_q.wdata[31:24];
          end else begin
            resp_q.rdata <= mem[word_addr];
          end
        end else begin
          cycles_left_q <= cycles_left_q - 1;
        end
      end
    end
  end
endmodule
