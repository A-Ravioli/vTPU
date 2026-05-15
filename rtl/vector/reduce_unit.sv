// Module: reduce_unit
// Purpose: Command/status shell for documented reductions.
// Public TPU inspiration: TensorCore-adjacent units perform reductions for ML kernels.
// Educational simplification: Python golden model owns data math; RTL validates commands and timing.
// Inputs: reduce_cmd_t command.
// Outputs: unit_status_t status.
// State: IDLE -> RUN -> DONE -> IDLE or ERROR.
// Latency: One cycle per 16 inputs, minimum one cycle.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Unsupported op, zero length, or missing columns for row/col reductions enters ERROR.
// Tests: Python golden reduce tests; future cocotb tests should add VMEM data-path checks.
module reduce_unit #(
  parameter int LANES = 16
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::reduce_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  output vtpu_pkg::unit_status_t status
);
  typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_DONE, ST_ERROR} state_t;
  state_t state_q;
  logic [15:0] cycles_left_q;
  logic op_ok;
  logic columns_ok;

  assign op_ok = (cmd.op <= 8'd5);
  assign columns_ok = (cmd.op <= 8'd1) || (cmd.columns != 16'd0);
  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q == ST_RUN);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? vtpu_pkg::ERR_UNSUPPORTED : vtpu_pkg::ERR_NONE;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cycles_left_q <= 16'd0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (cmd_valid) begin
            if (!op_ok || !columns_ok || (cmd.length == 16'd0)) begin
              state_q <= ST_ERROR;
            end else begin
              state_q <= ST_RUN;
              cycles_left_q <= (cmd.length + LANES[15:0] - 16'd1) / LANES[15:0];
            end
          end
        end
        ST_RUN: begin
          if (cycles_left_q <= 16'd1) begin
            state_q <= ST_DONE;
          end else begin
            cycles_left_q <= cycles_left_q - 16'd1;
          end
        end
        ST_DONE: state_q <= ST_IDLE;
        ST_ERROR: state_q <= ST_ERROR;
        default: state_q <= ST_ERROR;
      endcase
    end
  end
endmodule
