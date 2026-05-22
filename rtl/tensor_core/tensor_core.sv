// Module: tensor_core
// Purpose: Structural TensorCore containing VMEM, 4 MXUs, vector, reduce, arbitration, and local scheduling.
// Public TPU inspiration: TPU v4-style chips contain TensorCores with local VMEM and matrix/vector units.
// Educational simplification: MXUs share a banked VMEM model with deterministic arbitration.
// Inputs: TensorCore command stream and DMA VMEM request port.
// Outputs: DMA response, aggregate status, per-MXU status, and VMEM counter pulses.
// State: Local MXU scheduler, clear FSM, and child unit state.
// Latency: Child-unit dependent.
// Backpressure: cmd_ready is high only when the selected local unit can accept a command.
// Error behavior: Bad target/mask/opcode or child errors are reflected in status.
module tensor_core #(
  parameter int TC_ID = 0,
  parameter int MXUS_PER_TC = 4,
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W = 8,
  parameter int ACC_W = 32,
  parameter int VMEM_BYTES = 262144
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::tc_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,

  input  vtpu_pkg::vmem_req_t dma_req,
  output vtpu_pkg::vmem_resp_t dma_resp,

  output vtpu_pkg::unit_status_t status,
  output vtpu_pkg::unit_status_t mxu_status [MXUS_PER_TC],
  output logic [MXUS_PER_TC-1:0] mxu_busy,
  output logic [MXUS_PER_TC-1:0] mxu_done,
  output logic [MXUS_PER_TC-1:0] mxu_error,
  output logic vector_busy,
  output logic reduce_busy,
  output logic [31:0] vmem_access_count_pulse,
  output logic [31:0] vmem_bank_conflict_count_pulse
);
  typedef enum logic [1:0] {CLEAR_IDLE, CLEAR_RUN, CLEAR_DONE, CLEAR_ERROR} clear_state_t;

  vtpu_pkg::mxu_cmd_t mxu_cmd;
  vtpu_pkg::mxu_cmd_t mxu_cmd_q [MXUS_PER_TC];
  logic mxu_cmd_valid [MXUS_PER_TC];
  logic mxu_cmd_ready [MXUS_PER_TC];
  vtpu_pkg::vmem_req_t mxu_req [MXUS_PER_TC];
  vtpu_pkg::vmem_resp_t mxu_resp [MXUS_PER_TC];

  vtpu_pkg::vector_cmd_t vector_cmd;
  logic vector_valid;
  logic vector_ready;
  vtpu_pkg::unit_status_t vector_status;
  vtpu_pkg::vmem_req_t vector_req;
  vtpu_pkg::vmem_resp_t vector_resp;

  vtpu_pkg::reduce_cmd_t reduce_cmd;
  logic reduce_valid;
  logic reduce_ready;
  vtpu_pkg::unit_status_t reduce_status;
  vtpu_pkg::vmem_req_t reduce_req;
  vtpu_pkg::vmem_resp_t reduce_resp;

  clear_state_t clear_state_q;
  vtpu_pkg::tc_cmd_t clear_cmd_q;
  logic [31:0] clear_offset_q;
  vtpu_pkg::vmem_req_t clear_req;
  vtpu_pkg::vmem_resp_t clear_resp;
  vtpu_pkg::vmem_req_t reduce_port_req;
  vtpu_pkg::vmem_resp_t reduce_port_resp;

  logic [MXUS_PER_TC-1:0] eligible_mask;
  logic [MXUS_PER_TC-1:0] busy_mask;
  logic [MXUS_PER_TC-1:0] error_mask;
  logic [$clog2(MXUS_PER_TC)-1:0] rr_ptr_q;
  logic [$clog2(MXUS_PER_TC)-1:0] chosen_mxu;
  logic chosen_valid;
  logic local_selected;
  logic unsupported_q;
  logic [7:0] unsupported_code_q;
  logic child_busy_comb;
  logic status_done_comb;
  logic status_error_comb;
  integer idx;

  assign local_selected = (cmd.opcode == vtpu_pkg::OPC_CLEAR) ? 1'b1 : cmd.target[4 + TC_ID];
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

  assign busy_mask = mxu_busy;
  assign error_mask = mxu_error;
  assign vector_busy = vector_status.busy;
  assign reduce_busy = reduce_status.busy;

  function automatic logic [MXUS_PER_TC-1:0] mxu_target_mask(input logic [7:0] target);
    logic [MXUS_PER_TC-1:0] mask;
    integer mask_idx;
    begin
      mask = target[MXUS_PER_TC-1:0];
      if (mask == '0) begin
        mask = '1;
      end
      for (mask_idx = 0; mask_idx < MXUS_PER_TC; mask_idx++) begin
        if (mask_idx >= 4) mask[mask_idx] = 1'b0;
      end
      mxu_target_mask = mask;
    end
  endfunction

  function automatic logic any_child_busy;
    logic busy_any;
    integer busy_idx;
    begin
      busy_any = vector_status.busy || reduce_status.busy || (clear_state_q == CLEAR_RUN);
      for (busy_idx = 0; busy_idx < MXUS_PER_TC; busy_idx++) begin
        busy_any = busy_any || mxu_status[busy_idx].busy;
      end
      any_child_busy = busy_any;
    end
  endfunction

  function automatic logic [7:0] first_child_error_code;
    integer err_idx;
    begin
      first_child_error_code = vtpu_pkg::ERR_NONE;
      if (unsupported_q) begin
        first_child_error_code = unsupported_code_q;
      end
      for (err_idx = 0; err_idx < MXUS_PER_TC; err_idx++) begin
        if (mxu_status[err_idx].error && (first_child_error_code == vtpu_pkg::ERR_NONE)) begin
          first_child_error_code = mxu_status[err_idx].error_code;
        end
      end
      if (vector_status.error && (first_child_error_code == vtpu_pkg::ERR_NONE)) begin
        first_child_error_code = vector_status.error_code;
      end
      if (reduce_status.error && (first_child_error_code == vtpu_pkg::ERR_NONE)) begin
        first_child_error_code = reduce_status.error_code;
      end
      if ((clear_state_q == CLEAR_ERROR) && (first_child_error_code == vtpu_pkg::ERR_NONE)) begin
        first_child_error_code = vtpu_pkg::ERR_BAD_ADDR;
      end
    end
  endfunction

  always_comb begin
    eligible_mask = mxu_target_mask(cmd.target) & ~busy_mask;
    chosen_valid = 1'b0;
    chosen_mxu = rr_ptr_q;
    for (idx = 0; idx < MXUS_PER_TC; idx++) begin
      int unsigned probe;
      probe = (int'(rr_ptr_q) + idx) % MXUS_PER_TC;
      if (!chosen_valid && eligible_mask[probe]) begin
        chosen_valid = 1'b1;
        chosen_mxu = probe[$clog2(MXUS_PER_TC)-1:0];
      end
    end

    for (idx = 0; idx < MXUS_PER_TC; idx++) begin
      mxu_cmd_valid[idx] = 1'b0;
      mxu_cmd_q[idx] = mxu_cmd;
    end

    vector_valid = 1'b0;
    reduce_valid = 1'b0;
    cmd_ready = 1'b0;

    if (!local_selected) begin
      cmd_ready = 1'b1;
    end else if (cmd.opcode == vtpu_pkg::OPC_MATMUL) begin
      cmd_ready = chosen_valid && mxu_cmd_ready[chosen_mxu];
      if (cmd_valid && cmd_ready) begin
        mxu_cmd_valid[chosen_mxu] = 1'b1;
      end
    end else if (cmd.opcode == vtpu_pkg::OPC_VECTOR_OP) begin
      cmd_ready = vector_ready && !child_busy_comb;
      vector_valid = cmd_valid && cmd_ready;
    end else if (cmd.opcode == vtpu_pkg::OPC_REDUCE) begin
      cmd_ready = reduce_ready && !child_busy_comb;
      reduce_valid = cmd_valid && cmd_ready;
    end else if (cmd.opcode == vtpu_pkg::OPC_CLEAR) begin
      cmd_ready = (clear_state_q == CLEAR_IDLE) && !child_busy_comb;
    end else begin
      cmd_ready = !child_busy_comb;
    end

    clear_req = '0;
    clear_resp = reduce_port_resp;
    if (clear_state_q == CLEAR_RUN) begin
      clear_req.valid = 1'b1;
      clear_req.write = 1'b1;
      clear_req.addr = {16'd0, clear_cmd_q.dst} + clear_offset_q;
      clear_req.wdata = 32'd0;
      clear_req.wstrb = 4'hF;
    end

    reduce_port_req = (clear_state_q == CLEAR_RUN) ? clear_req : reduce_req;
    reduce_resp = (clear_state_q == CLEAR_RUN) ?
                  '{ready: 1'b0, valid: 1'b0, rdata: 32'd0, error: 1'b0} :
                  reduce_port_resp;
  end
  genvar mxu_g;
  generate
    for (mxu_g = 0; mxu_g < MXUS_PER_TC; mxu_g++) begin : gen_mxus
      mxu_top #(
        .ARRAY_M(ARRAY_M),
        .ARRAY_N(ARRAY_N),
        .ARRAY_K(ARRAY_K),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .VMEM_BYTES(VMEM_BYTES)
      ) u_mxu (
        .clk(clk),
        .rst_n(rst_n),
        .cmd(mxu_cmd_q[mxu_g]),
        .cmd_valid(mxu_cmd_valid[mxu_g]),
        .cmd_ready(mxu_cmd_ready[mxu_g]),
        .vmem_req(mxu_req[mxu_g]),
        .vmem_resp(mxu_resp[mxu_g]),
        .status(mxu_status[mxu_g])
      );
      assign mxu_busy[mxu_g] = mxu_status[mxu_g].busy;
      assign mxu_done[mxu_g] = mxu_status[mxu_g].done;
      assign mxu_error[mxu_g] = mxu_status[mxu_g].error;
    end
  endgenerate

  vector_unit #(
    .LANES(16),
    .VMEM_BYTES(VMEM_BYTES)
  ) u_vector (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(vector_cmd),
    .cmd_valid(vector_valid),
    .cmd_ready(vector_ready),
    .vmem_req(vector_req),
    .vmem_resp(vector_resp),
    .status(vector_status)
  );

  reduce_unit #(
    .LANES(16),
    .VMEM_BYTES(VMEM_BYTES)
  ) u_reduce (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(reduce_cmd),
    .cmd_valid(reduce_valid),
    .cmd_ready(reduce_ready),
    .vmem_req(reduce_req),
    .vmem_resp(reduce_resp),
    .status(reduce_status)
  );

  vmem_top #(
    .VMEM_BYTES(VMEM_BYTES),
    .DATA_W(32),
    .BANKS(vtpu_pkg::VTPU_VMEM_BANKS),
    .MXU_PORTS(MXUS_PER_TC)
  ) u_vmem (
    .clk(clk),
    .rst_n(rst_n),
    .req_dma(dma_req),
    .resp_dma(dma_resp),
    .req_mxu(mxu_req),
    .resp_mxu(mxu_resp),
    .req_vector(vector_req),
    .resp_vector(vector_resp),
    .req_reduce(reduce_port_req),
    .resp_reduce(reduce_port_resp),
    .access_count_pulse(vmem_access_count_pulse),
    .bank_conflict_count_pulse(vmem_bank_conflict_count_pulse)
  );

  function automatic logic clear_range_ok(input vtpu_pkg::tc_cmd_t local_cmd);
    clear_range_ok = (local_cmd.dst[1:0] == 2'b00) &&
                     (local_cmd.imm0[1:0] == 2'b00) &&
                     (({16'd0, local_cmd.dst} + {16'd0, local_cmd.imm0}) <= VMEM_BYTES);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr_ptr_q <= '0;
      clear_state_q <= CLEAR_IDLE;
      clear_cmd_q <= '0;
      clear_offset_q <= 32'd0;
      unsupported_q <= 1'b0;
      unsupported_code_q <= vtpu_pkg::ERR_NONE;
    end else begin
      unsupported_q <= 1'b0;

      if (cmd_valid && local_selected && (cmd.opcode == vtpu_pkg::OPC_MATMUL) && cmd_ready) begin
        rr_ptr_q <= (int'(chosen_mxu) == (MXUS_PER_TC - 1)) ? '0 : (chosen_mxu + 1'b1);
      end

      if (cmd_valid && local_selected && (cmd.opcode == vtpu_pkg::OPC_CLEAR) && cmd_ready) begin
        if (!clear_range_ok(cmd)) begin
          clear_state_q <= CLEAR_ERROR;
        end else begin
          clear_cmd_q <= cmd;
          clear_offset_q <= 32'd0;
          clear_state_q <= (cmd.imm0 == 16'd0) ? CLEAR_DONE : CLEAR_RUN;
        end
      end else begin
        unique case (clear_state_q)
          CLEAR_IDLE: begin
          end
          CLEAR_RUN: begin
            if (reduce_port_resp.valid) begin
              if (reduce_port_resp.error) begin
                clear_state_q <= CLEAR_ERROR;
              end else if ((clear_offset_q + 32'd4) >= {16'd0, clear_cmd_q.imm0}) begin
                clear_state_q <= CLEAR_DONE;
              end else begin
                clear_offset_q <= clear_offset_q + 32'd4;
              end
            end
          end
          CLEAR_DONE: begin
            clear_state_q <= CLEAR_IDLE;
          end
          CLEAR_ERROR: begin
            clear_state_q <= CLEAR_ERROR;
          end
          default: begin
            clear_state_q <= CLEAR_ERROR;
          end
        endcase
      end

      if (cmd_valid && local_selected &&
          (cmd.opcode != vtpu_pkg::OPC_MATMUL) &&
          (cmd.opcode != vtpu_pkg::OPC_VECTOR_OP) &&
          (cmd.opcode != vtpu_pkg::OPC_REDUCE) &&
          (cmd.opcode != vtpu_pkg::OPC_CLEAR) &&
          cmd_ready) begin
        unsupported_q <= 1'b1;
        unsupported_code_q <= vtpu_pkg::ERR_UNSUPPORTED;
      end
    end
  end

  assign child_busy_comb = any_child_busy();
  assign status_done_comb = (clear_state_q == CLEAR_DONE) ||
                            vector_status.done ||
                            reduce_status.done ||
                            (|mxu_done);
  assign status_error_comb = unsupported_q ||
                             (clear_state_q == CLEAR_ERROR) ||
                             vector_status.error ||
                             reduce_status.error ||
                             (|error_mask);
  assign status.busy = child_busy_comb;
  assign status.done = status_done_comb;
  assign status.error = status_error_comb;
  assign status.error_code = status_error_comb ? first_child_error_code() : vtpu_pkg::ERR_NONE;
endmodule
