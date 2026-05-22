/* verilator lint_off DECLFILENAME */
// Module set: physical memory shells
// Purpose: Physical-design-safe replacements for behavioral arrays.
// Notes: These modules preserve request/response timing and address checks, but
//        intentionally do not model storage contents. They are a staging point
//        for replacing the shells with real SRAM macros and LEF/liberty views.

module instr_mem_physical #(
  parameter int DEPTH = 1024
)(
  input  logic clk,
  input  logic rst_n,

  input  logic host_we,
  input  logic [$clog2(DEPTH)-1:0] host_addr,
  input  logic [1:0] host_lane,
  input  logic [31:0] host_wdata,
  output logic [31:0] host_rdata,

  input  logic fetch_en,
  input  logic [$clog2(DEPTH)-1:0] fetch_pc,
  output logic [127:0] instr,
  output logic fetch_error
);
  always_comb begin
    host_rdata = 32'd0;
    instr = 128'd0;
    fetch_error = 1'b0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
    end
  end
endmodule

module hbm_model_physical #(
  parameter int HBM_BYTES = 1048576,
  parameter int DATA_W = 32,
  parameter int READ_LATENCY = vtpu_pkg::VTPU_HBM_READ_LATENCY,
  parameter int WRITE_LATENCY = vtpu_pkg::VTPU_HBM_WRITE_LATENCY
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mem_req_t req,
  output vtpu_pkg::mem_resp_t resp,

  input  logic host_we,
  input  logic [31:0] host_addr,
  input  logic [31:0] host_wdata,
  input  logic [3:0] host_wstrb,
  output logic [31:0] host_rdata,

  output logic access_pulse,
  output logic stall_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = HBM_BYTES / WORD_BYTES;

  vtpu_pkg::mem_resp_t resp_q;
  vtpu_pkg::mem_req_t req_q;
  logic busy_q;
  int unsigned cycles_left_q;
  int unsigned word_addr_c;

  assign resp = resp_q;
  assign host_rdata = 32'd0;
  assign stall_pulse = req.valid && !resp_q.ready;

  always_comb begin
    word_addr_c = req_q.addr / WORD_BYTES;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0, error_code: 8'h00};
      req_q <= '0;
      busy_q <= 1'b0;
      cycles_left_q <= 0;
      access_pulse <= 1'b0;
    end else begin
      resp_q.valid <= 1'b0;
      resp_q.ready <= !busy_q;
      access_pulse <= 1'b0;

      if (!busy_q && req.valid) begin
        req_q <= req;
        busy_q <= 1'b1;
        cycles_left_q <= req.write ? WRITE_LATENCY : READ_LATENCY;
        resp_q.ready <= 1'b0;
        access_pulse <= 1'b1;
      end else if (busy_q) begin
        if (cycles_left_q == 0) begin
          busy_q <= 1'b0;
          resp_q.ready <= 1'b1;
          resp_q.valid <= 1'b1;
          resp_q.error <= 1'b0;
          resp_q.error_code <= vtpu_pkg::ERR_NONE;
          resp_q.rdata <= 32'd0;
          if (((req_q.addr % WORD_BYTES) != 0) || (word_addr_c >= WORDS)) begin
            resp_q.error <= 1'b1;
            resp_q.error_code <= vtpu_pkg::ERR_BAD_ADDR;
          end
        end else begin
          cycles_left_q <= cycles_left_q - 1;
        end
      end
    end
  end
endmodule

module cmem_top_physical #(
  parameter int CMEM_BYTES = 524288,
  parameter int DATA_W = 32,
  parameter int BANKS = vtpu_pkg::VTPU_VMEM_BANKS
)(
  input logic clk,
  input logic rst_n,

  input  vtpu_pkg::vmem_req_t req_dma,
  output vtpu_pkg::vmem_resp_t resp_dma,

  input  vtpu_pkg::vmem_req_t req_tc0,
  output vtpu_pkg::vmem_resp_t resp_tc0,

  input  vtpu_pkg::vmem_req_t req_tc1,
  output vtpu_pkg::vmem_resp_t resp_tc1,

  output logic [31:0] access_count_pulse,
  output logic [31:0] bank_conflict_count_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = CMEM_BYTES / WORD_BYTES;
  localparam int BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS);

  vtpu_pkg::vmem_resp_t resp_dma_q;
  vtpu_pkg::vmem_resp_t resp_tc0_q;
  vtpu_pkg::vmem_resp_t resp_tc1_q;
  vtpu_pkg::vmem_resp_t resp_dma_s;
  vtpu_pkg::vmem_resp_t resp_tc0_s;
  vtpu_pkg::vmem_resp_t resp_tc1_s;

  logic ready_dma;
  logic ready_tc0;
  logic ready_tc1;
  logic valid_dma;
  logic valid_tc0;
  logic valid_tc1;
  logic [BANK_W-1:0] bank_dma;
  logic [BANK_W-1:0] bank_tc0;
  logic [BANK_W-1:0] bank_tc1;

  assign resp_dma = resp_dma_s;
  assign resp_tc0 = resp_tc0_s;
  assign resp_tc1 = resp_tc1_s;

  function automatic logic [BANK_W-1:0] bank_of(input logic [31:0] addr);
    logic [31:0] word_addr;
    begin
      word_addr = addr >> 2;
      bank_of = word_addr[BANK_W-1:0];
    end
  endfunction

  function automatic vtpu_pkg::vmem_resp_t service_resp(input vtpu_pkg::vmem_req_t port_req);
    int unsigned word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      service_resp = '{ready: 1'b1, valid: 1'b1, rdata: 32'd0, error: 1'b0};
      if ((port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS)) begin
        service_resp.error = 1'b1;
      end
    end
  endfunction

  always_comb begin
    valid_dma = req_dma.valid;
    valid_tc0 = req_tc0.valid;
    valid_tc1 = req_tc1.valid;
    bank_dma = bank_of(req_dma.addr);
    bank_tc0 = bank_of(req_tc0.addr);
    bank_tc1 = bank_of(req_tc1.addr);

    ready_tc0 = valid_tc0;
    ready_tc1 = valid_tc1 && !(valid_tc0 && (bank_tc1 == bank_tc0));
    ready_dma = valid_dma &&
                !(valid_tc0 && (bank_dma == bank_tc0)) &&
                !(valid_tc1 && ready_tc1 && (bank_dma == bank_tc1));

    access_count_pulse = {31'd0, ready_tc0} +
                         {31'd0, ready_tc1} +
                         {31'd0, ready_dma};
    bank_conflict_count_pulse =
      {31'd0, (valid_tc1 && !ready_tc1)} +
      {31'd0, (valid_dma && !ready_dma)};

    resp_dma_s = resp_dma_q;
    resp_tc0_s = resp_tc0_q;
    resp_tc1_s = resp_tc1_q;
    resp_dma_s.ready = !valid_dma || ready_dma;
    resp_tc0_s.ready = !valid_tc0 || ready_tc0;
    resp_tc1_s.ready = !valid_tc1 || ready_tc1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc0_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc1_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
    end else begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc0_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc1_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};

      if (valid_tc0 && ready_tc0) resp_tc0_q <= service_resp(req_tc0);
      if (valid_tc1 && ready_tc1) resp_tc1_q <= service_resp(req_tc1);
      if (valid_dma && ready_dma) resp_dma_q <= service_resp(req_dma);
    end
  end
endmodule

module vmem_top_physical #(
  parameter int VMEM_BYTES = 262144,
  parameter int DATA_W = 32,
  parameter int BANKS = vtpu_pkg::VTPU_VMEM_BANKS,
  parameter int MXU_PORTS = 4
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

  output logic [31:0] access_count_pulse,
  output logic [31:0] bank_conflict_count_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;
  localparam int WORDS = VMEM_BYTES / WORD_BYTES;
  localparam int BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS);

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
  integer comb_idx;
  integer higher_idx;
  integer seq_idx;

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

  function automatic vtpu_pkg::vmem_resp_t service_resp(input vtpu_pkg::vmem_req_t port_req);
    int unsigned word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      service_resp = '{ready: 1'b1, valid: 1'b1, rdata: 32'd0, error: 1'b0};
      if ((port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS)) begin
        service_resp.error = 1'b1;
      end
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
                         {31'd0, ready_dma};
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end
    end else begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end

      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        if (valid_mxu[seq_idx] && ready_mxu[seq_idx]) begin
          resp_mxu_q[seq_idx] <= service_resp(req_mxu[seq_idx]);
        end
      end
      if (valid_vector && ready_vector) resp_vector_q <= service_resp(req_vector);
      if (valid_reduce && ready_reduce) resp_reduce_q <= service_resp(req_reduce);
      if (valid_dma && ready_dma) resp_dma_q <= service_resp(req_dma);
    end
  end
endmodule
