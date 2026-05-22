// Module: vtpu_pd_tiny_top
// Purpose: ASIC physical-design wrapper around a reduced vTPU instance.
// Notes: Keeps the external boundary scalar-only for synthesis/P&R tools.
module vtpu_pd_tiny_top (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        host_req_valid,
  input  logic        host_req_write,
  input  logic [31:0] host_req_addr,
  input  logic [31:0] host_req_wdata,
  output logic        host_req_ready,

  output logic        host_resp_valid,
  output logic [31:0] host_resp_rdata,
  output logic        host_resp_error,

  output logic        done,
  output logic        busy,
  output logic        error
);
  vtpu_pkg::host_req_t host_req;
  vtpu_pkg::host_resp_t host_resp;
  logic host_resp_valid_unused;

  assign host_req.valid = host_req_valid;
  assign host_req.write = host_req_write;
  assign host_req.addr = host_req_addr;
  assign host_req.wdata = host_req_wdata;

  assign host_resp_valid = host_resp.valid;
  assign host_resp_rdata = host_resp.rdata;
  assign host_resp_error = host_resp.error;

  virtual_tpu_v4_top #(
    .NUM_TENSOR_CORES(2),
    .MXUS_PER_TC(4),
    .ARRAY_M(2),
    .ARRAY_N(2),
    .ARRAY_K(2),
    .DATA_W(8),
    .ACC_W(32),
    .VMEM_BYTES(256),
    .CMEM_BYTES(256),
    .HBM_BYTES(256),
    .INSTR_DEPTH(16)
  ) u_vtpu (
    .clk(clk),
    .rst_n(rst_n),
    .host_req(host_req),
    .host_req_valid(host_req_valid),
    .host_req_ready(host_req_ready),
    .host_resp(host_resp),
    .host_resp_valid(host_resp_valid_unused),
    .done(done),
    .busy(busy),
    .error(error)
  );
endmodule
