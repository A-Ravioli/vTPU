// Module: hbm_model
// Purpose: Simulated HBM memory for RTL tests.
// Public TPU inspiration: TPU v4-style chips use HBM as global tensor storage.
// Educational simplification: 32-bit word memory with fixed request latency and an MMIO debug port.
// Inputs: one DMA request port plus one host debug word port.
// Outputs: DMA response, host read data, and access/stall pulses.
// State: Word memory, busy counter, captured request.
// Latency: READ_LATENCY or WRITE_LATENCY cycles for DMA; host debug reads are combinational.
// Backpressure: One outstanding DMA request.
// Error behavior: Unaligned or out-of-range accesses set response error and do not modify memory.
module hbm_model #(
  parameter int HBM_BYTES = 1048576,
  parameter int DATA_W = 32,
  parameter int READ_LATENCY = vtpu_pkg::VTPU_HBM_READ_LATENCY,
  parameter int WRITE_LATENCY = vtpu_pkg::VTPU_HBM_WRITE_LATENCY
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mem_req_t req,
  output vtpu_pkg::mem_resp_t resp,

  input  logic host_we,
  input  logic [31:0] host_addr,
  input  logic [31:0] host_wdata,
  input  logic [3:0] host_wstrb,
  output logic [31:0] host_rdata,

  output logic access_pulse,
  output logic stall_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = HBM_BYTES / WORD_BYTES;

  logic [DATA_W-1:0] mem [0:WORDS-1];
  vtpu_pkg::mem_resp_t resp_q;
  vtpu_pkg::mem_req_t req_q;
  logic busy_q;
  int unsigned cycles_left_q;
  int unsigned word_addr;
  int unsigned host_word_addr_c;
  int unsigned host_word_addr_q;

  assign resp = resp_q;
  assign stall_pulse = req.valid && !resp_q.ready;

  always_comb begin
    host_word_addr_c = host_addr / WORD_BYTES;
    if ((host_addr[1:0] != 2'b00) || (host_word_addr_c >= WORDS)) begin
      host_rdata = '0;
    end else begin
      host_rdata = mem[host_word_addr_c];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0, error_code: 8'h00};
      req_q <= '0;
      busy_q <= 1'b0;
      cycles_left_q <= 0;
      access_pulse <= 1'b0;
    end else begin
      resp_q.valid <= 1'b0;
      resp_q.ready <= !busy_q;
      access_pulse <= 1'b0;

      if (host_we) begin
        host_word_addr_q = host_addr / WORD_BYTES;
        if ((host_addr[1:0] == 2'b00) && (host_word_addr_q < WORDS)) begin
          if (host_wstrb[0]) mem[host_word_addr_q][7:0] <= host_wdata[7:0];
          if (host_wstrb[1]) mem[host_word_addr_q][15:8] <= host_wdata[15:8];
          if (host_wstrb[2]) mem[host_word_addr_q][23:16] <= host_wdata[23:16];
          if (host_wstrb[3]) mem[host_word_addr_q][31:24] <= host_wdata[31:24];
        end
      end

      if (!busy_q && req.valid) begin
        req_q <= req;
        busy_q <= 1'b1;
        cycles_left_q <= req.write ? WRITE_LATENCY : READ_LATENCY;
        resp_q.ready <= 1'b0;
        access_pulse <= 1'b1;
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
