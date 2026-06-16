// AWS F2 customer-logic top for the vTPU smoke workload.
module cl_vtpu #(
  parameter EN_DDR = 0,
  parameter EN_HBM = 1
)(
  `include "cl_ports.vh"
);

`include "cl_id_defines.vh"
`include "cl_vtpu_defines.vh"

  logic vtpu_done;
  logic vtpu_busy;
  logic vtpu_error;
  logic hbm_ready;
  logic vtpu_rst_n;

  axi_bus_t hbm_axi4_bus();
  cfg_bus_t hbm_stat_bus();

  assign vtpu_rst_n = rst_main_n && !sh_cl_flr_assert && hbm_ready;

  always_comb begin
    cl_sh_flr_done    = 1'b1;
    cl_sh_status0     = {29'b0, vtpu_error, vtpu_busy, vtpu_done};
    cl_sh_status1     = {31'b0, hbm_ready};
    cl_sh_status2     = 32'b0;
    cl_sh_id0         = `CL_SH_ID0;
    cl_sh_id1         = `CL_SH_ID1;
    cl_sh_status_vled = {12'b0, hbm_ready, vtpu_error, vtpu_busy, vtpu_done};
    cl_sh_dma_wr_full = 1'b0;
    cl_sh_dma_rd_full = 1'b0;
  end

  always_comb begin
    cl_sh_pcim_awid    = '0;
    cl_sh_pcim_awaddr  = '0;
    cl_sh_pcim_awlen   = '0;
    cl_sh_pcim_awsize  = '0;
    cl_sh_pcim_awburst = '0;
    cl_sh_pcim_awcache = '0;
    cl_sh_pcim_awlock  = '0;
    cl_sh_pcim_awprot  = '0;
    cl_sh_pcim_awqos   = '0;
    cl_sh_pcim_awuser  = '0;
    cl_sh_pcim_awvalid = 1'b0;
    cl_sh_pcim_wid     = '0;
    cl_sh_pcim_wdata   = '0;
    cl_sh_pcim_wstrb   = '0;
    cl_sh_pcim_wlast   = 1'b0;
    cl_sh_pcim_wuser   = '0;
    cl_sh_pcim_wvalid  = 1'b0;
    cl_sh_pcim_bready  = 1'b0;
    cl_sh_pcim_arid    = '0;
    cl_sh_pcim_araddr  = '0;
    cl_sh_pcim_arlen   = '0;
    cl_sh_pcim_arsize  = '0;
    cl_sh_pcim_arburst = '0;
    cl_sh_pcim_arcache = '0;
    cl_sh_pcim_arlock  = '0;
    cl_sh_pcim_arprot  = '0;
    cl_sh_pcim_arqos   = '0;
    cl_sh_pcim_aruser  = '0;
    cl_sh_pcim_arvalid = 1'b0;
    cl_sh_pcim_rready  = 1'b0;
  end

  always_comb begin
    cl_sh_dma_pcis_awready = 1'b0;
    cl_sh_dma_pcis_wready  = 1'b0;
    cl_sh_dma_pcis_bid     = '0;
    cl_sh_dma_pcis_bresp   = '0;
    cl_sh_dma_pcis_bvalid  = 1'b0;
    cl_sh_dma_pcis_arready = 1'b0;
    cl_sh_dma_pcis_rid     = '0;
    cl_sh_dma_pcis_rdata   = '0;
    cl_sh_dma_pcis_rresp   = '0;
    cl_sh_dma_pcis_rlast   = 1'b0;
    cl_sh_dma_pcis_ruser   = '0;
    cl_sh_dma_pcis_rvalid  = 1'b0;
  end

  always_comb begin
    cl_sda_awready = 1'b0;
    cl_sda_wready  = 1'b0;
    cl_sda_bresp   = '0;
    cl_sda_bvalid  = 1'b0;
    cl_sda_arready = 1'b0;
    cl_sda_rdata   = '0;
    cl_sda_rresp   = '0;
    cl_sda_rvalid  = 1'b0;
  end

  always_comb begin
    cl_sh_apppf_irq_req = '0;
    tdo = 1'b0;
    PCIE_EP_TXP = '0;
    PCIE_EP_TXN = '0;
    PCIE_RP_PERSTN = 1'b0;
    PCIE_RP_TXP = '0;
    PCIE_RP_TXN = '0;
  end

  always_comb begin
    hbm_axi4_bus.awid = '0;
    hbm_axi4_bus.wid  = '0;
    hbm_axi4_bus.arid = '0;
  end

  always_comb begin
    hbm_stat_bus.addr = '0;
    hbm_stat_bus.wdata = '0;
    hbm_stat_bus.wr = 1'b0;
    hbm_stat_bus.rd = 1'b0;
    hbm_stat_bus.user = '0;
  end

  vtpu_f2_smoke_top #(
    .HBM_BYTES(1048576),
    .VMEM_BYTES(4096),
    .CMEM_BYTES(4096),
    .INSTR_DEPTH(64)
  ) VTPU (
    .clk(clk_main_a0),
    .rst_n(vtpu_rst_n),
    .s_ocl_awaddr(ocl_cl_awaddr),
    .s_ocl_awvalid(ocl_cl_awvalid),
    .s_ocl_awready(cl_ocl_awready),
    .s_ocl_wdata(ocl_cl_wdata),
    .s_ocl_wstrb(ocl_cl_wstrb),
    .s_ocl_wvalid(ocl_cl_wvalid),
    .s_ocl_wready(cl_ocl_wready),
    .s_ocl_bresp(cl_ocl_bresp),
    .s_ocl_bvalid(cl_ocl_bvalid),
    .s_ocl_bready(ocl_cl_bready),
    .s_ocl_araddr(ocl_cl_araddr),
    .s_ocl_arvalid(ocl_cl_arvalid),
    .s_ocl_arready(cl_ocl_arready),
    .s_ocl_rdata(cl_ocl_rdata),
    .s_ocl_rresp(cl_ocl_rresp),
    .s_ocl_rvalid(cl_ocl_rvalid),
    .s_ocl_rready(ocl_cl_rready),
    .m_hbm_awaddr(hbm_axi4_bus.awaddr),
    .m_hbm_awlen(hbm_axi4_bus.awlen),
    .m_hbm_awsize(hbm_axi4_bus.awsize),
    .m_hbm_awburst(hbm_axi4_bus.awburst),
    .m_hbm_awvalid(hbm_axi4_bus.awvalid),
    .m_hbm_awready(hbm_axi4_bus.awready),
    .m_hbm_wdata(hbm_axi4_bus.wdata),
    .m_hbm_wstrb(hbm_axi4_bus.wstrb),
    .m_hbm_wlast(hbm_axi4_bus.wlast),
    .m_hbm_wvalid(hbm_axi4_bus.wvalid),
    .m_hbm_wready(hbm_axi4_bus.wready),
    .m_hbm_bresp(hbm_axi4_bus.bresp),
    .m_hbm_bvalid(hbm_axi4_bus.bvalid),
    .m_hbm_bready(hbm_axi4_bus.bready),
    .m_hbm_araddr(hbm_axi4_bus.araddr),
    .m_hbm_arlen(hbm_axi4_bus.arlen),
    .m_hbm_arsize(hbm_axi4_bus.arsize),
    .m_hbm_arburst(hbm_axi4_bus.arburst),
    .m_hbm_arvalid(hbm_axi4_bus.arvalid),
    .m_hbm_arready(hbm_axi4_bus.arready),
    .m_hbm_rdata(hbm_axi4_bus.rdata),
    .m_hbm_rresp(hbm_axi4_bus.rresp),
    .m_hbm_rvalid(hbm_axi4_bus.rvalid),
    .m_hbm_rlast(hbm_axi4_bus.rlast),
    .m_hbm_rready(hbm_axi4_bus.rready),
    .done(vtpu_done),
    .busy(vtpu_busy),
    .error(vtpu_error)
  );

  cl_hbm_axi4 #(
    .HBM_PRESENT(EN_HBM)
  ) HBM (
    .clk_hbm_ref(clk_hbm_ref),
    .clk(clk_main_a0),
    .rst_n(rst_main_n && !sh_cl_flr_assert),
    .hbm_axi4_bus(hbm_axi4_bus),
    .hbm_stat_bus(hbm_stat_bus),
    .i_hbm_apb_preset_n_1(hbm_apb_preset_n_1),
    .o_hbm_apb_paddr_1(hbm_apb_paddr_1),
    .o_hbm_apb_pprot_1(hbm_apb_pprot_1),
    .o_hbm_apb_psel_1(hbm_apb_psel_1),
    .o_hbm_apb_penable_1(hbm_apb_penable_1),
    .o_hbm_apb_pwrite_1(hbm_apb_pwrite_1),
    .o_hbm_apb_pwdata_1(hbm_apb_pwdata_1),
    .o_hbm_apb_pstrb_1(hbm_apb_pstrb_1),
    .o_hbm_apb_pready_1(hbm_apb_pready_1),
    .o_hbm_apb_prdata_1(hbm_apb_prdata_1),
    .o_hbm_apb_pslverr_1(hbm_apb_pslverr_1),
    .i_hbm_apb_preset_n_0(hbm_apb_preset_n_0),
    .o_hbm_apb_paddr_0(hbm_apb_paddr_0),
    .o_hbm_apb_pprot_0(hbm_apb_pprot_0),
    .o_hbm_apb_psel_0(hbm_apb_psel_0),
    .o_hbm_apb_penable_0(hbm_apb_penable_0),
    .o_hbm_apb_pwrite_0(hbm_apb_pwrite_0),
    .o_hbm_apb_pwdata_0(hbm_apb_pwdata_0),
    .o_hbm_apb_pstrb_0(hbm_apb_pstrb_0),
    .o_hbm_apb_pready_0(hbm_apb_pready_0),
    .o_hbm_apb_prdata_0(hbm_apb_prdata_0),
    .o_hbm_apb_pslverr_0(hbm_apb_pslverr_0),
    .o_cl_sh_hbm_stat_int(),
    .o_hbm_ready(hbm_ready)
  );

  sh_ddr #(
    .DDR_PRESENT(EN_DDR)
  ) SH_DDR (
    .clk(clk_main_a0),
    .rst_n(),
    .stat_clk(clk_main_a0),
    .stat_rst_n(),
    .CLK_DIMM_DP(CLK_DIMM_DP),
    .CLK_DIMM_DN(CLK_DIMM_DN),
    .M_ACT_N(M_ACT_N),
    .M_MA(M_MA),
    .M_BA(M_BA),
    .M_BG(M_BG),
    .M_CKE(M_CKE),
    .M_ODT(M_ODT),
    .M_CS_N(M_CS_N),
    .M_CLK_DN(M_CLK_DN),
    .M_CLK_DP(M_CLK_DP),
    .M_PAR(M_PAR),
    .M_DQ(M_DQ),
    .M_ECC(M_ECC),
    .M_DQS_DP(M_DQS_DP),
    .M_DQS_DN(M_DQS_DN),
    .cl_RST_DIMM_N(RST_DIMM_N),
    .cl_sh_ddr_axi_awid(),
    .cl_sh_ddr_axi_awaddr(),
    .cl_sh_ddr_axi_awlen(),
    .cl_sh_ddr_axi_awsize(),
    .cl_sh_ddr_axi_awvalid(),
    .cl_sh_ddr_axi_awburst(),
    .cl_sh_ddr_axi_awuser(),
    .cl_sh_ddr_axi_awready(),
    .cl_sh_ddr_axi_wdata(),
    .cl_sh_ddr_axi_wstrb(),
    .cl_sh_ddr_axi_wlast(),
    .cl_sh_ddr_axi_wvalid(),
    .cl_sh_ddr_axi_wready(),
    .cl_sh_ddr_axi_bid(),
    .cl_sh_ddr_axi_bresp(),
    .cl_sh_ddr_axi_bvalid(),
    .cl_sh_ddr_axi_bready(),
    .cl_sh_ddr_axi_arid(),
    .cl_sh_ddr_axi_araddr(),
    .cl_sh_ddr_axi_arlen(),
    .cl_sh_ddr_axi_arsize(),
    .cl_sh_ddr_axi_arvalid(),
    .cl_sh_ddr_axi_arburst(),
    .cl_sh_ddr_axi_aruser(),
    .cl_sh_ddr_axi_arready(),
    .cl_sh_ddr_axi_rid(),
    .cl_sh_ddr_axi_rdata(),
    .cl_sh_ddr_axi_rresp(),
    .cl_sh_ddr_axi_rlast(),
    .cl_sh_ddr_axi_rvalid(),
    .cl_sh_ddr_axi_rready(),
    .sh_ddr_stat_bus_addr(),
    .sh_ddr_stat_bus_wdata(),
    .sh_ddr_stat_bus_wr(),
    .sh_ddr_stat_bus_rd(),
    .sh_ddr_stat_bus_ack(),
    .sh_ddr_stat_bus_rdata(),
    .ddr_sh_stat_int(),
    .sh_cl_ddr_is_ready()
  );

  always_comb begin
    cl_sh_ddr_stat_ack = 1'b0;
    cl_sh_ddr_stat_rdata = '0;
    cl_sh_ddr_stat_int = '0;
  end
endmodule
