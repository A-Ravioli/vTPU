// Module: vtpu_f2_smoke_sim_top
// Purpose: Local simulation wrapper for the F2-facing smoke top.
module vtpu_f2_smoke_sim_top #(
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

  output logic done,
  output logic busy,
  output logic error
);
  logic [63:0]  hbm_awaddr;
  logic [7:0]   hbm_awlen;
  logic [2:0]   hbm_awsize;
  logic [1:0]   hbm_awburst;
  logic         hbm_awvalid;
  logic         hbm_awready;
  logic [511:0] hbm_wdata;
  logic [63:0]  hbm_wstrb;
  logic         hbm_wlast;
  logic         hbm_wvalid;
  logic         hbm_wready;
  logic [1:0]   hbm_bresp;
  logic         hbm_bvalid;
  logic         hbm_bready;
  logic [63:0]  hbm_araddr;
  logic [7:0]   hbm_arlen;
  logic [2:0]   hbm_arsize;
  logic [1:0]   hbm_arburst;
  logic         hbm_arvalid;
  logic         hbm_arready;
  logic [511:0] hbm_rdata;
  logic [1:0]   hbm_rresp;
  logic         hbm_rvalid;
  logic         hbm_rlast;
  logic         hbm_rready;

  vtpu_f2_smoke_top #(
    .HBM_BYTES(HBM_BYTES),
    .VMEM_BYTES(VMEM_BYTES),
    .CMEM_BYTES(CMEM_BYTES),
    .INSTR_DEPTH(INSTR_DEPTH)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .s_ocl_awaddr(s_ocl_awaddr),
    .s_ocl_awvalid(s_ocl_awvalid),
    .s_ocl_awready(s_ocl_awready),
    .s_ocl_wdata(s_ocl_wdata),
    .s_ocl_wstrb(s_ocl_wstrb),
    .s_ocl_wvalid(s_ocl_wvalid),
    .s_ocl_wready(s_ocl_wready),
    .s_ocl_bresp(s_ocl_bresp),
    .s_ocl_bvalid(s_ocl_bvalid),
    .s_ocl_bready(s_ocl_bready),
    .s_ocl_araddr(s_ocl_araddr),
    .s_ocl_arvalid(s_ocl_arvalid),
    .s_ocl_arready(s_ocl_arready),
    .s_ocl_rdata(s_ocl_rdata),
    .s_ocl_rresp(s_ocl_rresp),
    .s_ocl_rvalid(s_ocl_rvalid),
    .s_ocl_rready(s_ocl_rready),
    .m_hbm_awaddr(hbm_awaddr),
    .m_hbm_awlen(hbm_awlen),
    .m_hbm_awsize(hbm_awsize),
    .m_hbm_awburst(hbm_awburst),
    .m_hbm_awvalid(hbm_awvalid),
    .m_hbm_awready(hbm_awready),
    .m_hbm_wdata(hbm_wdata),
    .m_hbm_wstrb(hbm_wstrb),
    .m_hbm_wlast(hbm_wlast),
    .m_hbm_wvalid(hbm_wvalid),
    .m_hbm_wready(hbm_wready),
    .m_hbm_bresp(hbm_bresp),
    .m_hbm_bvalid(hbm_bvalid),
    .m_hbm_bready(hbm_bready),
    .m_hbm_araddr(hbm_araddr),
    .m_hbm_arlen(hbm_arlen),
    .m_hbm_arsize(hbm_arsize),
    .m_hbm_arburst(hbm_arburst),
    .m_hbm_arvalid(hbm_arvalid),
    .m_hbm_arready(hbm_arready),
    .m_hbm_rdata(hbm_rdata),
    .m_hbm_rresp(hbm_rresp),
    .m_hbm_rvalid(hbm_rvalid),
    .m_hbm_rlast(hbm_rlast),
    .m_hbm_rready(hbm_rready),
    .done(done),
    .busy(busy),
    .error(error)
  );

  axi512_memory_model #(
    .MEM_BYTES(HBM_BYTES)
  ) u_hbm_model (
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(hbm_awaddr),
    .s_axi_awlen(hbm_awlen),
    .s_axi_awsize(hbm_awsize),
    .s_axi_awburst(hbm_awburst),
    .s_axi_awvalid(hbm_awvalid),
    .s_axi_awready(hbm_awready),
    .s_axi_wdata(hbm_wdata),
    .s_axi_wstrb(hbm_wstrb),
    .s_axi_wlast(hbm_wlast),
    .s_axi_wvalid(hbm_wvalid),
    .s_axi_wready(hbm_wready),
    .s_axi_bresp(hbm_bresp),
    .s_axi_bvalid(hbm_bvalid),
    .s_axi_bready(hbm_bready),
    .s_axi_araddr(hbm_araddr),
    .s_axi_arlen(hbm_arlen),
    .s_axi_arsize(hbm_arsize),
    .s_axi_arburst(hbm_arburst),
    .s_axi_arvalid(hbm_arvalid),
    .s_axi_arready(hbm_arready),
    .s_axi_rdata(hbm_rdata),
    .s_axi_rresp(hbm_rresp),
    .s_axi_rvalid(hbm_rvalid),
    .s_axi_rlast(hbm_rlast),
    .s_axi_rready(hbm_rready)
  );
endmodule

