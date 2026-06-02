/* verilator lint_off DECLFILENAME */
// Module set: physical memory shells
// Purpose: Physical-design-safe SRAM macro adapters for on-chip memories.
// Notes: The physical path uses real SRAM macro instances when
//        VTPU_PHYSICAL_SRAM_MACROS is defined. RTL simulation keeps a
//        deterministic behavioral model with the same one-cycle response.

`ifdef VTPU_PHYSICAL_SRAM_MACROS
/* verilator lint_off UNDRIVEN */
(* blackbox *)
module sky130_sram_1rw1r_80x64_8(
  input  clk0,
  input  csb0,
  input  web0,
  input  [9:0] wmask0,
  input  [5:0] addr0,
  input  [79:0] din0,
  output [79:0] dout0,
  input  clk1,
  input  csb1,
  input  [5:0] addr1,
  output [79:0] dout1
);
endmodule
/* verilator lint_on UNDRIVEN */
`endif

module vtpu_sram_1rw_32x64 #(
  parameter int WORDS = 64
)(
  input  logic clk,
  input  logic en,
  input  logic write,
  input  logic [((WORDS <= 1) ? 1 : $clog2(WORDS))-1:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0] wstrb,
  output logic [31:0] rdata
);
  localparam int MACRO_ROWS = 64;
  localparam int MACRO_TILES = (WORDS + MACRO_ROWS - 1) / MACRO_ROWS;
  localparam int TILE_W = (MACRO_TILES <= 1) ? 1 : $clog2(MACRO_TILES);

`ifdef VTPU_PHYSICAL_SRAM_MACROS
  logic [79:0] macro_dout0 [MACRO_TILES];
  logic [79:0] macro_dout1 [MACRO_TILES];
  logic [TILE_W-1:0] tile_idx;
  logic [5:0] row_addr;

  assign tile_idx = TILE_W'(addr >> 6);
  assign row_addr = 6'(addr);
  assign rdata = macro_dout0[tile_idx][31:0];

  genvar macro_tile_g;
  generate
    for (macro_tile_g = 0; macro_tile_g < MACRO_TILES; macro_tile_g++) begin : gen_macro_tiles
      sky130_sram_1rw1r_80x64_8 u_macro (
        .clk0(clk),
        .csb0(!(en && (tile_idx == TILE_W'(macro_tile_g)))),
        .web0(!write),
        .wmask0({6'b0, wstrb}),
        .addr0(row_addr),
        .din0({48'd0, wdata}),
        .dout0(macro_dout0[macro_tile_g]),
        .clk1(clk),
        .csb1(1'b1),
        .addr1(6'd0),
        .dout1(macro_dout1[macro_tile_g])
      );
    end
  endgenerate
`else
  logic [31:0] mem [0:WORDS-1];
  logic [31:0] rdata_q;

  assign rdata = rdata_q;

  always_ff @(posedge clk) begin
    rdata_q <= 32'd0;
    if (en) begin
      if (write) begin
        if (wstrb[0]) mem[addr][7:0] <= wdata[7:0];
        if (wstrb[1]) mem[addr][15:8] <= wdata[15:8];
        if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];
      end else begin
        rdata_q <= mem[addr];
      end
    end
  end
`endif
endmodule

module vtpu_sram_1rw_64x64 #(
  parameter int WORDS = 64
)(
  input  logic clk,
  input  logic en,
  input  logic write,
  input  logic [((WORDS <= 1) ? 1 : $clog2(WORDS))-1:0] addr,
  input  logic [63:0] wdata,
  input  logic [7:0] wstrb,
  output logic [63:0] rdata
);
  localparam int MACRO_ROWS = 64;
  localparam int MACRO_TILES = (WORDS + MACRO_ROWS - 1) / MACRO_ROWS;
  localparam int TILE_W = (MACRO_TILES <= 1) ? 1 : $clog2(MACRO_TILES);

`ifdef VTPU_PHYSICAL_SRAM_MACROS
  logic [79:0] macro_dout0 [MACRO_TILES];
  logic [79:0] macro_dout1 [MACRO_TILES];
  logic [TILE_W-1:0] tile_idx;
  logic [5:0] row_addr;

  assign tile_idx = TILE_W'(addr >> 6);
  assign row_addr = 6'(addr);
  assign rdata = macro_dout0[tile_idx][63:0];

  genvar macro_tile_g;
  generate
    for (macro_tile_g = 0; macro_tile_g < MACRO_TILES; macro_tile_g++) begin : gen_macro_tiles
      sky130_sram_1rw1r_80x64_8 u_macro (
        .clk0(clk),
        .csb0(!(en && (tile_idx == TILE_W'(macro_tile_g)))),
        .web0(!write),
        .wmask0({2'b0, wstrb}),
        .addr0(row_addr),
        .din0({16'd0, wdata}),
        .dout0(macro_dout0[macro_tile_g]),
        .clk1(clk),
        .csb1(1'b1),
        .addr1(6'd0),
        .dout1(macro_dout1[macro_tile_g])
      );
    end
  endgenerate
`else
  logic [63:0] mem [0:WORDS-1];
  logic [63:0] rdata_q;

  assign rdata = rdata_q;

  always_ff @(posedge clk) begin
    rdata_q <= 64'd0;
    if (en) begin
      if (write) begin
        if (wstrb[0]) mem[addr][7:0] <= wdata[7:0];
        if (wstrb[1]) mem[addr][15:8] <= wdata[15:8];
        if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];
        if (wstrb[4]) mem[addr][39:32] <= wdata[39:32];
        if (wstrb[5]) mem[addr][47:40] <= wdata[47:40];
        if (wstrb[6]) mem[addr][55:48] <= wdata[55:48];
        if (wstrb[7]) mem[addr][63:56] <= wdata[63:56];
      end else begin
        rdata_q <= mem[addr];
      end
    end
  end
`endif
endmodule

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
  localparam int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic lower_en;
  logic upper_en;
  logic lower_write;
  logic upper_write;
  logic [ADDR_W-1:0] lower_addr;
  logic [ADDR_W-1:0] upper_addr;
  logic [63:0] lower_wdata;
  logic [63:0] upper_wdata;
  logic [7:0] lower_wstrb;
  logic [7:0] upper_wstrb;
  logic [63:0] lower_rdata;
  logic [63:0] upper_rdata;
  logic [31:0] host_rdata_q;
  logic [31:0] fetch_pc_u;
  logic [ADDR_W:0] host_shadow_index;
`ifndef VTPU_PHYSICAL_SRAM_MACROS
  logic [31:0] lower_shadow [0:(DEPTH*2)-1];
  logic [31:0] upper_shadow [0:(DEPTH*2)-1];
`endif

  assign fetch_pc_u = 32'(fetch_pc);
  assign host_shadow_index = {host_addr, host_lane[0]};
  assign lower_en = host_we ? (host_lane[1] == 1'b0) : fetch_en;
  assign upper_en = host_we ? (host_lane[1] == 1'b1) : fetch_en;
  assign lower_write = host_we && (host_lane[1] == 1'b0);
  assign upper_write = host_we && (host_lane[1] == 1'b1);
  assign lower_addr = host_we ? host_addr : fetch_pc;
  assign upper_addr = host_we ? host_addr : fetch_pc;
  assign lower_wdata = host_lane[0] ? {host_wdata, 32'd0} : {32'd0, host_wdata};
  assign upper_wdata = host_lane[0] ? {host_wdata, 32'd0} : {32'd0, host_wdata};
  assign lower_wstrb = host_lane[0] ? 8'hF0 : 8'h0F;
  assign upper_wstrb = host_lane[0] ? 8'hF0 : 8'h0F;
  assign host_rdata = host_rdata_q;
  assign instr = {upper_rdata, lower_rdata};
  assign fetch_error = fetch_en && (fetch_pc_u >= DEPTH);

  vtpu_sram_1rw_64x64 #(
    .WORDS(DEPTH)
  ) u_instr_lower (
    .clk(clk),
    .en(lower_en),
    .write(lower_write),
    .addr(lower_addr),
    .wdata(lower_wdata),
    .wstrb(lower_wstrb),
    .rdata(lower_rdata)
  );

  vtpu_sram_1rw_64x64 #(
    .WORDS(DEPTH)
  ) u_instr_upper (
    .clk(clk),
    .en(upper_en),
    .write(upper_write),
    .addr(upper_addr),
    .wdata(upper_wdata),
    .wstrb(upper_wstrb),
    .rdata(upper_rdata)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_rdata_q <= 32'd0;
    end else begin
`ifndef VTPU_PHYSICAL_SRAM_MACROS
      if (host_we) begin
        if (host_lane[1]) begin
          upper_shadow[host_shadow_index] <= host_wdata;
        end else begin
          lower_shadow[host_shadow_index] <= host_wdata;
        end
      end

      host_rdata_q <= host_lane[1] ? upper_shadow[host_shadow_index] :
                                    lower_shadow[host_shadow_index];
`else
      host_rdata_q <= 32'd0;
`endif
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
  localparam int BANK_WORDS = (WORDS + BANKS - 1) / BANKS;
  localparam int BANK_ADDR_W = (BANK_WORDS <= 1) ? 1 : $clog2(BANK_WORDS);

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
  logic [BANKS-1:0] bank_en;
  logic [BANKS-1:0] bank_write;
  logic [BANK_ADDR_W-1:0] bank_addr [BANKS];
  logic [31:0] bank_wdata [BANKS];
  logic [3:0] bank_wstrb [BANKS];
  logic [31:0] bank_rdata [BANKS];
  logic [1:0] pending_port_q [BANKS];
  logic pending_valid_q [BANKS];
  logic pending_error_q [BANKS];
  integer comb_idx;
  integer seq_idx;

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

  function automatic logic req_error(input vtpu_pkg::vmem_req_t port_req);
    int unsigned word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      req_error = (port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS);
    end
  endfunction

  function automatic logic [BANK_ADDR_W-1:0] macro_addr(input vtpu_pkg::vmem_req_t port_req);
    logic [31:0] word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      macro_addr = BANK_ADDR_W'(word_addr / BANKS);
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

    for (comb_idx = 0; comb_idx < BANKS; comb_idx++) begin
      bank_en[comb_idx] = 1'b0;
      bank_write[comb_idx] = 1'b0;
      bank_addr[comb_idx] = '0;
      bank_wdata[comb_idx] = 32'd0;
      bank_wstrb[comb_idx] = 4'h0;
    end

    if (valid_tc0 && ready_tc0 && !req_error(req_tc0)) begin
      bank_en[bank_tc0] = 1'b1;
      bank_write[bank_tc0] = req_tc0.write;
      bank_addr[bank_tc0] = macro_addr(req_tc0);
      bank_wdata[bank_tc0] = req_tc0.wdata;
      bank_wstrb[bank_tc0] = req_tc0.wstrb;
    end
    if (valid_tc1 && ready_tc1 && !req_error(req_tc1)) begin
      bank_en[bank_tc1] = 1'b1;
      bank_write[bank_tc1] = req_tc1.write;
      bank_addr[bank_tc1] = macro_addr(req_tc1);
      bank_wdata[bank_tc1] = req_tc1.wdata;
      bank_wstrb[bank_tc1] = req_tc1.wstrb;
    end
    if (valid_dma && ready_dma && !req_error(req_dma)) begin
      bank_en[bank_dma] = 1'b1;
      bank_write[bank_dma] = req_dma.write;
      bank_addr[bank_dma] = macro_addr(req_dma);
      bank_wdata[bank_dma] = req_dma.wdata;
      bank_wstrb[bank_dma] = req_dma.wstrb;
    end

    resp_dma_s = resp_dma_q;
    resp_tc0_s = resp_tc0_q;
    resp_tc1_s = resp_tc1_q;
    resp_dma_s.ready = !valid_dma || ready_dma;
    resp_tc0_s.ready = !valid_tc0 || ready_tc0;
    resp_tc1_s.ready = !valid_tc1 || ready_tc1;
  end

  genvar cmem_bank_g;
  generate
    for (cmem_bank_g = 0; cmem_bank_g < BANKS; cmem_bank_g++) begin : gen_cmem_banks
      vtpu_sram_1rw_32x64 #(
        .WORDS(BANK_WORDS)
      ) u_bank (
        .clk(clk),
        .en(bank_en[cmem_bank_g]),
        .write(bank_write[cmem_bank_g]),
        .addr(bank_addr[cmem_bank_g]),
        .wdata(bank_wdata[cmem_bank_g]),
        .wstrb(bank_wstrb[cmem_bank_g]),
        .rdata(bank_rdata[cmem_bank_g])
      );
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc0_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc1_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      for (seq_idx = 0; seq_idx < BANKS; seq_idx++) begin
        pending_port_q[seq_idx] <= 2'd0;
        pending_valid_q[seq_idx] <= 1'b0;
        pending_error_q[seq_idx] <= 1'b0;
      end
    end else begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc0_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_tc1_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};

      for (seq_idx = 0; seq_idx < BANKS; seq_idx++) begin
        if (pending_valid_q[seq_idx]) begin
          unique case (pending_port_q[seq_idx])
            2'd0: resp_tc0_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
            2'd1: resp_tc1_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
            2'd2: resp_dma_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
            default: begin
            end
          endcase
        end
        pending_valid_q[seq_idx] <= 1'b0;
        pending_error_q[seq_idx] <= 1'b0;
      end

      if (valid_tc0 && ready_tc0) begin
        pending_port_q[bank_tc0] <= 2'd0;
        pending_valid_q[bank_tc0] <= 1'b1;
        pending_error_q[bank_tc0] <= req_error(req_tc0);
      end
      if (valid_tc1 && ready_tc1) begin
        pending_port_q[bank_tc1] <= 2'd1;
        pending_valid_q[bank_tc1] <= 1'b1;
        pending_error_q[bank_tc1] <= req_error(req_tc1);
      end
      if (valid_dma && ready_dma) begin
        pending_port_q[bank_dma] <= 2'd2;
        pending_valid_q[bank_dma] <= 1'b1;
        pending_error_q[bank_dma] <= req_error(req_dma);
      end
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
  localparam int BANK_WORDS = (WORDS + BANKS - 1) / BANKS;
  localparam int BANK_ADDR_W = (BANK_WORDS <= 1) ? 1 : $clog2(BANK_WORDS);

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
  logic [BANKS-1:0] bank_en;
  logic [BANKS-1:0] bank_write;
  logic [BANK_ADDR_W-1:0] bank_addr [BANKS];
  logic [31:0] bank_wdata [BANKS];
  logic [3:0] bank_wstrb [BANKS];
  logic [31:0] bank_rdata [BANKS];
  logic [3:0] pending_port_q [BANKS];
  logic pending_valid_q [BANKS];
  logic pending_error_q [BANKS];
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

  function automatic logic req_error(input vtpu_pkg::vmem_req_t port_req);
    int unsigned word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      req_error = (port_req.addr[1:0] != 2'b00) || (word_addr >= WORDS);
    end
  endfunction

  function automatic logic [BANK_ADDR_W-1:0] macro_addr(input vtpu_pkg::vmem_req_t port_req);
    logic [31:0] word_addr;
    begin
      word_addr = port_req.addr / WORD_BYTES;
      macro_addr = BANK_ADDR_W'(word_addr / BANKS);
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

    for (comb_idx = 0; comb_idx < BANKS; comb_idx++) begin
      bank_en[comb_idx] = 1'b0;
      bank_write[comb_idx] = 1'b0;
      bank_addr[comb_idx] = '0;
      bank_wdata[comb_idx] = 32'd0;
      bank_wstrb[comb_idx] = 4'h0;
    end

    for (comb_idx = 0; comb_idx < MXU_PORTS; comb_idx++) begin
      if (valid_mxu[comb_idx] && ready_mxu[comb_idx] && !req_error(req_mxu[comb_idx])) begin
        bank_en[bank_mxu[comb_idx]] = 1'b1;
        bank_write[bank_mxu[comb_idx]] = req_mxu[comb_idx].write;
        bank_addr[bank_mxu[comb_idx]] = macro_addr(req_mxu[comb_idx]);
        bank_wdata[bank_mxu[comb_idx]] = req_mxu[comb_idx].wdata;
        bank_wstrb[bank_mxu[comb_idx]] = req_mxu[comb_idx].wstrb;
      end
    end
    if (valid_vector && ready_vector && !req_error(req_vector)) begin
      bank_en[bank_vector] = 1'b1;
      bank_write[bank_vector] = req_vector.write;
      bank_addr[bank_vector] = macro_addr(req_vector);
      bank_wdata[bank_vector] = req_vector.wdata;
      bank_wstrb[bank_vector] = req_vector.wstrb;
    end
    if (valid_reduce && ready_reduce && !req_error(req_reduce)) begin
      bank_en[bank_reduce] = 1'b1;
      bank_write[bank_reduce] = req_reduce.write;
      bank_addr[bank_reduce] = macro_addr(req_reduce);
      bank_wdata[bank_reduce] = req_reduce.wdata;
      bank_wstrb[bank_reduce] = req_reduce.wstrb;
    end
    if (valid_dma && ready_dma && !req_error(req_dma)) begin
      bank_en[bank_dma] = 1'b1;
      bank_write[bank_dma] = req_dma.write;
      bank_addr[bank_dma] = macro_addr(req_dma);
      bank_wdata[bank_dma] = req_dma.wdata;
      bank_wstrb[bank_dma] = req_dma.wstrb;
    end

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

  genvar vmem_bank_g;
  generate
    for (vmem_bank_g = 0; vmem_bank_g < BANKS; vmem_bank_g++) begin : gen_vmem_banks
      vtpu_sram_1rw_32x64 #(
        .WORDS(BANK_WORDS)
      ) u_bank (
        .clk(clk),
        .en(bank_en[vmem_bank_g]),
        .write(bank_write[vmem_bank_g]),
        .addr(bank_addr[vmem_bank_g]),
        .wdata(bank_wdata[vmem_bank_g]),
        .wstrb(bank_wstrb[vmem_bank_g]),
        .rdata(bank_rdata[vmem_bank_g])
      );
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end
      for (seq_idx = 0; seq_idx < BANKS; seq_idx++) begin
        pending_port_q[seq_idx] <= 4'd0;
        pending_valid_q[seq_idx] <= 1'b0;
        pending_error_q[seq_idx] <= 1'b0;
      end
    end else begin
      resp_dma_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_vector_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      resp_reduce_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        resp_mxu_q[seq_idx] <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0};
      end

      for (seq_idx = 0; seq_idx < BANKS; seq_idx++) begin
        if (pending_valid_q[seq_idx]) begin
          if (pending_port_q[seq_idx] < MXU_PORTS[3:0]) begin
            resp_mxu_q[pending_port_q[seq_idx][1:0]] <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
          end else if (pending_port_q[seq_idx] == 4'd8) begin
            resp_vector_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
          end else if (pending_port_q[seq_idx] == 4'd9) begin
            resp_reduce_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
          end else if (pending_port_q[seq_idx] == 4'd10) begin
            resp_dma_q <= '{ready: 1'b1, valid: 1'b1, rdata: bank_rdata[seq_idx], error: pending_error_q[seq_idx]};
          end
        end
        pending_valid_q[seq_idx] <= 1'b0;
        pending_error_q[seq_idx] <= 1'b0;
      end

      for (seq_idx = 0; seq_idx < MXU_PORTS; seq_idx++) begin
        if (valid_mxu[seq_idx] && ready_mxu[seq_idx]) begin
          pending_port_q[bank_mxu[seq_idx]] <= 4'(seq_idx);
          pending_valid_q[bank_mxu[seq_idx]] <= 1'b1;
          pending_error_q[bank_mxu[seq_idx]] <= req_error(req_mxu[seq_idx]);
        end
      end
      if (valid_vector && ready_vector) begin
        pending_port_q[bank_vector] <= 4'd8;
        pending_valid_q[bank_vector] <= 1'b1;
        pending_error_q[bank_vector] <= req_error(req_vector);
      end
      if (valid_reduce && ready_reduce) begin
        pending_port_q[bank_reduce] <= 4'd9;
        pending_valid_q[bank_reduce] <= 1'b1;
        pending_error_q[bank_reduce] <= req_error(req_reduce);
      end
      if (valid_dma && ready_dma) begin
        pending_port_q[bank_dma] <= 4'd10;
        pending_valid_q[bank_dma] <= 1'b1;
        pending_error_q[bank_dma] <= req_error(req_dma);
      end
    end
  end
endmodule
