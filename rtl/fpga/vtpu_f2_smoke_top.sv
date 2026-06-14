// Module: vtpu_f2_smoke_top
// Purpose: Portable F2-facing vTPU wrapper with OCL AXI-Lite control and a
//          single 512-bit AXI4 HBM channel.
module vtpu_f2_smoke_top #(
  parameter int HBM_BYTES = 1048576,
  parameter int VMEM_BYTES = 4096,
  parameter int CMEM_BYTES = 4096,
  parameter int INSTR_DEPTH = 64
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [31:0] s_ocl_awaddr,
  input  logic        s_ocl_awvalid,
  output logic        s_ocl_awready,
  input  logic [31:0] s_ocl_wdata,
  input  logic [3:0]  s_ocl_wstrb,
  input  logic        s_ocl_wvalid,
  output logic        s_ocl_wready,
  output logic [1:0]  s_ocl_bresp,
  output logic        s_ocl_bvalid,
  input  logic        s_ocl_bready,

  input  logic [31:0] s_ocl_araddr,
  input  logic        s_ocl_arvalid,
  output logic        s_ocl_arready,
  output logic [31:0] s_ocl_rdata,
  output logic [1:0]  s_ocl_rresp,
  output logic        s_ocl_rvalid,
  input  logic        s_ocl_rready,

  output logic [63:0]  m_hbm_awaddr,
  output logic [7:0]   m_hbm_awlen,
  output logic [2:0]   m_hbm_awsize,
  output logic [1:0]   m_hbm_awburst,
  output logic         m_hbm_awvalid,
  input  logic         m_hbm_awready,
  output logic [511:0] m_hbm_wdata,
  output logic [63:0]  m_hbm_wstrb,
  output logic         m_hbm_wlast,
  output logic         m_hbm_wvalid,
  input  logic         m_hbm_wready,
  input  logic [1:0]   m_hbm_bresp,
  input  logic         m_hbm_bvalid,
  output logic         m_hbm_bready,
  output logic [63:0]  m_hbm_araddr,
  output logic [7:0]   m_hbm_arlen,
  output logic [2:0]   m_hbm_arsize,
  output logic [1:0]   m_hbm_arburst,
  output logic         m_hbm_arvalid,
  input  logic         m_hbm_arready,
  input  logic [511:0] m_hbm_rdata,
  input  logic [1:0]   m_hbm_rresp,
  input  logic         m_hbm_rvalid,
  input  logic         m_hbm_rlast,
  output logic         m_hbm_rready,

  output logic done,
  output logic busy,
  output logic error
);
  vtpu_pkg::host_req_t host_req;
  vtpu_pkg::host_resp_t host_resp;
  logic host_req_valid;
  logic host_req_ready;
  logic host_resp_valid;
  vtpu_pkg::mem_req_t core_hbm_req;
  vtpu_pkg::mem_resp_t core_hbm_resp;
  vtpu_pkg::mem_req_t debug_hbm_req;
  vtpu_pkg::mem_resp_t debug_hbm_resp;
  vtpu_pkg::mem_req_t adapter_req;
  vtpu_pkg::mem_resp_t adapter_resp;
  logic debug_active_q;
  logic select_debug;

  assign select_debug = debug_active_q || (debug_hbm_req.valid && !busy);
  assign adapter_req = select_debug ? debug_hbm_req : core_hbm_req;
  assign debug_hbm_resp = select_debug ? adapter_resp : '{ready: !busy, valid: 1'b0, rdata: 32'd0, error: 1'b0, error_code: vtpu_pkg::ERR_NONE};
  assign core_hbm_resp = select_debug ? '{ready: 1'b0, valid: 1'b0, rdata: 32'd0, error: 1'b0, error_code: vtpu_pkg::ERR_NONE} : adapter_resp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      debug_active_q <= 1'b0;
    end else begin
      if (!debug_active_q && debug_hbm_req.valid && !busy && adapter_resp.ready) begin
        debug_active_q <= 1'b1;
      end else if (debug_active_q && adapter_resp.valid) begin
        debug_active_q <= 1'b0;
      end
    end
  end

  vtpu_ocl_axil_bridge #(
    .HBM_BYTES(HBM_BYTES)
  ) u_ocl_bridge (
    .clk(clk),
    .rst_n(rst_n),
    .s_axil_awaddr(s_ocl_awaddr),
    .s_axil_awvalid(s_ocl_awvalid),
    .s_axil_awready(s_ocl_awready),
    .s_axil_wdata(s_ocl_wdata),
    .s_axil_wstrb(s_ocl_wstrb),
    .s_axil_wvalid(s_ocl_wvalid),
    .s_axil_wready(s_ocl_wready),
    .s_axil_bresp(s_ocl_bresp),
    .s_axil_bvalid(s_ocl_bvalid),
    .s_axil_bready(s_ocl_bready),
    .s_axil_araddr(s_ocl_araddr),
    .s_axil_arvalid(s_ocl_arvalid),
    .s_axil_arready(s_ocl_arready),
    .s_axil_rdata(s_ocl_rdata),
    .s_axil_rresp(s_ocl_rresp),
    .s_axil_rvalid(s_ocl_rvalid),
    .s_axil_rready(s_ocl_rready),
    .host_req(host_req),
    .host_req_valid(host_req_valid),
    .host_req_ready(host_req_ready),
    .host_resp(host_resp),
    .host_resp_valid(host_resp_valid),
    .hbm_req(debug_hbm_req),
    .hbm_resp(debug_hbm_resp),
    .core_busy(busy)
  );

  vtpu_hbm_axi_adapter #(
    .HBM_BYTES(HBM_BYTES)
  ) u_hbm_adapter (
    .clk(clk),
    .rst_n(rst_n),
    .req(adapter_req),
    .resp(adapter_resp),
    .m_axi_awaddr(m_hbm_awaddr),
    .m_axi_awlen(m_hbm_awlen),
    .m_axi_awsize(m_hbm_awsize),
    .m_axi_awburst(m_hbm_awburst),
    .m_axi_awvalid(m_hbm_awvalid),
    .m_axi_awready(m_hbm_awready),
    .m_axi_wdata(m_hbm_wdata),
    .m_axi_wstrb(m_hbm_wstrb),
    .m_axi_wlast(m_hbm_wlast),
    .m_axi_wvalid(m_hbm_wvalid),
    .m_axi_wready(m_hbm_wready),
    .m_axi_bresp(m_hbm_bresp),
    .m_axi_bvalid(m_hbm_bvalid),
    .m_axi_bready(m_hbm_bready),
    .m_axi_araddr(m_hbm_araddr),
    .m_axi_arlen(m_hbm_arlen),
    .m_axi_arsize(m_hbm_arsize),
    .m_axi_arburst(m_hbm_arburst),
    .m_axi_arvalid(m_hbm_arvalid),
    .m_axi_arready(m_hbm_arready),
    .m_axi_rdata(m_hbm_rdata),
    .m_axi_rresp(m_hbm_rresp),
    .m_axi_rvalid(m_hbm_rvalid),
    .m_axi_rlast(m_hbm_rlast),
    .m_axi_rready(m_hbm_rready)
  );

  virtual_tpu_v4_top #(
    .ARRAY_M(16),
    .ARRAY_N(16),
    .ARRAY_K(16),
    .VMEM_BYTES(VMEM_BYTES),
    .CMEM_BYTES(CMEM_BYTES),
    .HBM_BYTES(HBM_BYTES),
    .INSTR_DEPTH(INSTR_DEPTH),
    .EXTERNAL_HBM(1'b1),
    .FAST_BF16_MXU(1'b0)
  ) u_vtpu (
    .clk(clk),
    .rst_n(rst_n),
    .host_req(host_req),
    .host_req_valid(host_req_valid),
    .host_req_ready(host_req_ready),
    .host_resp(host_resp),
    .host_resp_valid(host_resp_valid),
    .ext_hbm_req(core_hbm_req),
    .ext_hbm_resp(core_hbm_resp),
    .done(done),
    .busy(busy),
    .error(error)
  );
endmodule

