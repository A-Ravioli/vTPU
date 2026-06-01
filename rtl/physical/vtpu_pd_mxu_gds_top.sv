// Module: vtpu_pd_mxu_gds_top
// Purpose: Minimal physical-design bring-up wrapper for one vTPU MXU datapath.
// Notes: This target is intentionally small enough to exercise the full GDS flow.
module vtpu_pd_mxu_gds_top (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        cmd_valid,
  input  logic [15:0] dst_addr,
  input  logic [15:0] src_a_addr,
  input  logic [15:0] src_b_addr,
  input  logic [15:0] m,
  input  logic [15:0] n,
  input  logic [15:0] k,
  input  logic        accumulate,

  input  logic        vmem_ready,
  input  logic        vmem_valid,
  input  logic [31:0] vmem_rdata,
  input  logic        vmem_error,

  output logic        cmd_ready,
  output logic        vmem_req_valid,
  output logic        vmem_req_write,
  output logic [31:0] vmem_req_addr,
  output logic [31:0] vmem_req_wdata,
  output logic [3:0]  vmem_req_wstrb,
  output logic        busy,
  output logic        done,
  output logic        error,
  output logic [7:0]  error_code
);
  vtpu_pkg::mxu_cmd_t cmd;
  vtpu_pkg::vmem_req_t vmem_req;
  vtpu_pkg::vmem_resp_t vmem_resp;
  vtpu_pkg::unit_status_t status;

  assign cmd.dst_addr = dst_addr;
  assign cmd.a_addr = src_a_addr;
  assign cmd.b_addr = src_b_addr;
  assign cmd.m = m;
  assign cmd.n = n;
  assign cmd.k = k;
  assign cmd.accumulate = accumulate;
  assign cmd.bf16 = 1'b0;

  assign vmem_resp.ready = vmem_ready;
  assign vmem_resp.valid = vmem_valid;
  assign vmem_resp.rdata = vmem_rdata;
  assign vmem_resp.error = vmem_error;

  assign vmem_req_valid = vmem_req.valid;
  assign vmem_req_write = vmem_req.write;
  assign vmem_req_addr = vmem_req.addr;
  assign vmem_req_wdata = vmem_req.wdata;
  assign vmem_req_wstrb = vmem_req.wstrb;

  assign busy = status.busy;
  assign done = status.done;
  assign error = status.error;
  assign error_code = status.error_code;

  mxu_top #(
    .ARRAY_M(1),
    .ARRAY_N(1),
    .ARRAY_K(1),
    .DATA_W(8),
    .ACC_W(32),
    .VMEM_BYTES(64)
  ) u_mxu (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(cmd),
    .cmd_valid(cmd_valid),
    .cmd_ready(cmd_ready),
    .vmem_req(vmem_req),
    .vmem_resp(vmem_resp),
    .status(status)
  );
endmodule
