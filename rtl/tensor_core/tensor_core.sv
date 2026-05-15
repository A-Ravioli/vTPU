// Module: tensor_core
// Purpose: TensorCore command router shell with one active MXU plus vector/reduce status units.
// Public TPU inspiration: TPU v4-style chips have TensorCores containing MXUs and vector/scalar units.
// Educational simplification: One MXU data path is exposed; extra units validate timing/status only.
// Inputs: tc_cmd_t command and flattened tile ports.
// Outputs: status and C tile.
// State: Delegated to MXU/vector/reduce units.
// Latency: Unit-dependent.
// Backpressure: cmd_ready requires the selected unit to be ready.
// Error behavior: Unsupported opcodes enter error status.
// Tests: Future TensorCore cocotb tests; Python golden model covers command behavior.
module tensor_core #(
  parameter int TC_ID = 0,
  parameter int MXUS_PER_TC = 4,
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W = 8,
  parameter int ACC_W = 32
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::tc_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  input  logic signed [DATA_W-1:0] a_tile [0:ARRAY_M*ARRAY_K-1],
  input  logic signed [DATA_W-1:0] b_tile [0:ARRAY_K*ARRAY_N-1],
  input  logic signed [ACC_W-1:0] c_in [0:ARRAY_M*ARRAY_N-1],
  output logic signed [ACC_W-1:0] c_out [0:ARRAY_M*ARRAY_N-1],
  output vtpu_pkg::unit_status_t status
);
  vtpu_pkg::mxu_cmd_t mxu_cmd;
  vtpu_pkg::unit_status_t mxu_status;
  vtpu_pkg::vector_cmd_t vector_cmd;
  vtpu_pkg::unit_status_t vector_status;
  vtpu_pkg::reduce_cmd_t reduce_cmd;
  vtpu_pkg::unit_status_t reduce_status;
  logic mxu_valid;
  logic vector_valid;
  logic reduce_valid;
  logic mxu_ready;
  logic vector_ready;
  logic reduce_ready;
  logic unsupported_q;

  assign mxu_cmd.dst_addr = cmd.dst;
  assign mxu_cmd.a_addr = cmd.src0;
  assign mxu_cmd.b_addr = cmd.src1;
  assign mxu_cmd.m = cmd.imm0;
  assign mxu_cmd.n = cmd.imm1;
  assign mxu_cmd.k = cmd.imm2;
  assign mxu_cmd.accumulate = cmd.flags[0];

  assign vector_cmd.dst_addr = cmd.dst;
  assign vector_cmd.src0_addr = cmd.src0;
  assign vector_cmd.src1_addr = cmd.src1;
  assign vector_cmd.length = cmd.imm0;
  assign vector_cmd.op = cmd.imm1[7:0];
  assign vector_cmd.imm = cmd.imm2;

  assign reduce_cmd.dst_addr = cmd.dst;
  assign reduce_cmd.src_addr = cmd.src0;
  assign reduce_cmd.length = cmd.imm0;
  assign reduce_cmd.op = cmd.imm1[7:0];
  assign reduce_cmd.columns = cmd.imm2;

  assign mxu_valid = cmd_valid && (cmd.opcode == vtpu_pkg::OPC_MATMUL);
  assign vector_valid = cmd_valid && (cmd.opcode == vtpu_pkg::OPC_VECTOR_OP);
  assign reduce_valid = cmd_valid && (cmd.opcode == vtpu_pkg::OPC_REDUCE);
  assign cmd_ready = ((cmd.opcode == vtpu_pkg::OPC_MATMUL) && !mxu_status.busy) ||
                     ((cmd.opcode == vtpu_pkg::OPC_VECTOR_OP) && vector_ready) ||
                     ((cmd.opcode == vtpu_pkg::OPC_REDUCE) && reduce_ready) ||
                     (cmd.opcode == vtpu_pkg::OPC_CLEAR);

  mxu_top #(
    .ARRAY_M(ARRAY_M),
    .ARRAY_N(ARRAY_N),
    .ARRAY_K(ARRAY_K),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
  ) u_mxu (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(mxu_cmd),
    .cmd_valid(mxu_valid),
    .cmd_ready(mxu_ready),
    .a_tile(a_tile),
    .b_tile(b_tile),
    .c_in(c_in),
    .c_out(c_out),
    .status(mxu_status)
  );

  vector_unit u_vector (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(vector_cmd),
    .cmd_valid(vector_valid),
    .cmd_ready(vector_ready),
    .status(vector_status)
  );

  reduce_unit u_reduce (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(reduce_cmd),
    .cmd_valid(reduce_valid),
    .cmd_ready(reduce_ready),
    .status(reduce_status)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      unsupported_q <= 1'b0;
    end else if (cmd_valid &&
                 (cmd.opcode != vtpu_pkg::OPC_MATMUL) &&
                 (cmd.opcode != vtpu_pkg::OPC_VECTOR_OP) &&
                 (cmd.opcode != vtpu_pkg::OPC_REDUCE) &&
                 (cmd.opcode != vtpu_pkg::OPC_CLEAR)) begin
      unsupported_q <= 1'b1;
    end
  end

  assign status.busy = mxu_status.busy || vector_status.busy || reduce_status.busy;
  assign status.done = mxu_status.done || vector_status.done || reduce_status.done || (cmd_valid && (cmd.opcode == vtpu_pkg::OPC_CLEAR));
  assign status.error = unsupported_q || mxu_status.error || vector_status.error || reduce_status.error;
  assign status.error_code = (unsupported_q || mxu_status.error || vector_status.error || reduce_status.error) ?
                             vtpu_pkg::ERR_UNSUPPORTED : vtpu_pkg::ERR_NONE;
endmodule
