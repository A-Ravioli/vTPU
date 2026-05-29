// Module: vtpu_pd_smoke_top
// Purpose: Smallest current full-chip physical smoke target for reaching GDS.
// Notes: Keeps both TensorCore slots because virtual_tpu_v4_top currently wires
//        TC0 and TC1 explicitly, but reduces MXU count, array size, and memories.
module vtpu_pd_smoke_top (
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
    .MXUS_PER_TC(1),
    .ARRAY_M(1),
    .ARRAY_N(1),
    .ARRAY_K(1),
    .DATA_W(8),
    .ACC_W(32),
    .VMEM_BYTES(64),
    .CMEM_BYTES(64),
    .HBM_BYTES(64),
    .INSTR_DEPTH(4),
    .PHYSICAL_MEMORIES(1'b1)
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
