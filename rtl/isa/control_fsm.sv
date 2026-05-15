// Module: control_fsm
// Purpose: Minimal fetch/decode/issue shell for the educational ISA.
// Public TPU inspiration: Explicit instruction streams drive TPU-like accelerator units.
// Educational simplification: Issues one decoded command at a time and models barriers using status inputs.
// Inputs: decoded instruction and unit statuses.
// Outputs: fetch enable, DMA/TC command valid, done/error.
// State: IDLE -> FETCH -> DECODE -> ISSUE/WAIT -> HALT/ERROR.
// Latency: One instruction can retire every few cycles when units are ready.
// Backpressure: ISSUE waits for command ready.
// Error behavior: illegal instruction enters ERROR.
// Tests: Future chip cocotb tests; Python golden model owns full semantics now.
module control_fsm #(
  parameter int NUM_TENSOR_CORES = 2
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic instr_fetch_en,
  output logic [15:0] pc,
  input  vtpu_pkg::decoded_instr_t decoded,
  input  logic illegal,
  output vtpu_pkg::dma_cmd_t dma_cmd,
  output logic dma_cmd_valid,
  input  logic dma_cmd_ready,
  input  vtpu_pkg::unit_status_t dma_status,
  output vtpu_pkg::tc_cmd_t tc_cmd [NUM_TENSOR_CORES],
  output logic tc_cmd_valid [NUM_TENSOR_CORES],
  input  logic tc_cmd_ready [NUM_TENSOR_CORES],
  input  vtpu_pkg::unit_status_t tc_status [NUM_TENSOR_CORES],
  output logic done,
  output logic busy,
  output logic error,
  output logic [7:0] error_code
);
  typedef enum logic [2:0] {ST_IDLE, ST_FETCH, ST_DECODE, ST_ISSUE, ST_WAIT, ST_HALT, ST_ERROR} state_t;
  state_t state_q;
  logic [7:0] barrier_mask_q;
  int tc_idx;

  assign instr_fetch_en = (state_q == ST_FETCH);
  assign done = (state_q == ST_HALT);
  assign busy = (state_q != ST_IDLE) && (state_q != ST_HALT) && (state_q != ST_ERROR);
  assign error = (state_q == ST_ERROR);
  assign error_code = error ? vtpu_pkg::ERR_BAD_OPCODE : vtpu_pkg::ERR_NONE;
  assign dma_cmd.src_space = decoded.flags[2:0];
  assign dma_cmd.dst_space = decoded.flags[5:3];
  assign dma_cmd.src_addr = {16'd0, decoded.src0};
  assign dma_cmd.dst_addr = {16'd0, decoded.dst};
  assign dma_cmd.len_bytes = {16'd0, decoded.imm0};

  always_comb begin
    dma_cmd_valid = 1'b0;
    for (tc_idx = 0; tc_idx < NUM_TENSOR_CORES; tc_idx++) begin
      tc_cmd_valid[tc_idx] = 1'b0;
      tc_cmd[tc_idx] = '0;
      tc_cmd[tc_idx].opcode = decoded.opcode;
      tc_cmd[tc_idx].flags = decoded.flags;
      tc_cmd[tc_idx].target = decoded.target;
      tc_cmd[tc_idx].dst = decoded.dst;
      tc_cmd[tc_idx].src0 = decoded.src0;
      tc_cmd[tc_idx].src1 = decoded.src1;
      tc_cmd[tc_idx].imm0 = decoded.imm0;
      tc_cmd[tc_idx].imm1 = decoded.imm1;
      tc_cmd[tc_idx].imm2 = decoded.imm2;
    end
    if (state_q == ST_ISSUE) begin
      if ((decoded.opcode == vtpu_pkg::OPC_DMA_COPY) ||
          (decoded.opcode == vtpu_pkg::OPC_LOAD_TILE) ||
          (decoded.opcode == vtpu_pkg::OPC_STORE_TILE)) begin
        dma_cmd_valid = 1'b1;
      end else if ((decoded.opcode == vtpu_pkg::OPC_MATMUL) ||
                   (decoded.opcode == vtpu_pkg::OPC_VECTOR_OP) ||
                   (decoded.opcode == vtpu_pkg::OPC_REDUCE) ||
                   (decoded.opcode == vtpu_pkg::OPC_CLEAR)) begin
        if (decoded.target[4]) tc_cmd_valid[0] = 1'b1;
        if ((NUM_TENSOR_CORES > 1) && decoded.target[5]) tc_cmd_valid[1] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      pc <= 16'd0;
      barrier_mask_q <= 8'd0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          pc <= 16'd0;
          if (start) state_q <= ST_FETCH;
        end
        ST_FETCH: state_q <= ST_DECODE;
        ST_DECODE: begin
          if (illegal) begin
            state_q <= ST_ERROR;
          end else if (decoded.opcode == vtpu_pkg::OPC_HALT) begin
            state_q <= ST_HALT;
          end else if (decoded.opcode == vtpu_pkg::OPC_BARRIER) begin
            barrier_mask_q <= decoded.imm0[7:0];
            state_q <= ST_WAIT;
          end else begin
            state_q <= ST_ISSUE;
          end
        end
        ST_ISSUE: begin
          if ((decoded.opcode == vtpu_pkg::OPC_DMA_COPY) ||
              (decoded.opcode == vtpu_pkg::OPC_LOAD_TILE) ||
              (decoded.opcode == vtpu_pkg::OPC_STORE_TILE)) begin
            if (dma_cmd_ready) begin
              pc <= pc + 16'd1;
              state_q <= ST_FETCH;
            end
          end else begin
            pc <= pc + 16'd1;
            state_q <= ST_FETCH;
          end
        end
        ST_WAIT: begin
          if (((barrier_mask_q[0] == 1'b0) || !dma_status.busy) &&
              ((barrier_mask_q[1] == 1'b0) || !tc_status[0].busy)) begin
            pc <= pc + 16'd1;
            state_q <= ST_FETCH;
          end
        end
        ST_HALT: state_q <= ST_HALT;
        ST_ERROR: state_q <= ST_ERROR;
        default: state_q <= ST_ERROR;
      endcase
    end
  end
endmodule
