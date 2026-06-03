// Module: control_fsm
// Purpose: Fetch/decode/issue control for the educational ISA.
// Public TPU inspiration: Explicit instruction streams drive TPU-like accelerator units.
// Educational simplification: Single in-order issue with scoreboard-style barriers.
// Inputs: decoded instruction, legality, and unit statuses.
// Outputs: instruction fetch PC, DMA/TensorCore commands, done/busy/error status.
// State: IDLE -> FETCH -> DECODE -> ISSUE/WAIT -> HALT/ERROR.
// Latency: In-order; command completion is tracked by unit status and barriers.
// Backpressure: ISSUE holds valid until selected units accept.
// Error behavior: Illegal instructions or unit errors enter ERROR with a stable code.
module control_fsm #(
  parameter int NUM_TENSOR_CORES = 2
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic instr_fetch_en,
  output logic [31:0] pc,
  input  vtpu_pkg::decoded_instr_t decoded,
  input  logic illegal,
  input  logic [7:0] decode_error_code,
  output vtpu_pkg::dma_cmd_t dma_cmd,
  output logic dma_cmd_valid,
  input  logic dma_cmd_ready,
  input  vtpu_pkg::unit_status_t dma_status,
  output vtpu_pkg::tc_cmd_t tc_cmd [NUM_TENSOR_CORES],
  output logic tc_cmd_valid [NUM_TENSOR_CORES],
  input  logic tc_cmd_ready [NUM_TENSOR_CORES],
  input  vtpu_pkg::unit_status_t tc_status [NUM_TENSOR_CORES],
  output logic instr_retired,
  output logic barrier_wait,
  output logic error_pulse,
  output logic done,
  output logic busy,
  output logic error,
  output logic [7:0] error_code
);
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_FETCH,
    ST_DECODE,
    ST_ISSUE,
    ST_WAIT_BARRIER,
    ST_WAIT_HALT,
    ST_HALT,
    ST_ERROR
  } state_t;

  state_t state_q;
  logic [7:0] barrier_mask_q;
  logic [NUM_TENSOR_CORES-1:0] issue_tc_mask_q;
  logic [NUM_TENSOR_CORES-1:0] issued_tc_mask_q;
  logic dma_issue_q;
  logic issued_dma_q;
  logic [7:0] error_code_q;
  integer tc_comb_idx;
  integer tc_seq_idx;

  assign instr_fetch_en = (state_q == ST_FETCH) || (state_q == ST_DECODE);
  assign done = (state_q == ST_HALT);
  assign busy = (state_q != ST_IDLE) && (state_q != ST_HALT) && (state_q != ST_ERROR);
  assign error = (state_q == ST_ERROR);
  assign error_code = error_code_q;
  assign barrier_wait = (state_q == ST_WAIT_BARRIER) && scoreboard_busy(barrier_mask_q);

  assign dma_cmd.src_space = decoded.flags[2:0];
  assign dma_cmd.dst_space = decoded.flags[5:3];
  // 32-bit DMA addresses: low 16 bits in src0/dst, high 16 bits in imm2/imm1.
  assign dma_cmd.src_addr = {decoded.imm2, decoded.src0};
  assign dma_cmd.dst_addr = {decoded.imm1, decoded.dst};
  assign dma_cmd.len_bytes = {16'd0, decoded.imm0};

  function automatic logic op_uses_dma(input vtpu_pkg::opcode_t opcode);
    op_uses_dma = (opcode == vtpu_pkg::OPC_DMA_COPY) ||
                  (opcode == vtpu_pkg::OPC_LOAD_TILE) ||
                  (opcode == vtpu_pkg::OPC_STORE_TILE);
  endfunction

  function automatic logic op_uses_tc(input vtpu_pkg::opcode_t opcode);
    op_uses_tc = (opcode == vtpu_pkg::OPC_MATMUL) ||
                 (opcode == vtpu_pkg::OPC_VECTOR_OP) ||
                 (opcode == vtpu_pkg::OPC_REDUCE) ||
                 (opcode == vtpu_pkg::OPC_CLEAR);
  endfunction

  function automatic logic any_unit_busy;
    logic busy_any;
    integer idx;
    begin
      busy_any = dma_status.busy;
      for (idx = 0; idx < NUM_TENSOR_CORES; idx++) begin
        busy_any = busy_any || tc_status[idx].busy;
      end
      any_unit_busy = busy_any;
    end
  endfunction

  function automatic logic any_unit_error;
    logic error_any;
    integer idx;
    begin
      error_any = dma_status.error;
      for (idx = 0; idx < NUM_TENSOR_CORES; idx++) begin
        error_any = error_any || tc_status[idx].error;
      end
      any_unit_error = error_any;
    end
  endfunction

  function automatic logic [7:0] first_unit_error_code;
    integer idx;
    begin
      first_unit_error_code = vtpu_pkg::ERR_NONE;
      if (dma_status.error) begin
        first_unit_error_code = dma_status.error_code;
      end else begin
        for (idx = 0; idx < NUM_TENSOR_CORES; idx++) begin
          if (tc_status[idx].error && (first_unit_error_code == vtpu_pkg::ERR_NONE)) begin
            first_unit_error_code = tc_status[idx].error_code;
          end
        end
      end
    end
  endfunction

  function automatic logic scoreboard_busy(input logic [7:0] mask);
    logic wait_dma;
    logic wait_tc;
    integer idx;
    begin
      wait_dma = mask[0];
      wait_tc = mask[1] || mask[2] || mask[3] || mask[5] || mask[6];
      scoreboard_busy = (wait_dma && dma_status.busy);
      if (wait_tc) begin
        for (idx = 0; idx < NUM_TENSOR_CORES; idx++) begin
          scoreboard_busy = scoreboard_busy || tc_status[idx].busy;
        end
      end
    end
  endfunction

  function automatic logic [NUM_TENSOR_CORES-1:0] target_tc_mask(input logic [7:0] target);
    logic [NUM_TENSOR_CORES-1:0] mask;
    integer idx;
    begin
      mask = '0;
      for (idx = 0; idx < NUM_TENSOR_CORES; idx++) begin
        if ((idx < 4) && target[4 + idx]) begin
          mask[idx] = 1'b1;
        end
      end
      target_tc_mask = mask;
    end
  endfunction

  function automatic logic [NUM_TENSOR_CORES-1:0] decoded_tc_mask(input vtpu_pkg::decoded_instr_t instr);
    logic [NUM_TENSOR_CORES-1:0] mask;
    begin
      mask = '0;
      if (instr.opcode == vtpu_pkg::OPC_CLEAR) begin
        if (instr.flags[2:0] == vtpu_pkg::MEM_VMEM0) begin
          mask[0] = 1'b1;
        end else if ((NUM_TENSOR_CORES > 1) && (instr.flags[2:0] == vtpu_pkg::MEM_VMEM1)) begin
          mask[1] = 1'b1;
        end
      end else begin
        mask = target_tc_mask(instr.target);
      end
      decoded_tc_mask = mask;
    end
  endfunction

  always_comb begin
    dma_cmd_valid = 1'b0;
    for (tc_comb_idx = 0; tc_comb_idx < NUM_TENSOR_CORES; tc_comb_idx++) begin
      tc_cmd_valid[tc_comb_idx] = 1'b0;
      tc_cmd[tc_comb_idx] = '0;
      tc_cmd[tc_comb_idx].opcode = decoded.opcode;
      tc_cmd[tc_comb_idx].flags = decoded.flags;
      tc_cmd[tc_comb_idx].target = decoded.target;
      tc_cmd[tc_comb_idx].dst = decoded.dst;
      tc_cmd[tc_comb_idx].src0 = decoded.src0;
      tc_cmd[tc_comb_idx].src1 = decoded.src1;
      tc_cmd[tc_comb_idx].imm0 = decoded.imm0;
      tc_cmd[tc_comb_idx].imm1 = decoded.imm1;
      tc_cmd[tc_comb_idx].imm2 = decoded.imm2;
    end

    if (state_q == ST_ISSUE) begin
      if (dma_issue_q && !issued_dma_q) begin
        dma_cmd_valid = 1'b1;
      end
      for (tc_comb_idx = 0; tc_comb_idx < NUM_TENSOR_CORES; tc_comb_idx++) begin
        if (issue_tc_mask_q[tc_comb_idx] && !issued_tc_mask_q[tc_comb_idx]) begin
          tc_cmd_valid[tc_comb_idx] = 1'b1;
        end
      end
    end
  end

  task automatic retire_and_fetch;
    begin
      instr_retired <= 1'b1;
      pc <= pc + 32'd1;
      state_q <= ST_FETCH;
    end
  endtask

  task automatic enter_error(input logic [7:0] code);
    begin
      state_q <= ST_ERROR;
      error_code_q <= (code == vtpu_pkg::ERR_NONE) ? vtpu_pkg::ERR_UNSUPPORTED : code;
      error_pulse <= 1'b1;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    logic [NUM_TENSOR_CORES-1:0] next_issued_tc_mask;
    logic next_issued_dma;

    if (!rst_n) begin
      state_q <= ST_IDLE;
      pc <= 32'd0;
      barrier_mask_q <= 8'd0;
      issue_tc_mask_q <= '0;
      issued_tc_mask_q <= '0;
      dma_issue_q <= 1'b0;
      issued_dma_q <= 1'b0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      instr_retired <= 1'b0;
      error_pulse <= 1'b0;
    end else begin
      instr_retired <= 1'b0;
      error_pulse <= 1'b0;
      next_issued_tc_mask = issued_tc_mask_q;
      next_issued_dma = issued_dma_q;

      if (start && ((state_q == ST_IDLE) || (state_q == ST_HALT) || (state_q == ST_ERROR))) begin
        state_q <= ST_FETCH;
        pc <= 32'd0;
        barrier_mask_q <= 8'd0;
        issue_tc_mask_q <= '0;
        issued_tc_mask_q <= '0;
        dma_issue_q <= 1'b0;
        issued_dma_q <= 1'b0;
        error_code_q <= vtpu_pkg::ERR_NONE;
      end else if (any_unit_error() && (state_q != ST_ERROR)) begin
        enter_error(first_unit_error_code());
      end else begin
        unique case (state_q)
          ST_IDLE: begin
            pc <= 32'd0;
          end
          ST_FETCH: begin
            state_q <= ST_DECODE;
          end
          ST_DECODE: begin
            if (illegal) begin
              enter_error(decode_error_code);
            end else if ((decoded.opcode == vtpu_pkg::OPC_NOP) ||
                         (decoded.opcode == vtpu_pkg::OPC_SYNC)) begin
              retire_and_fetch();
            end else if (decoded.opcode == vtpu_pkg::OPC_HALT) begin
              if (any_unit_busy()) begin
                state_q <= ST_WAIT_HALT;
              end else begin
                instr_retired <= 1'b1;
                pc <= pc + 32'd1;
                state_q <= ST_HALT;
              end
            end else if (decoded.opcode == vtpu_pkg::OPC_BARRIER) begin
              barrier_mask_q <= decoded.imm0[7:0];
              if (scoreboard_busy(decoded.imm0[7:0])) begin
                state_q <= ST_WAIT_BARRIER;
              end else begin
                retire_and_fetch();
              end
            end else if (op_uses_dma(decoded.opcode)) begin
              dma_issue_q <= 1'b1;
              issued_dma_q <= 1'b0;
              issue_tc_mask_q <= '0;
              issued_tc_mask_q <= '0;
              state_q <= ST_ISSUE;
            end else if (op_uses_tc(decoded.opcode)) begin
              dma_issue_q <= 1'b0;
              issued_dma_q <= 1'b0;
              issue_tc_mask_q <= decoded_tc_mask(decoded);
              issued_tc_mask_q <= '0;
              if (decoded_tc_mask(decoded) == '0) begin
                enter_error(vtpu_pkg::ERR_BAD_TARGET);
              end else begin
                state_q <= ST_ISSUE;
              end
            end else begin
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end
          end
          ST_ISSUE: begin
            if (dma_issue_q && !issued_dma_q && dma_cmd_ready) begin
              next_issued_dma = 1'b1;
              issued_dma_q <= 1'b1;
            end
            for (tc_seq_idx = 0; tc_seq_idx < NUM_TENSOR_CORES; tc_seq_idx++) begin
              if (issue_tc_mask_q[tc_seq_idx] && !issued_tc_mask_q[tc_seq_idx] && tc_cmd_ready[tc_seq_idx]) begin
                next_issued_tc_mask[tc_seq_idx] = 1'b1;
                issued_tc_mask_q[tc_seq_idx] <= 1'b1;
              end
            end

            if ((dma_issue_q && next_issued_dma) ||
                ((issue_tc_mask_q != '0) && ((next_issued_tc_mask & issue_tc_mask_q) == issue_tc_mask_q))) begin
              dma_issue_q <= 1'b0;
              issued_dma_q <= 1'b0;
              issue_tc_mask_q <= '0;
              issued_tc_mask_q <= '0;
              retire_and_fetch();
            end
          end
          ST_WAIT_BARRIER: begin
            if (!scoreboard_busy(barrier_mask_q)) begin
              retire_and_fetch();
            end
          end
          ST_WAIT_HALT: begin
            if (!any_unit_busy()) begin
              instr_retired <= 1'b1;
              pc <= pc + 32'd1;
              state_q <= ST_HALT;
            end
          end
          ST_HALT: begin
          end
          ST_ERROR: begin
          end
          default: begin
            enter_error(vtpu_pkg::ERR_UNSUPPORTED);
          end
        endcase
      end
    end
  end
endmodule
