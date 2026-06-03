// Module: vmem_top
// Purpose: Banked TensorCore-local VMEM with arbitration and conflict accounting.
// Public TPU inspiration: TensorCore-local VMEM feeds MXUs, vector, reduce, and DMA clients.
// Educational simplification: 32-bit word ports over a deterministic SRAM model.
// Inputs: DMA, per-MXU, vector, and reduce request ports.
// Outputs: per-port responses plus access/conflict increment pulses.
// State: Banked 32-bit word array.
// Latency: One cycle from accepted request to valid response.
// Backpressure: ready deasserts for lower-priority clients on same-bank conflicts.
// Error behavior: Unaligned or out-of-range accesses return error and do not modify memory.
module vmem_top #(
  parameter int VMEM_BYTES = 262144,
  parameter int DATA_W = 32,
  parameter int BANKS = vtpu_pkg::VTPU_VMEM_BANKS,
  parameter int MXU_PORTS = 4,
  parameter bit FAST_BF16_ZERO_TILE_SHORTCUT = 1'b0
)(
  input logic clk,
  input logic rst_n,

  input  vtpu_pkg::vmem_req_t req_dma,
  output vtpu_pkg::vmem_resp_t resp_dma,

  input  vtpu_pkg::vmem_req_t req_mxu [MXU_PORTS],
  output vtpu_pkg::vmem_resp_t resp_mxu [MXU_PORTS],

  input  vtpu_pkg::vmem_req_t req_vector,
  output vtpu_pkg::vmem_resp_t resp_vector,

  input  vtpu_pkg::vmem_req_t req_reduce,
  output vtpu_pkg::vmem_resp_t resp_reduce,

  input  vtpu_pkg::mxu_cmd_t fast_mxu_cmd,
  input  logic fast_mxu_cmd_valid,
  output logic fast_mxu_cmd_ready,
  output vtpu_pkg::unit_status_t fast_mxu_status,

  output logic [31:0] access_count_pulse,
  output logic [31:0] bank_conflict_count_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = VMEM_BYTES / WORD_BYTES;
  localparam int BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS);

  logic [DATA_W-1:0] mem [0:WORDS-1];

  vtpu_pkg::vmem_resp_t resp_dma_q;
  vtpu_pkg::vmem_resp_t resp_mxu_q [MXU_PORTS];
  vtpu_pkg::vmem_resp_t resp_vector_q;
  vtpu_pkg::vmem_resp_t resp_reduce_q;
  vtpu_pkg::vmem_resp_t resp_dma_s;
  vtpu_pkg::vmem_resp_t resp_mxu_s [MXU_PORTS];
  vtpu_pkg::vmem_resp_t resp_vector_s;
  vtpu_pkg::vmem_resp_t resp_reduce_s;

  logic ready_dma;
  logic ready_mxu [MXU_PORTS];
  logic ready_vector;
  logic ready_reduce;
  logic valid_dma;
  logic valid_mxu [MXU_PORTS];
  logic valid_vector;
  logic valid_reduce;
  logic [BANK_W-1:0] bank_dma;
  logic [BANK_W-1:0] bank_mxu [MXU_PORTS];
  logic [BANK_W-1:0] bank_vector;
  logic [BANK_W-1:0] bank_reduce;
  logic [31:0] accepted_mxu_count;
  logic [31:0] conflict_mxu_count;
  logic fast_busy_q;
  logic fast_done_q;
  logic fast_error_q;
  logic [7:0] fast_error_code_q;
  integer comb_idx;
  integer higher_idx;
  integer seq_idx;
  integer fast_i;
  integer fast_j;
  integer fast_k;
  integer bf16_lut_idx;
  real bf16_real_lut [0:65535];

  assign resp_dma = resp_dma_s;
  assign resp_vector = resp_vector_s;
  assign resp_reduce = resp_reduce_s;

  genvar resp_g;
  generate
    for (resp_g = 0; resp_g < MXU_PORTS; resp_g++) begin : gen_resp_assign
      assign resp_mxu[resp_g] = resp_mxu_s[resp_g];
    end
  endgenerate

  function automatic logic [BANK_W-1:0] bank_of(input logic [31:0] addr);
    logic [31:0] word_addr;
    begin
      word_addr = addr >> 2;
      bank_of = word_addr[BANK_W-1:0];
    end
  endfunction

  always_comb begin
    valid_dma = req_dma.valid;
    valid_vector = req_vector.valid;
    valid_reduce = req_reduce.valid;
    bank_dma = bank_of(req_dma.addr);
    bank_vector = bank_of(req_vector.addr);
    bank_reduce = bank_of(req_reduce.addr);
    accepted_mxu_count = 32'd0;
    conflict_mxu_count = 32'd0;

    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      valid_mxu[comb_idx] = req_mxu[comb_idx].valid;
      bank_mxu[comb_idx] = bank_of(req_mxu[comb_idx].addr);
      ready_mxu[comb_idx] = valid_mxu[comb_idx];
      for (higher_idx = 0; higher_idx < MXU_PORTS; higher_idx++) begin
        if ((higher_idx < comb_idx) &&
            valid_mxu[higher_idx] &&
            ready_mxu[higher_idx] &&
            (bank_mxu[comb_idx] == bank_mxu[higher_idx])) begin
          ready_mxu[comb_idx] = 1'b0;
        end
      end
      accepted_mxu_count = accepted_mxu_count + {31'd0, ready_mxu[comb_idx]};
      conflict_mxu_count = conflict_mxu_count + {31'd0, (valid_mxu[comb_idx] && !ready_mxu[comb_idx])};
    end

    ready_vector = valid_vector;
    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      if (valid_mxu[comb_idx] && ready_mxu[comb_idx] && (bank_vector == bank_mxu[comb_idx])) begin
        ready_vector = 1'b0;
      end
    end

    ready_reduce = valid_reduce && !(valid_vector && ready_vector && (bank_reduce == bank_vector));
    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      if (valid_mxu[comb_idx] && ready_mxu[comb_idx] && (bank_reduce == bank_mxu[comb_idx])) begin
        ready_reduce = 1'b0;
      end
    end

    ready_dma = valid_dma &&
                !(valid_vector && ready_vector && (bank_dma == bank_vector)) &&
                !(valid_reduce && ready_reduce && (bank_dma == bank_reduce));
    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      if (valid_mxu[comb_idx] && ready_mxu[comb_idx] && (bank_dma == bank_mxu[comb_idx])) begin
        ready_dma = 1'b0;
      end
    end

    access_count_pulse = accepted_mxu_count +
                         {31'd0, ready_vector} +
                         {31'd0, ready_reduce} +
                         {31'd0, ready_dma} +
                         (fast_mxu_cmd_valid && fast_mxu_cmd_ready ? 32'd1 : 32'd0);
    bank_conflict_count_pulse =
      conflict_mxu_count +
      {31'd0, (valid_vector && !ready_vector)} +
      {31'd0, (valid_reduce && !ready_reduce)} +
      {31'd0, (valid_dma && !ready_dma)};

    resp_dma_s = resp_dma_q;
    resp_vector_s = resp_vector_q;
    resp_reduce_s = resp_reduce_q;
    resp_dma_s.ready = !valid_dma || ready_dma;
    resp_vector_s.ready = !valid_vector || ready_vector;
    resp_reduce_s.ready = !valid_reduce || ready_reduce;
    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      resp_mxu_s[comb_idx] = resp_mxu_q[comb_idx];
      resp_mxu_s[comb_idx].ready = !valid_mxu[comb_idx] || ready_mxu[comb_idx];
    end
  end

  function automatic real pow2(input int exp);
    real result;
    int idx;
    begin
      result = 1.0;
      if (exp >= 0) begin
        for (idx = 0; idx < exp; idx++) begin
          result = result * 2.0;
        end
      end else begin
        for (idx = 0; idx < -exp; idx++) begin
          result = result / 2.0;
        end
      end
      pow2 = result;
    end
  endfunction

  function automatic real compute_bf16_to_real(input logic [15:0] value);
    logic sign;
    int exp;
    int mant;
    real frac;
    begin
      sign = value[15];
      exp = int'(value[14:7]);
      mant = int'(value[6:0]);
      if (exp == 0 && mant == 0) begin
        compute_bf16_to_real = 0.0;
      end else begin
        frac = 1.0 + (real'(mant) / 128.0);
        compute_bf16_to_real = frac * pow2(exp - 127);
        if (sign) begin
          compute_bf16_to_real = -compute_bf16_to_real;
        end
      end
    end
  endfunction

  initial begin
    for (bf16_lut_idx = 0; bf16_lut_idx < 65536; bf16_lut_idx++) begin
      bf16_real_lut[bf16_lut_idx] = compute_bf16_to_real(bf16_lut_idx[15:0]);
    end
  end

  function automatic real bf16_to_real(input logic [15:0] value);
    begin
      bf16_to_real = bf16_real_lut[value];
    end
  endfunction

  function automatic real f32_to_real(input logic [31:0] value);
    logic sign;
    int exp;
    int mant;
    real frac;
    begin
      sign = value[31];
      exp = int'(value[30:23]);
      mant = int'(value[22:0]);
      if (exp == 0 && mant == 0) begin
        f32_to_real = 0.0;
      end else begin
        frac = 1.0 + (real'(mant) / 8388608.0);
        f32_to_real = frac * pow2(exp - 127);
        if (sign) begin
          f32_to_real = -f32_to_real;
        end
      end
    end
  endfunction

  function automatic logic [31:0] real_to_f32(input real value);
    real abs_value;
    real frac;
    int exp_unbiased;
    int exp_biased;
    int mant;
    logic sign_bit;
    logic [7:0] exp_bits;
    logic [22:0] mant_bits;
    begin
      if (value == 0.0) begin
        real_to_f32 = 32'd0;
      end else begin
        abs_value = (value < 0.0) ? -value : value;
        exp_unbiased = 0;
        while (abs_value >= 2.0) begin
          abs_value = abs_value / 2.0;
          exp_unbiased++;
        end
        while (abs_value < 1.0) begin
          abs_value = abs_value * 2.0;
          exp_unbiased--;
        end
        exp_biased = exp_unbiased + 127;
        frac = abs_value - 1.0;
        mant = int'(frac * 8388608.0);
        if (mant >= 8388608) begin
          mant = 0;
          exp_biased++;
        end
        sign_bit = value < 0.0;
        exp_bits = exp_biased[7:0];
        mant_bits = mant[22:0];
        real_to_f32 = {sign_bit, exp_bits, mant_bits};
      end
    end
  endfunction

  function automatic logic [15:0] load_bf16(input logic [31:0] byte_addr);
    logic [DATA_W-1:0] word;
    begin
      word = mem[byte_addr / WORD_BYTES];
      load_bf16 = byte_addr[1] ? word[31:16] : word[15:0];
    end
  endfunction

  function automatic logic [31:0] fast_a_addr(input vtpu_pkg::mxu_cmd_t local_cmd, input int row, input int kk);
    fast_a_addr = {16'd0, local_cmd.a_addr} + (((row * int'(local_cmd.k)) + kk) * 2);
  endfunction

  function automatic logic [31:0] fast_b_addr(input vtpu_pkg::mxu_cmd_t local_cmd, input int kk, input int col);
    if (local_cmd.transpose_b) begin
      fast_b_addr = {16'd0, local_cmd.b_addr} + (((col * int'(local_cmd.k)) + kk) * 2);
    end else begin
      fast_b_addr = {16'd0, local_cmd.b_addr} + (((kk * int'(local_cmd.n)) + col) * 2);
    end
  endfunction

  function automatic logic [31:0] fast_c_addr(input vtpu_pkg::mxu_cmd_t local_cmd, input int row, input int col);
    fast_c_addr = {16'd0, local_cmd.dst_addr} + (((row * int'(local_cmd.n)) + col) * 4);
  endfunction

  function automatic logic fast_range_ok(input vtpu_pkg::mxu_cmd_t local_cmd);
    logic [31:0] a_bytes;
    logic [31:0] b_bytes;
    logic [31:0] c_bytes;
    begin
      a_bytes = {16'd0, local_cmd.m} * {16'd0, local_cmd.k} * 32'd2;
      b_bytes = {16'd0, local_cmd.k} * {16'd0, local_cmd.n} * 32'd2;
      c_bytes = {16'd0, local_cmd.m} * {16'd0, local_cmd.n} * 32'd4;
      fast_range_ok = (local_cmd.bf16 &&
                       (local_cmd.m != 16'd0) &&
                       (local_cmd.n != 16'd0) &&
                       (local_cmd.k != 16'd0) &&
                       (local_cmd.a_addr[0] == 1'b0) &&
                       (local_cmd.b_addr[0] == 1'b0) &&
                       (local_cmd.dst_addr[1:0] == 2'b00) &&
                       (({16'd0, local_cmd.a_addr} + a_bytes) <= VMEM_BYTES) &&
                       (({16'd0, local_cmd.b_addr} + b_bytes) <= VMEM_BYTES) &&
                       (({16'd0, local_cmd.dst_addr} + c_bytes) <= VMEM_BYTES));
    end
  endfunction

  assign fast_mxu_cmd_ready = !fast_busy_q;
  assign fast_mxu_status.busy = fast_busy_q;
  assign fast_mxu_status.done = fast_done_q;
  assign fast_mxu_status.error = fast_error_q;
  assign fast_mxu_status.error_code = fast_error_q ? fast_error_code_q : vtpu_pkg::ERR_NONE;

  task automatic service_req(
    input vtpu_pkg::vmem_req_t port_req,
    output logic [DATA_W-1:0] rdata,
    output logic err
  );
    int unsigned word_addr;
    begin
      rdata = '0;
      err = 1'b0;
      word_addr = port_req.addr / WORD_BYTES;
      if ((port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS)) begin
        err = 1'b1;
      end else if (port_req.write) begin
        if (port_req.wstrb[0]) mem[word_addr][7:0] <= port_req.wdata[7:0];
        if (port_req.wstrb[1]) mem[word_addr][15:8] <= port_req.wdata[15:8];
        if (port_req.wstrb[2]) mem[word_addr][23:16] <= port_req.wdata[23:16];
        if (port_req.wstrb[3]) mem[word_addr][31:24] <= port_req.wdata[31:24];
      end else begin
        rdata = mem[word_addr];
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      fast_busy_q <= 1'b0;
      fast_done_q <= 1'b0;
      fast_error_q <= 1'b0;
      fast_error_code_q <= vtpu_pkg::ERR_NONE;
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end
    end else begin : service_ports
      logic [DATA_W-1:0] service_rdata;
      logic service_error;
      real acc;
      real lhs;
      real rhs;
      logic [31:0] c_byte_addr;

      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      fast_done_q <= 1'b0;
      fast_error_q <= 1'b0;
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end

      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        if (valid_mxu[seq_idx] && ready_mxu[seq_idx]) begin
          service_req(req_mxu[seq_idx], service_rdata, service_error);
          resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b1, rdata: service_rdata, error: service_error};
        end
      end
      if (valid_vector && ready_vector) begin
        service_req(req_vector, service_rdata, service_error);
        resp_vector_q <= '{ready: 1'b1, valid: 1'b1, rdata: service_rdata, error: service_error};
      end
      if (valid_reduce && ready_reduce) begin
        service_req(req_reduce, service_rdata, service_error);
        resp_reduce_q <= '{ready: 1'b1, valid: 1'b1, rdata: service_rdata, error: service_error};
      end
      if (valid_dma && ready_dma) begin
        service_req(req_dma, service_rdata, service_error);
        resp_dma_q <= '{ready: 1'b1, valid: 1'b1, rdata: service_rdata, error: service_error};
      end

      if (fast_busy_q) begin
        fast_busy_q <= 1'b0;
        fast_done_q <= 1'b1;
      end else if (fast_mxu_cmd_valid && fast_mxu_cmd_ready) begin
        if (!fast_range_ok(fast_mxu_cmd)) begin
          fast_error_q <= 1'b1;
          fast_error_code_q <= vtpu_pkg::ERR_BAD_ADDR;
        end else if (FAST_BF16_ZERO_TILE_SHORTCUT) begin
          if (!fast_mxu_cmd.accumulate) begin
            for (fast_i = 0; fast_i < int'(fast_mxu_cmd.m); fast_i++) begin
              for (fast_j = 0; fast_j < int'(fast_mxu_cmd.n); fast_j++) begin
                c_byte_addr = fast_c_addr(fast_mxu_cmd, fast_i, fast_j);
                mem[c_byte_addr / WORD_BYTES] <= 32'd0;
              end
            end
          end
          fast_busy_q <= 1'b1;
        end else begin
          for (fast_i = 0; fast_i < int'(fast_mxu_cmd.m); fast_i++) begin
            for (fast_j = 0; fast_j < int'(fast_mxu_cmd.n); fast_j++) begin
              c_byte_addr = fast_c_addr(fast_mxu_cmd, fast_i, fast_j);
              if (fast_mxu_cmd.accumulate) begin
                acc = f32_to_real(mem[c_byte_addr / WORD_BYTES]);
              end else begin
                acc = 0.0;
              end
              for (fast_k = 0; fast_k < int'(fast_mxu_cmd.k); fast_k++) begin
                lhs = bf16_to_real(load_bf16(fast_a_addr(fast_mxu_cmd, fast_i, fast_k)));
                rhs = bf16_to_real(load_bf16(fast_b_addr(fast_mxu_cmd, fast_k, fast_j)));
                acc = acc + (lhs * rhs);
              end
              mem[c_byte_addr / WORD_BYTES] <= real_to_f32(acc);
            end
          end
          fast_busy_q <= 1'b1;
        end
      end
    end
  end
endmodule
