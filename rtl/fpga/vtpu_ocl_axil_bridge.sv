// Module: vtpu_ocl_axil_bridge
// Purpose: Convert AWS OCL AXI-Lite traffic into vTPU host requests and
//          idle-time HBM debug-window requests.
// Scope: one AXI-Lite transaction at a time, 32-bit accesses only.
module vtpu_ocl_axil_bridge #(
  parameter int HBM_BYTES = 1048576
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [31:0] s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,

  input  logic [31:0] s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,

  output vtpu_pkg::host_req_t  host_req,
  output logic                 host_req_valid,
  input  logic                 host_req_ready,
  input  vtpu_pkg::host_resp_t host_resp,
  input  logic                 host_resp_valid,

  output vtpu_pkg::mem_req_t   hbm_req,
  input  vtpu_pkg::mem_resp_t  hbm_resp,

  input  logic                 core_busy
);
  localparam logic [31:0] HBM_BASE = vtpu_pkg::VTPU_HBM_BASE;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WRITE_WAIT,
    ST_CORE_REQ,
    ST_CORE_RESP,
    ST_HBM_REQ,
    ST_HBM_RESP,
    ST_WRITE_RESP,
    ST_READ_RESP
  } state_t;

  state_t state_q;
  logic aw_seen_q;
  logic w_seen_q;
  logic op_write_q;
  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic [31:0] rdata_q;
  logic error_q;
  vtpu_pkg::host_req_t host_req_q;
  vtpu_pkg::mem_req_t hbm_req_q;

  assign host_req = host_req_q;
  assign hbm_req = hbm_req_q;
  assign host_req_valid = (state_q == ST_CORE_REQ);

  assign s_axil_awready = (state_q == ST_IDLE || state_q == ST_WRITE_WAIT) && !aw_seen_q;
  assign s_axil_wready = (state_q == ST_IDLE || state_q == ST_WRITE_WAIT) && !w_seen_q;
  assign s_axil_arready = (state_q == ST_IDLE) && !aw_seen_q && !w_seen_q;
  assign s_axil_bvalid = (state_q == ST_WRITE_RESP);
  assign s_axil_bresp = error_q ? 2'b10 : 2'b00;
  assign s_axil_rvalid = (state_q == ST_READ_RESP);
  assign s_axil_rdata = rdata_q;
  assign s_axil_rresp = error_q ? 2'b10 : 2'b00;

  function automatic logic hbm_hit(input logic [31:0] addr);
    hbm_hit = (addr >= HBM_BASE) && (addr < (HBM_BASE + HBM_BYTES));
  endfunction

  function automatic logic aligned(input logic [31:0] addr);
    aligned = (addr[1:0] == 2'b00);
  endfunction

  task automatic issue_core_req;
    begin
      host_req_q.valid <= 1'b1;
      host_req_q.write <= op_write_q;
      host_req_q.addr <= addr_q;
      host_req_q.wdata <= wdata_q;
    end
  endtask

  task automatic issue_hbm_req;
    begin
      hbm_req_q.valid <= 1'b1;
      hbm_req_q.write <= op_write_q;
      hbm_req_q.space <= vtpu_pkg::MEM_HBM;
      hbm_req_q.addr <= addr_q - HBM_BASE;
      hbm_req_q.wdata <= wdata_q;
      hbm_req_q.wstrb <= op_write_q ? wstrb_q : 4'h0;
    end
  endtask

  task automatic clear_reqs;
    begin
      host_req_q <= '0;
      hbm_req_q <= '0;
    end
  endtask

  task automatic dispatch_transaction;
    begin
      error_q <= 1'b0;
      rdata_q <= 32'd0;
      if (!aligned(addr_q) || (op_write_q && (wstrb_q == 4'h0))) begin
        error_q <= 1'b1;
        state_q <= op_write_q ? ST_WRITE_RESP : ST_READ_RESP;
      end else if (hbm_hit(addr_q)) begin
        if (core_busy) begin
          error_q <= 1'b1;
          state_q <= op_write_q ? ST_WRITE_RESP : ST_READ_RESP;
        end else begin
          issue_hbm_req();
          state_q <= ST_HBM_REQ;
        end
      end else begin
        issue_core_req();
        state_q <= ST_CORE_REQ;
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      aw_seen_q <= 1'b0;
      w_seen_q <= 1'b0;
      op_write_q <= 1'b0;
      addr_q <= 32'd0;
      wdata_q <= 32'd0;
      wstrb_q <= 4'h0;
      rdata_q <= 32'd0;
      error_q <= 1'b0;
      clear_reqs();
    end else begin
      clear_reqs();

      unique case (state_q)
        ST_IDLE: begin
          aw_seen_q <= 1'b0;
          w_seen_q <= 1'b0;
          if (s_axil_arvalid) begin
            op_write_q <= 1'b0;
            addr_q <= s_axil_araddr;
            state_q <= ST_CORE_REQ;
            error_q <= 1'b0;
            rdata_q <= 32'd0;
            if (!aligned(s_axil_araddr)) begin
              error_q <= 1'b1;
              state_q <= ST_READ_RESP;
            end else if (hbm_hit(s_axil_araddr)) begin
              if (core_busy) begin
                error_q <= 1'b1;
                state_q <= ST_READ_RESP;
              end else begin
                hbm_req_q <= '{valid: 1'b1, write: 1'b0, space: vtpu_pkg::MEM_HBM, addr: s_axil_araddr - HBM_BASE, wdata: 32'd0, wstrb: 4'h0};
                state_q <= ST_HBM_REQ;
              end
            end else begin
              host_req_q <= '{valid: 1'b1, write: 1'b0, addr: s_axil_araddr, wdata: 32'd0};
              state_q <= ST_CORE_REQ;
            end
          end else if (s_axil_awvalid || s_axil_wvalid) begin
            if (s_axil_awvalid) begin
              aw_seen_q <= 1'b1;
              addr_q <= s_axil_awaddr;
            end
            if (s_axil_wvalid) begin
              w_seen_q <= 1'b1;
              wdata_q <= s_axil_wdata;
              wstrb_q <= s_axil_wstrb;
            end
            op_write_q <= 1'b1;
            state_q <= ST_WRITE_WAIT;
          end
        end

        ST_WRITE_WAIT: begin
          if (s_axil_awvalid && !aw_seen_q) begin
            aw_seen_q <= 1'b1;
            addr_q <= s_axil_awaddr;
          end
          if (s_axil_wvalid && !w_seen_q) begin
            w_seen_q <= 1'b1;
            wdata_q <= s_axil_wdata;
            wstrb_q <= s_axil_wstrb;
          end
          if ((aw_seen_q || s_axil_awvalid) && (w_seen_q || s_axil_wvalid)) begin
            op_write_q <= 1'b1;
            dispatch_transaction();
          end
        end

        ST_CORE_REQ: begin
          if (host_req_ready) begin
            state_q <= ST_CORE_RESP;
          end else begin
            issue_core_req();
          end
        end

        ST_CORE_RESP: begin
          if (host_resp_valid) begin
            rdata_q <= host_resp.rdata;
            error_q <= host_resp.error;
            state_q <= op_write_q ? ST_WRITE_RESP : ST_READ_RESP;
          end
        end

        ST_HBM_REQ: begin
          if (hbm_resp.ready) begin
            state_q <= ST_HBM_RESP;
          end else begin
            issue_hbm_req();
          end
        end

        ST_HBM_RESP: begin
          if (hbm_resp.valid) begin
            rdata_q <= hbm_resp.rdata;
            error_q <= hbm_resp.error;
            state_q <= op_write_q ? ST_WRITE_RESP : ST_READ_RESP;
          end
        end

        ST_WRITE_RESP: begin
          if (s_axil_bready) begin
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            state_q <= ST_IDLE;
          end
        end

        ST_READ_RESP: begin
          if (s_axil_rready) begin
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
