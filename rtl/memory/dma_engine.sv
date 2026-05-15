// Module: dma_engine
// Purpose: Blocking DMA command/status shell for memory copy integration.
// Public TPU inspiration: Explicit DMA moves tensors between global and local memory.
// Educational simplification: One command is accepted and completed after a length-derived delay.
// Inputs: dma_cmd_t command.
// Outputs: unit_status_t status.
// State: IDLE -> RUN -> DONE -> IDLE or ERROR.
// Latency: max(1, len_bytes / 32) cycles for aligned commands.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Unaligned command addresses or lengths enter ERROR.
// Tests: Future cocotb DMA tests; Python golden model owns byte-accurate copy behavior now.
module dma_engine (
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::dma_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  output vtpu_pkg::unit_status_t status
);
  typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_DONE, ST_ERROR} state_t;

  state_t state_q;
  logic [31:0] cycles_left_q;

  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q == ST_RUN);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? vtpu_pkg::ERR_UNALIGNED : vtpu_pkg::ERR_NONE;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cycles_left_q <= 32'd0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (cmd_valid) begin
            if ((cmd.src_addr[1:0] != 2'b00) || (cmd.dst_addr[1:0] != 2'b00) || (cmd.len_bytes[1:0] != 2'b00)) begin
              state_q <= ST_ERROR;
            end else begin
              state_q <= ST_RUN;
              cycles_left_q <= (cmd.len_bytes == 32'd0) ? 32'd1 : ((cmd.len_bytes + 32'd31) >> 5);
            end
          end
        end
        ST_RUN: begin
          if (cycles_left_q <= 32'd1) begin
            state_q <= ST_DONE;
            cycles_left_q <= 32'd0;
          end else begin
            cycles_left_q <= cycles_left_q - 32'd1;
          end
        end
        ST_DONE: state_q <= ST_IDLE;
        ST_ERROR: state_q <= ST_ERROR;
        default: state_q <= ST_ERROR;
      endcase
    end
  end
endmodule
