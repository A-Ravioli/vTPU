// Module: vmem_bank
// Purpose: Single 32-bit VMEM bank with one request port.
// Public TPU inspiration: TPU-like local memories are banked to feed compute units.
// Educational simplification: One synchronous 32-bit port with byte write strobes.
// Inputs: vmem_req_t request.
// Outputs: vmem_resp_t response.
// State: Word memory array.
// Latency: One cycle.
// Backpressure: Always ready when reset is deasserted.
// Error behavior: Unaligned or out-of-range accesses set error.
// Tests: Covered through VMEM top lint and future cocotb memory tests.
module vmem_bank #(
  parameter int BANK_BYTES = 16384,
  parameter int DATA_W = 32
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::vmem_req_t req,
  output vtpu_pkg::vmem_resp_t resp
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = BANK_BYTES / WORD_BYTES;

  logic [DATA_W-1:0] mem [0:WORDS-1];
  vtpu_pkg::vmem_resp_t resp_q;
  int unsigned word_addr;

  assign resp = resp_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
    end else begin
      resp_q.ready <= 1'b1;
      resp_q.valid <= req.valid;
      resp_q.rdata <= '0;
      resp_q.error <= 1'b0;
      word_addr = req.addr / WORD_BYTES;
      if (req.valid) begin
        if (((req.addr % WORD_BYTES) != 0) || (word_addr >= WORDS)) begin
          resp_q.error <= 1'b1;
        end else if (req.write) begin
          if (req.wstrb[0]) mem[word_addr][7:0] <= req.wdata[7:0];
          if (req.wstrb[1]) mem[word_addr][15:8] <= req.wdata[15:8];
          if (req.wstrb[2]) mem[word_addr][23:16] <= req.wdata[23:16];
          if (req.wstrb[3]) mem[word_addr][31:24] <= req.wdata[31:24];
        end else begin
          resp_q.rdata <= mem[word_addr];
        end
      end
    end
  end
endmodule
