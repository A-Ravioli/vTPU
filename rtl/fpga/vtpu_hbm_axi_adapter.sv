// Module: vtpu_hbm_axi_adapter
// Purpose: Translate vTPU's single-32-bit-word HBM request protocol to a
//          512-bit AXI4 memory port suitable for the AWS F2 HBM wrapper path.
// Scope: v1 smoke bring-up adapter; one outstanding read or write.
module vtpu_hbm_axi_adapter #(
  parameter int HBM_BYTES = 1048576
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mem_req_t  req,
  output vtpu_pkg::mem_resp_t resp,

  output logic [63:0]  m_axi_awaddr,
  output logic [7:0]   m_axi_awlen,
  output logic [2:0]   m_axi_awsize,
  output logic [1:0]   m_axi_awburst,
  output logic         m_axi_awvalid,
  input  logic         m_axi_awready,

  output logic [511:0] m_axi_wdata,
  output logic [63:0]  m_axi_wstrb,
  output logic         m_axi_wlast,
  output logic         m_axi_wvalid,
  input  logic         m_axi_wready,

  input  logic [1:0]   m_axi_bresp,
  input  logic         m_axi_bvalid,
  output logic         m_axi_bready,

  output logic [63:0]  m_axi_araddr,
  output logic [7:0]   m_axi_arlen,
  output logic [2:0]   m_axi_arsize,
  output logic [1:0]   m_axi_arburst,
  output logic         m_axi_arvalid,
  input  logic         m_axi_arready,

  input  logic [511:0] m_axi_rdata,
  input  logic [1:0]   m_axi_rresp,
  input  logic         m_axi_rvalid,
  input  logic         m_axi_rlast,
  output logic         m_axi_rready
);
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_READ_ADDR,
    ST_READ_DATA,
    ST_WRITE_ADDR,
    ST_WRITE_DATA,
    ST_WRITE_RESP,
    ST_ERROR_RESP
  } state_t;

  state_t state_q;
  vtpu_pkg::mem_req_t req_q;
  vtpu_pkg::mem_resp_t resp_q;
  logic [3:0] lane_q;

  assign resp = resp_q;

  function automatic logic request_bad(input vtpu_pkg::mem_req_t candidate);
    request_bad = (candidate.space != vtpu_pkg::MEM_HBM) ||
                  (candidate.addr[1:0] != 2'b00) ||
                  (candidate.addr >= HBM_BYTES);
  endfunction

  always_comb begin
    m_axi_awaddr = {32'd0, req_q.addr[31:6], 6'd0};
    m_axi_awlen = 8'd0;
    m_axi_awsize = 3'd6; // 64-byte beat
    m_axi_awburst = 2'b01;
    m_axi_awvalid = (state_q == ST_WRITE_ADDR);

    m_axi_wdata = 512'd0;
    m_axi_wstrb = 64'd0;
    m_axi_wlast = 1'b1;
    m_axi_wvalid = (state_q == ST_WRITE_DATA);
    m_axi_wdata[lane_q * 32 +: 32] = req_q.wdata;
    m_axi_wstrb[lane_q * 4 +: 4] = req_q.wstrb;

    m_axi_bready = (state_q == ST_WRITE_RESP);

    m_axi_araddr = {32'd0, req_q.addr[31:6], 6'd0};
    m_axi_arlen = 8'd0;
    m_axi_arsize = 3'd6; // 64-byte beat
    m_axi_arburst = 2'b01;
    m_axi_arvalid = (state_q == ST_READ_ADDR);

    m_axi_rready = (state_q == ST_READ_DATA);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      req_q <= '0;
      lane_q <= 4'd0;
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: 32'd0, error: 1'b0, error_code: vtpu_pkg::ERR_NONE};
    end else begin
      resp_q.valid <= 1'b0;
      resp_q.ready <= (state_q == ST_IDLE);

      unique case (state_q)
        ST_IDLE: begin
          resp_q.error <= 1'b0;
          resp_q.error_code <= vtpu_pkg::ERR_NONE;
          resp_q.rdata <= 32'd0;
          if (req.valid) begin
            req_q <= req;
            lane_q <= req.addr[5:2];
            resp_q.ready <= 1'b0;
            if (request_bad(req)) begin
              state_q <= ST_ERROR_RESP;
            end else if (req.write) begin
              state_q <= ST_WRITE_ADDR;
            end else begin
              state_q <= ST_READ_ADDR;
            end
          end
        end

        ST_READ_ADDR: begin
          resp_q.ready <= 1'b0;
          if (m_axi_arready) begin
            state_q <= ST_READ_DATA;
          end
        end

        ST_READ_DATA: begin
          resp_q.ready <= 1'b0;
          if (m_axi_rvalid) begin
            resp_q.valid <= 1'b1;
            resp_q.rdata <= m_axi_rdata[lane_q * 32 +: 32];
            resp_q.error <= (m_axi_rresp != 2'b00) || !m_axi_rlast;
            resp_q.error_code <= ((m_axi_rresp != 2'b00) || !m_axi_rlast) ? vtpu_pkg::ERR_BAD_ADDR : vtpu_pkg::ERR_NONE;
            state_q <= ST_IDLE;
          end
        end

        ST_WRITE_ADDR: begin
          resp_q.ready <= 1'b0;
          if (m_axi_awready) begin
            state_q <= ST_WRITE_DATA;
          end
        end

        ST_WRITE_DATA: begin
          resp_q.ready <= 1'b0;
          if (m_axi_wready) begin
            state_q <= ST_WRITE_RESP;
          end
        end

        ST_WRITE_RESP: begin
          resp_q.ready <= 1'b0;
          if (m_axi_bvalid) begin
            resp_q.valid <= 1'b1;
            resp_q.error <= (m_axi_bresp != 2'b00);
            resp_q.error_code <= (m_axi_bresp != 2'b00) ? vtpu_pkg::ERR_BAD_ADDR : vtpu_pkg::ERR_NONE;
            state_q <= ST_IDLE;
          end
        end

        ST_ERROR_RESP: begin
          resp_q.valid <= 1'b1;
          resp_q.error <= 1'b1;
          resp_q.error_code <= vtpu_pkg::ERR_BAD_ADDR;
          resp_q.ready <= 1'b0;
          state_q <= ST_IDLE;
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end
endmodule

