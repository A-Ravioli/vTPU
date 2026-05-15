// Module: vmem_top
// Purpose: Small multi-port VMEM model for early TensorCore integration.
// Public TPU inspiration: TensorCore-local VMEM feeds matrix/vector units.
// Educational simplification: Three logical 32-bit ports share one simple word array; banking is deferred.
// Inputs: three vmem_req_t ports.
// Outputs: three vmem_resp_t ports.
// State: Word-addressed memory array.
// Latency: One cycle read response; writes complete in one cycle.
// Backpressure: ready is always high in this MVP model.
// Error behavior: Out-of-range addresses set the response error bit and do not modify memory.
// Tests: Python memory model tests now; RTL VMEM tests to be added with cocotb.
module vmem_top #(
  parameter int VMEM_BYTES = 262144,
  parameter int DATA_W = 32
)(
  input logic clk,
  input logic rst_n,

  input  vtpu_pkg::vmem_req_t req_a,
  output vtpu_pkg::vmem_resp_t resp_a,

  input  vtpu_pkg::vmem_req_t req_b,
  output vtpu_pkg::vmem_resp_t resp_b,

  input  vtpu_pkg::vmem_req_t req_dma,
  output vtpu_pkg::vmem_resp_t resp_dma
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = VMEM_BYTES / WORD_BYTES;

  logic [DATA_W-1:0] mem [0:WORDS-1];
  vtpu_pkg::vmem_resp_t resp_a_q;
  vtpu_pkg::vmem_resp_t resp_b_q;
  vtpu_pkg::vmem_resp_t resp_dma_q;

  assign resp_a = resp_a_q;
  assign resp_b = resp_b_q;
  assign resp_dma = resp_dma_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_a_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_b_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
    end else begin
      handle_port(req_a, resp_a_q);
      handle_port(req_b, resp_b_q);
      handle_port(req_dma, resp_dma_q);
    end
  end

  task automatic handle_port(
    input vtpu_pkg::vmem_req_t req,
    inout vtpu_pkg::vmem_resp_t resp
  );
    int unsigned word_addr;
    begin
      resp.ready = 1'b1;
      resp.valid = req.valid;
      resp.error = 1'b0;
      resp.rdata = '0;
      word_addr = req.addr / WORD_BYTES;
      if (req.valid) begin
        if ((req.addr % WORD_BYTES) != 0 || word_addr >= WORDS) begin
          resp.error = 1'b1;
        end else if (req.write) begin
          if (req.wstrb[0]) mem[word_addr][7:0] <= req.wdata[7:0];
          if (req.wstrb[1]) mem[word_addr][15:8] <= req.wdata[15:8];
          if (req.wstrb[2]) mem[word_addr][23:16] <= req.wdata[23:16];
          if (req.wstrb[3]) mem[word_addr][31:24] <= req.wdata[31:24];
        end else begin
          resp.rdata = mem[word_addr];
        end
      end
    end
  endtask
endmodule
