// Module: cmem_top
// Purpose: Banked shared CMEM SRAM with arbitration and conflict accounting.
// Public TPU inspiration: Shared on-chip SRAM stages data between HBM and TensorCore VMEMs.
// Educational simplification: Three 32-bit request ports over a deterministic banked memory.
// Inputs: DMA and two TensorCore-side request ports.
// Outputs: per-port responses plus access/conflict increment pulses.
// State: Banked 32-bit word array.
// Latency: One cycle from accepted request to valid response.
// Backpressure: ready deasserts for lower-priority clients on same-bank conflicts.
// Error behavior: Unaligned or out-of-range accesses return error and do not modify memory.
module cmem_top #(
  parameter int CMEM_BYTES = 524288,
  parameter int DATA_W = 32,
  parameter int BANKS = vtpu_pkg::VTPU_VMEM_BANKS
)(
  input logic clk,
  input logic rst_n,

  input  vtpu_pkg::vmem_req_t req_dma,
  output vtpu_pkg::vmem_resp_t resp_dma,

  input  vtpu_pkg::vmem_req_t req_tc0,
  output vtpu_pkg::vmem_resp_t resp_tc0,

  input  vtpu_pkg::vmem_req_t req_tc1,
  output vtpu_pkg::vmem_resp_t resp_tc1,

  output logic [31:0] access_count_pulse,
  output logic [31:0] bank_conflict_count_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = CMEM_BYTES / WORD_BYTES;
  localparam int BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS);

  logic [DATA_W-1:0] mem [0:WORDS-1];

  vtpu_pkg::vmem_resp_t resp_dma_q;
  vtpu_pkg::vmem_resp_t resp_tc0_q;
  vtpu_pkg::vmem_resp_t resp_tc1_q;
  vtpu_pkg::vmem_resp_t resp_dma_s;
  vtpu_pkg::vmem_resp_t resp_tc0_s;
  vtpu_pkg::vmem_resp_t resp_tc1_s;

  logic ready_dma;
  logic ready_tc0;
  logic ready_tc1;
  logic valid_dma;
  logic valid_tc0;
  logic valid_tc1;
  logic [BANK_W-1:0] bank_dma;
  logic [BANK_W-1:0] bank_tc0;
  logic [BANK_W-1:0] bank_tc1;

  assign resp_dma = resp_dma_s;
  assign resp_tc0 = resp_tc0_s;
  assign resp_tc1 = resp_tc1_s;

  function automatic logic [BANK_W-1:0] bank_of(input logic [31:0] addr);
    logic [31:0] word_addr;
    begin
      word_addr = addr >> 2;
      bank_of = word_addr[BANK_W-1:0];
    end
  endfunction

  always_comb begin
    valid_dma = req_dma.valid;
    valid_tc0 = req_tc0.valid;
    valid_tc1 = req_tc1.valid;
    bank_dma = bank_of(req_dma.addr);
    bank_tc0 = bank_of(req_tc0.addr);
    bank_tc1 = bank_of(req_tc1.addr);

    // TensorCore-side reads win over background DMA on same-bank conflicts.
    ready_tc0 = valid_tc0;
    ready_tc1 = valid_tc1 && !(valid_tc0 && (bank_tc1 == bank_tc0));
    ready_dma = valid_dma &&
                !(valid_tc0 && (bank_dma == bank_tc0)) &&
                !(valid_tc1 && ready_tc1 && (bank_dma == bank_tc1));

    access_count_pulse = {31'd0, ready_tc0} +
                         {31'd0, ready_tc1} +
                         {31'd0, ready_dma};
    bank_conflict_count_pulse =
      {31'd0, (valid_tc1 && !ready_tc1)} +
      {31'd0, (valid_dma && !ready_dma)};

    resp_dma_s = resp_dma_q;
    resp_tc0_s = resp_tc0_q;
    resp_tc1_s = resp_tc1_q;
    resp_dma_s.ready = !valid_dma || ready_dma;
    resp_tc0_s.ready = !valid_tc0 || ready_tc0;
    resp_tc1_s.ready = !valid_tc1 || ready_tc1;
  end

  task automatic service_req(
    input vtpu_pkg::vmem_req_t port_req,
    output logic [DATA_W-1:0] rdata,
    output logic err
  );
    int unsigned word_addr;
    begin
      rdata = '0;
      err = 1'b0;
      word_addr = port_req.addr / WORD_BYTES;
      if ((port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS)) begin
        err = 1'b1;
      end else if (port_req.write) begin
        if (port_req.wstrb[0]) mem[word_addr][7:0] <= port_req.wdata[7:0];
        if (port_req.wstrb[1]) mem[word_addr][15:8] <= port_req.wdata[15:8];
        if (port_req.wstrb[2]) mem[word_addr][23:16] <= port_req.wdata[23:16];
        if (port_req.wstrb[3]) mem[word_addr][31:24] <= port_req.wdata[31:24];
      end else begin
        rdata = mem[word_addr];
      end
    end
  endtask

  task automatic drive_idle_resp(output vtpu_pkg::vmem_resp_t port_resp);
    begin
      port_resp.valid = 1'b0;
      port_resp.rdata = '0;
      port_resp.error = 1'b0;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc0_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc1_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
    end else begin
      drive_idle_resp(resp_dma_q);
      drive_idle_resp(resp_tc0_q);
      drive_idle_resp(resp_tc1_q);

      if (valid_tc0 && ready_tc0) begin
        resp_tc0_q.valid <= 1'b1;
        service_req(req_tc0, resp_tc0_q.rdata, resp_tc0_q.error);
      end
      if (valid_tc1 && ready_tc1) begin
        resp_tc1_q.valid <= 1'b1;
        service_req(req_tc1, resp_tc1_q.rdata, resp_tc1_q.error);
      end
      if (valid_dma && ready_dma) begin
        resp_dma_q.valid <= 1'b1;
        service_req(req_dma, resp_dma_q.rdata, resp_dma_q.error);
      end
    end
  end
endmodule
