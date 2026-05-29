// Module: virtual_tpu_v4_top
// Purpose: Structural educational TPU v4-inspired chip shell for int8/int32 programs.
// Public TPU inspiration: Host-loaded instruction streams drive DMA, local VMEM, MXU, vector, and reduce units.
// Educational simplification: Deterministic SRAM/HBM models and in-order control; BF16 is rejected in RTL.
// Inputs: clock/reset and 32-bit host/MMIO request channel.
// Outputs: host response plus done/busy/error status.
// Structure: instr_mem + decoder + control_fsm + DMA + HBM + CMEM + two TensorCores.
// Errors: malformed instructions, bad spaces, bad targets, unaligned accesses, out-of-bounds accesses, and BF16 enter ERROR.
// Tests: Chip-level cocotb compares HBM-visible results and MMIO counters to Python expectations.
module virtual_tpu_v4_top #(
  parameter int NUM_TENSOR_CORES = 2,
  parameter int MXUS_PER_TC = 4,
  parameter int ARRAY_M = 16,
  parameter int ARRAY_N = 16,
  parameter int ARRAY_K = 16,
  parameter int DATA_W = 8,
  parameter int ACC_W = 32,
  parameter int VMEM_BYTES = 262144,
  parameter int CMEM_BYTES = 524288,
  parameter int HBM_BYTES = 1048576,
  parameter int INSTR_DEPTH = 1024,
  parameter bit PHYSICAL_MEMORIES = 1'b0
)(
  input logic clk,
  input logic rst_n,

  input  vtpu_pkg::host_req_t  host_req,
  input  logic                 host_req_valid,
  output logic                 host_req_ready,
  output vtpu_pkg::host_resp_t host_resp,
  output logic                 host_resp_valid,

  output logic done,
  output logic busy,
  output logic error
);
  localparam logic [31:0] REG_CONTROL = vtpu_pkg::VTPU_REG_CONTROL;
  localparam logic [31:0] REG_STATUS = vtpu_pkg::VTPU_REG_STATUS;
  localparam logic [31:0] REG_ERROR_CODE = vtpu_pkg::VTPU_REG_ERROR_CODE;
  localparam logic [31:0] REG_PC = vtpu_pkg::VTPU_REG_PC;
  localparam logic [31:0] COUNTER_BASE = vtpu_pkg::VTPU_COUNTER_BASE;
  localparam logic [31:0] INSTR_BASE = vtpu_pkg::VTPU_INSTR_BASE;
  localparam logic [31:0] INSTR_BYTES = INSTR_DEPTH * 16;
  localparam logic [31:0] HBM_BASE = vtpu_pkg::VTPU_HBM_BASE;
  localparam logic [31:0] HBM_LIMIT = HBM_BASE + HBM_BYTES;
  localparam int INSTR_ADDR_W = $clog2(INSTR_DEPTH);
  localparam int COUNTER_ADDR_W = $clog2(vtpu_pkg::VTPU_NUM_COUNTERS);

  vtpu_pkg::host_resp_t host_resp_q;
  logic start_pulse_q;
  logic counter_clear_q;

  logic instr_fetch_en;
  logic [15:0] pc;
  logic [127:0] instr_raw;
  logic [31:0] instr_host_rdata;
  logic instr_fetch_error;
  logic instr_host_we;
  logic [INSTR_ADDR_W-1:0] instr_host_addr;
  logic [1:0] instr_host_lane;

  vtpu_pkg::decoded_instr_t decoded;
  logic decode_illegal;
  logic [7:0] decode_error_code;

  vtpu_pkg::dma_cmd_t dma_cmd;
  logic dma_cmd_valid;
  logic dma_cmd_ready;
  vtpu_pkg::unit_status_t dma_status;
  vtpu_pkg::mem_req_t hbm_req;
  vtpu_pkg::mem_resp_t hbm_resp;
  vtpu_pkg::vmem_req_t cmem_dma_req;
  vtpu_pkg::vmem_resp_t cmem_dma_resp;
  vtpu_pkg::vmem_req_t vmem0_dma_req;
  vtpu_pkg::vmem_resp_t vmem0_dma_resp;
  vtpu_pkg::vmem_req_t vmem1_dma_req;
  vtpu_pkg::vmem_resp_t vmem1_dma_resp;
  logic [31:0] dma_bytes_moved_pulse;

  vtpu_pkg::tc_cmd_t tc_cmd [NUM_TENSOR_CORES];
  logic tc_cmd_valid [NUM_TENSOR_CORES];
  logic tc_cmd_ready [NUM_TENSOR_CORES];
  vtpu_pkg::unit_status_t tc_status [NUM_TENSOR_CORES];

  vtpu_pkg::unit_status_t tc0_mxu_status [MXUS_PER_TC];
  vtpu_pkg::unit_status_t tc1_mxu_status [MXUS_PER_TC];
  logic [MXUS_PER_TC-1:0] tc0_mxu_busy;
  logic [MXUS_PER_TC-1:0] tc0_mxu_done;
  logic [MXUS_PER_TC-1:0] tc0_mxu_error;
  logic [MXUS_PER_TC-1:0] tc1_mxu_busy;
  logic [MXUS_PER_TC-1:0] tc1_mxu_done;
  logic [MXUS_PER_TC-1:0] tc1_mxu_error;
  logic tc0_vector_busy;
  logic tc0_reduce_busy;
  logic tc1_vector_busy;
  logic tc1_reduce_busy;
  logic [31:0] tc0_vmem_access_pulse;
  logic [31:0] tc0_vmem_conflict_pulse;
  logic [31:0] tc1_vmem_access_pulse;
  logic [31:0] tc1_vmem_conflict_pulse;

  vtpu_pkg::vmem_req_t cmem_tc0_req;
  vtpu_pkg::vmem_resp_t cmem_tc0_resp;
  vtpu_pkg::vmem_req_t cmem_tc1_req;
  vtpu_pkg::vmem_resp_t cmem_tc1_resp;
  logic [31:0] cmem_access_pulse;
  logic [31:0] cmem_conflict_pulse;

  logic hbm_host_we;
  logic [31:0] hbm_host_addr;
  logic [31:0] hbm_host_rdata;
  logic hbm_access_pulse;
  logic hbm_stall_pulse;

  logic instr_retired;
  logic barrier_wait;
  logic control_error_pulse;
  logic control_done;
  logic control_busy;
  logic control_error;
  logic [7:0] control_error_code;

  logic [63:0] counter_inc [0:vtpu_pkg::VTPU_NUM_COUNTERS-1];
  logic [COUNTER_ADDR_W-1:0] counter_read_index;
  logic [63:0] counter_read_value;

  logic [31:0] host_offset;
  logic [31:0] counter_offset;
  logic host_aligned;
  logic control_addr_hit;
  logic status_addr_hit;
  logic error_addr_hit;
  logic pc_addr_hit;
  logic counter_addr_hit;
  logic instr_addr_hit;
  logic hbm_addr_hit;
  logic hbm_word_in_range;
  logic chip_units_busy;
  logic chip_units_error;

  integer inc_idx;

  function automatic logic mxu_busy_at(input logic [MXUS_PER_TC-1:0] mask, input int unsigned index);
    begin
      mxu_busy_at = (index < MXUS_PER_TC) ? mask[index] : 1'b0;
    end
  endfunction

  assign host_req_ready = 1'b1;
  assign host_resp = host_resp_q;
  assign host_resp_valid = host_resp_q.valid;
  assign done = control_done;
  assign busy = control_busy || dma_status.busy || tc_status[0].busy || tc_status[1].busy;
  assign error = control_error || dma_status.error || tc_status[0].error || tc_status[1].error;
  assign chip_units_busy = busy;
  assign chip_units_error = error;

  assign host_aligned = (host_req.addr[1:0] == 2'b00);
  assign control_addr_hit = (host_req.addr == REG_CONTROL);
  assign status_addr_hit = (host_req.addr == REG_STATUS);
  assign error_addr_hit = (host_req.addr == REG_ERROR_CODE);
  assign pc_addr_hit = (host_req.addr == REG_PC);
  assign counter_addr_hit = (host_req.addr >= COUNTER_BASE) &&
                            (host_req.addr < (COUNTER_BASE + (vtpu_pkg::VTPU_NUM_COUNTERS * 8)));
  assign instr_addr_hit = (host_req.addr >= INSTR_BASE) &&
                          (host_req.addr < (INSTR_BASE + INSTR_BYTES));
  assign hbm_addr_hit = (host_req.addr >= HBM_BASE) && (host_req.addr < HBM_LIMIT);

  always_comb begin
    host_offset = 32'd0;
    counter_offset = 32'd0;
    instr_host_addr = '0;
    instr_host_lane = 2'd0;
    hbm_host_addr = 32'd0;
    counter_read_index = '0;
    hbm_word_in_range = 1'b0;

    if (instr_addr_hit) begin
      host_offset = host_req.addr - INSTR_BASE;
      instr_host_addr = host_offset[INSTR_ADDR_W+3:4];
      instr_host_lane = host_offset[3:2];
    end else if (hbm_addr_hit) begin
      host_offset = host_req.addr - HBM_BASE;
      hbm_host_addr = host_offset;
      hbm_word_in_range = ((host_offset + 32'd3) < HBM_BYTES);
    end else if (counter_addr_hit) begin
      counter_offset = host_req.addr - COUNTER_BASE;
      counter_read_index = counter_offset[COUNTER_ADDR_W+2:3];
    end
  end

  assign instr_host_we = host_req_valid && host_req.write && host_aligned && instr_addr_hit && !chip_units_busy;
  assign hbm_host_we = host_req_valid && host_req.write && host_aligned && hbm_addr_hit && hbm_word_in_range && !chip_units_busy;

  generate
    if (PHYSICAL_MEMORIES) begin : gen_physical_instr_mem
      instr_mem_physical #(
        .DEPTH(INSTR_DEPTH)
      ) u_instr_mem (
        .clk(clk),
        .rst_n(rst_n),
        .host_we(instr_host_we),
        .host_addr(instr_host_addr),
        .host_lane(instr_host_lane),
        .host_wdata(host_req.wdata),
        .host_rdata(instr_host_rdata),
        .fetch_en(instr_fetch_en),
        .fetch_pc(pc[INSTR_ADDR_W-1:0]),
        .instr(instr_raw),
        .fetch_error(instr_fetch_error)
      );
    end else begin : gen_behavioral_instr_mem
      instr_mem #(
        .DEPTH(INSTR_DEPTH)
      ) u_instr_mem (
        .clk(clk),
        .rst_n(rst_n),
        .host_we(instr_host_we),
        .host_addr(instr_host_addr),
        .host_lane(instr_host_lane),
        .host_wdata(host_req.wdata),
        .host_rdata(instr_host_rdata),
        .fetch_en(instr_fetch_en),
        .fetch_pc(pc[INSTR_ADDR_W-1:0]),
        .instr(instr_raw),
        .fetch_error(instr_fetch_error)
      );
    end
  endgenerate

  instr_decoder u_instr_decoder (
    .instr_raw(instr_raw),
    .decoded(decoded),
    .illegal(decode_illegal),
    .error_code(decode_error_code)
  );

  control_fsm #(
    .NUM_TENSOR_CORES(NUM_TENSOR_CORES)
  ) u_control (
    .clk(clk),
    .rst_n(rst_n),
    .start(start_pulse_q),
    .instr_fetch_en(instr_fetch_en),
    .pc(pc),
    .decoded(decoded),
    .illegal(decode_illegal || instr_fetch_error),
    .decode_error_code(instr_fetch_error ? vtpu_pkg::ERR_BAD_ADDR : decode_error_code),
    .dma_cmd(dma_cmd),
    .dma_cmd_valid(dma_cmd_valid),
    .dma_cmd_ready(dma_cmd_ready),
    .dma_status(dma_status),
    .tc_cmd(tc_cmd),
    .tc_cmd_valid(tc_cmd_valid),
    .tc_cmd_ready(tc_cmd_ready),
    .tc_status(tc_status),
    .instr_retired(instr_retired),
    .barrier_wait(barrier_wait),
    .error_pulse(control_error_pulse),
    .done(control_done),
    .busy(control_busy),
    .error(control_error),
    .error_code(control_error_code)
  );

  dma_engine #(
    .HBM_BYTES(HBM_BYTES),
    .CMEM_BYTES(CMEM_BYTES),
    .VMEM_BYTES(VMEM_BYTES)
  ) u_dma (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(dma_cmd),
    .cmd_valid(dma_cmd_valid),
    .cmd_ready(dma_cmd_ready),
    .status(dma_status),
    .hbm_req(hbm_req),
    .hbm_resp(hbm_resp),
    .cmem_req(cmem_dma_req),
    .cmem_resp(cmem_dma_resp),
    .vmem0_req(vmem0_dma_req),
    .vmem0_resp(vmem0_dma_resp),
    .vmem1_req(vmem1_dma_req),
    .vmem1_resp(vmem1_dma_resp),
    .bytes_moved_pulse(dma_bytes_moved_pulse)
  );

  generate
    if (PHYSICAL_MEMORIES) begin : gen_physical_hbm
      hbm_model_physical #(
        .HBM_BYTES(HBM_BYTES),
        .DATA_W(32),
        .READ_LATENCY(1),
        .WRITE_LATENCY(1)
      ) u_hbm (
        .clk(clk),
        .rst_n(rst_n),
        .req(hbm_req),
        .resp(hbm_resp),
        .host_we(hbm_host_we),
        .host_addr(hbm_host_addr),
        .host_wdata(host_req.wdata),
        .host_wstrb(4'hF),
        .host_rdata(hbm_host_rdata),
        .access_pulse(hbm_access_pulse),
        .stall_pulse(hbm_stall_pulse)
      );
    end else begin : gen_behavioral_hbm
      hbm_model #(
        .HBM_BYTES(HBM_BYTES),
        .DATA_W(32),
        .READ_LATENCY(1),
        .WRITE_LATENCY(1)
      ) u_hbm (
        .clk(clk),
        .rst_n(rst_n),
        .req(hbm_req),
        .resp(hbm_resp),
        .host_we(hbm_host_we),
        .host_addr(hbm_host_addr),
        .host_wdata(host_req.wdata),
        .host_wstrb(4'hF),
        .host_rdata(hbm_host_rdata),
        .access_pulse(hbm_access_pulse),
        .stall_pulse(hbm_stall_pulse)
      );
    end
  endgenerate

  assign cmem_tc0_req = '0;
  assign cmem_tc1_req = '0;

  generate
    if (PHYSICAL_MEMORIES) begin : gen_physical_cmem
      cmem_top_physical #(
        .CMEM_BYTES(CMEM_BYTES),
        .DATA_W(32),
        .BANKS(vtpu_pkg::VTPU_VMEM_BANKS)
      ) u_cmem (
        .clk(clk),
        .rst_n(rst_n),
        .req_dma(cmem_dma_req),
        .resp_dma(cmem_dma_resp),
        .req_tc0(cmem_tc0_req),
        .resp_tc0(cmem_tc0_resp),
        .req_tc1(cmem_tc1_req),
        .resp_tc1(cmem_tc1_resp),
        .access_count_pulse(cmem_access_pulse),
        .bank_conflict_count_pulse(cmem_conflict_pulse)
      );
    end else begin : gen_behavioral_cmem
      cmem_top #(
        .CMEM_BYTES(CMEM_BYTES),
        .DATA_W(32),
        .BANKS(vtpu_pkg::VTPU_VMEM_BANKS)
      ) u_cmem (
        .clk(clk),
        .rst_n(rst_n),
        .req_dma(cmem_dma_req),
        .resp_dma(cmem_dma_resp),
        .req_tc0(cmem_tc0_req),
        .resp_tc0(cmem_tc0_resp),
        .req_tc1(cmem_tc1_req),
        .resp_tc1(cmem_tc1_resp),
        .access_count_pulse(cmem_access_pulse),
        .bank_conflict_count_pulse(cmem_conflict_pulse)
      );
    end
  endgenerate

  tensor_core #(
    .TC_ID(0),
    .MXUS_PER_TC(MXUS_PER_TC),
    .ARRAY_M(ARRAY_M),
    .ARRAY_N(ARRAY_N),
    .ARRAY_K(ARRAY_K),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .VMEM_BYTES(VMEM_BYTES),
    .PHYSICAL_MEMORIES(PHYSICAL_MEMORIES)
  ) u_tensor_core0 (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(tc_cmd[0]),
    .cmd_valid(tc_cmd_valid[0]),
    .cmd_ready(tc_cmd_ready[0]),
    .dma_req(vmem0_dma_req),
    .dma_resp(vmem0_dma_resp),
    .status(tc_status[0]),
    .mxu_status(tc0_mxu_status),
    .mxu_busy(tc0_mxu_busy),
    .mxu_done(tc0_mxu_done),
    .mxu_error(tc0_mxu_error),
    .vector_busy(tc0_vector_busy),
    .reduce_busy(tc0_reduce_busy),
    .vmem_access_count_pulse(tc0_vmem_access_pulse),
    .vmem_bank_conflict_count_pulse(tc0_vmem_conflict_pulse)
  );

  tensor_core #(
    .TC_ID(1),
    .MXUS_PER_TC(MXUS_PER_TC),
    .ARRAY_M(ARRAY_M),
    .ARRAY_N(ARRAY_N),
    .ARRAY_K(ARRAY_K),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .VMEM_BYTES(VMEM_BYTES),
    .PHYSICAL_MEMORIES(PHYSICAL_MEMORIES)
  ) u_tensor_core1 (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(tc_cmd[1]),
    .cmd_valid(tc_cmd_valid[1]),
    .cmd_ready(tc_cmd_ready[1]),
    .dma_req(vmem1_dma_req),
    .dma_resp(vmem1_dma_resp),
    .status(tc_status[1]),
    .mxu_status(tc1_mxu_status),
    .mxu_busy(tc1_mxu_busy),
    .mxu_done(tc1_mxu_done),
    .mxu_error(tc1_mxu_error),
    .vector_busy(tc1_vector_busy),
    .reduce_busy(tc1_reduce_busy),
    .vmem_access_count_pulse(tc1_vmem_access_pulse),
    .vmem_bank_conflict_count_pulse(tc1_vmem_conflict_pulse)
  );

  always_comb begin
    for (inc_idx = 0; inc_idx < vtpu_pkg::VTPU_NUM_COUNTERS; inc_idx++) begin
      counter_inc[inc_idx] = 64'd0;
    end
    counter_inc[vtpu_pkg::VTPU_COUNTER_CYCLES] = 64'd1;
    counter_inc[vtpu_pkg::VTPU_COUNTER_INSTRUCTIONS] = {63'd0, instr_retired};
    counter_inc[vtpu_pkg::VTPU_COUNTER_DMA_BYTES] = {32'd0, dma_bytes_moved_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_DMA_ACTIVE] = {63'd0, dma_status.busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_HBM_STALL] = {63'd0, hbm_stall_pulse | hbm_access_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_CMEM_ACCESSES] = {32'd0, cmem_access_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_VMEM_ACCESSES] = {32'd0, tc0_vmem_access_pulse + tc1_vmem_access_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_VMEM_BANK_CONFLICTS] = {32'd0, tc0_vmem_conflict_pulse + tc1_vmem_conflict_pulse + cmem_conflict_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_MXU_ACTIVE] = {63'd0, (|tc0_mxu_busy) | (|tc1_mxu_busy)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_VECTOR_ACTIVE] = {63'd0, tc0_vector_busy | tc1_vector_busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_REDUCE_ACTIVE] = {63'd0, tc0_reduce_busy | tc1_reduce_busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_BARRIER_WAIT] = {63'd0, barrier_wait};
    counter_inc[vtpu_pkg::VTPU_COUNTER_ERRORS] = {63'd0, control_error_pulse};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC0_ACTIVE] = {63'd0, tc_status[0].busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC1_ACTIVE] = {63'd0, tc_status[1].busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC0_MXU0_ACTIVE] = {63'd0, mxu_busy_at(tc0_mxu_busy, 0)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC0_MXU1_ACTIVE] = {63'd0, mxu_busy_at(tc0_mxu_busy, 1)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC0_MXU2_ACTIVE] = {63'd0, mxu_busy_at(tc0_mxu_busy, 2)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC0_MXU3_ACTIVE] = {63'd0, mxu_busy_at(tc0_mxu_busy, 3)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC1_MXU0_ACTIVE] = {63'd0, mxu_busy_at(tc1_mxu_busy, 0)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC1_MXU1_ACTIVE] = {63'd0, mxu_busy_at(tc1_mxu_busy, 1)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC1_MXU2_ACTIVE] = {63'd0, mxu_busy_at(tc1_mxu_busy, 2)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_TC1_MXU3_ACTIVE] = {63'd0, mxu_busy_at(tc1_mxu_busy, 3)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_DMA_IDLE] = {63'd0, control_busy && !dma_status.busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_MXU_IDLE] = {63'd0, control_busy && !(|tc0_mxu_busy) && !(|tc1_mxu_busy)};
    counter_inc[vtpu_pkg::VTPU_COUNTER_VECTOR_IDLE] = {63'd0, control_busy && !tc0_vector_busy && !tc1_vector_busy};
    counter_inc[vtpu_pkg::VTPU_COUNTER_REDUCE_IDLE] = {63'd0, control_busy && !tc0_reduce_busy && !tc1_reduce_busy};
  end

  perf_counters #(
    .NUM_COUNTERS(vtpu_pkg::VTPU_NUM_COUNTERS)
  ) u_perf_counters (
    .clk(clk),
    .rst_n(rst_n),
    .clear(counter_clear_q),
    .inc(counter_inc),
    .read_index(counter_read_index),
    .read_value(counter_read_value)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_resp_q <= '{valid: 1'b0, rdata: '0, error: 1'b0};
      start_pulse_q <= 1'b0;
      counter_clear_q <= 1'b0;
    end else begin
      host_resp_q <= '{valid: 1'b0, rdata: '0, error: 1'b0};
      start_pulse_q <= 1'b0;
      counter_clear_q <= 1'b0;

      if (host_req_valid) begin
        host_resp_q.valid <= 1'b1;
        if (!host_aligned) begin
          host_resp_q.error <= 1'b1;
        end else if (control_addr_hit) begin
          if (host_req.write && host_req.wdata[1]) begin
            counter_clear_q <= 1'b1;
          end
          if (host_req.write && host_req.wdata[0]) begin
            if (chip_units_busy) begin
              host_resp_q.error <= 1'b1;
            end else begin
              start_pulse_q <= 1'b1;
            end
          end
          host_resp_q.rdata <= {30'd0, chip_units_error, chip_units_busy};
        end else if (status_addr_hit) begin
          host_resp_q.rdata <= {29'd0, chip_units_error, chip_units_busy, done};
        end else if (error_addr_hit) begin
          host_resp_q.rdata <= {24'd0, control_error_code};
        end else if (pc_addr_hit) begin
          host_resp_q.rdata <= {16'd0, pc};
        end else if (counter_addr_hit) begin
          host_resp_q.rdata <= counter_offset[2] ? counter_read_value[63:32] : counter_read_value[31:0];
          if (host_req.write) host_resp_q.error <= 1'b1;
        end else if (instr_addr_hit) begin
          if (host_req.write) begin
            if (chip_units_busy) host_resp_q.error <= 1'b1;
          end else begin
            host_resp_q.rdata <= instr_host_rdata;
          end
        end else if (hbm_addr_hit) begin
          if (!hbm_word_in_range) begin
            host_resp_q.error <= 1'b1;
          end else if (host_req.write) begin
            if (chip_units_busy) host_resp_q.error <= 1'b1;
          end else begin
            host_resp_q.rdata <= hbm_host_rdata;
          end
        end else begin
          host_resp_q.error <= 1'b1;
        end
      end
    end
  end
endmodule
