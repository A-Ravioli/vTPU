// Module: virtual_tpu_v4_top
// Purpose: Executable educational TPU v4-inspired chip shell for a 16x16 int8 matmul demo.
// Public TPU inspiration: Host-loaded programs drive DMA, TensorCore, MXU, VMEM, and HBM movement.
// Educational simplification: One TensorCore and one MXU are active; HBM/VMEM are simulation SRAM arrays.
// Inputs: clock/reset and 32-bit host/MMIO request channel.
// Outputs: host response plus done/busy/error status.
// State: Host MMIO, instruction execution, DMA byte copy, clear, matmul issue/writeback.
// Latency: DMA and clear move one byte per cycle; MXU latency is delegated to TensorCore/MXU.
// Backpressure: host_req_ready is always high; writes to HBM/instruction memory are rejected while busy.
// Error behavior: unsupported opcodes, flags, targets, spaces, unaligned or out-of-range accesses enter ERROR.
// Tests: Chip-level cocotb tests load matmul_16_program through MMIO and compare HBM output to NumPy.
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
  parameter int INSTR_DEPTH = 1024
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
  localparam logic [31:0] REG_CONTROL = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS = 32'h0000_0004;
  localparam logic [31:0] REG_ERROR_CODE = 32'h0000_0008;
  localparam logic [31:0] REG_PC = 32'h0000_000C;
  localparam logic [31:0] INSTR_BASE = 32'h0000_1000;
  localparam logic [31:0] INSTR_BYTES = INSTR_DEPTH * 16;
  localparam logic [31:0] HBM_BASE = 32'h0010_0000;
  localparam logic [31:0] HBM_LIMIT = HBM_BASE + HBM_BYTES;
  localparam int INSTR_ADDR_W = $clog2(INSTR_DEPTH);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_EXEC,
    ST_DMA,
    ST_CLEAR,
    ST_PREP_MATMUL,
    ST_ISSUE_TC,
    ST_WAIT_TC,
    ST_WRITE_C,
    ST_HALT,
    ST_ERROR
  } exec_state_t;

  exec_state_t state_q;
  vtpu_pkg::host_resp_t host_resp_q;
  logic [127:0] instr_mem [0:INSTR_DEPTH-1];
  logic [7:0] hbm_mem [0:HBM_BYTES-1];
  logic [7:0] vmem_mem [0:VMEM_BYTES-1];
  logic [15:0] pc_q;
  logic [7:0] error_code_q;

  vtpu_pkg::instr_t instr_q;
  logic [7:0] opcode_q;
  logic [7:0] flags_q;
  logic [7:0] target_q;
  logic [15:0] dst_q;
  logic [15:0] src0_q;
  logic [15:0] src1_q;
  logic [15:0] imm0_q;
  logic [15:0] imm1_q;
  logic [15:0] imm2_q;

  logic [2:0] dma_src_space_q;
  logic [2:0] dma_dst_space_q;
  logic [31:0] dma_src_addr_q;
  logic [31:0] dma_dst_addr_q;
  logic [31:0] dma_len_q;
  logic [31:0] dma_idx_q;
  logic [31:0] clear_idx_q;
  logic [31:0] write_c_idx_q;

  logic signed [DATA_W-1:0] tc_a_tile [0:ARRAY_M*ARRAY_K-1];
  logic signed [DATA_W-1:0] tc_b_tile [0:ARRAY_K*ARRAY_N-1];
  logic signed [ACC_W-1:0] tc_c_in [0:ARRAY_M*ARRAY_N-1];
  logic signed [ACC_W-1:0] tc_c_out [0:ARRAY_M*ARRAY_N-1];
  vtpu_pkg::tc_cmd_t tc_cmd_q;
  logic tc_cmd_valid_q;
  logic tc_cmd_ready;
  vtpu_pkg::unit_status_t tc_status;

  integer host_pc;
  integer host_lane;
  integer host_offset;
  integer prep_idx;
  integer row_idx;
  integer col_idx;
  integer word_addr;

  assign host_req_ready = 1'b1;
  assign host_resp = host_resp_q;
  assign host_resp_valid = host_resp_q.valid;
  assign done = (state_q == ST_HALT);
  assign busy = (state_q != ST_IDLE) && (state_q != ST_HALT) && (state_q != ST_ERROR);
  assign error = (state_q == ST_ERROR);

  tensor_core #(
    .TC_ID(0),
    .MXUS_PER_TC(MXUS_PER_TC),
    .ARRAY_M(ARRAY_M),
    .ARRAY_N(ARRAY_N),
    .ARRAY_K(ARRAY_K),
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
  ) u_tensor_core0 (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(tc_cmd_q),
    .cmd_valid(tc_cmd_valid_q),
    .cmd_ready(tc_cmd_ready),
    .a_tile(tc_a_tile),
    .b_tile(tc_b_tile),
    .c_in(tc_c_in),
    .c_out(tc_c_out),
    .status(tc_status)
  );

  always_comb begin
    instr_q = vtpu_pkg::unpack_instr(instr_mem[pc_q[INSTR_ADDR_W-1:0]]);
  end

  function automatic logic [31:0] read_hbm_word(input logic [31:0] addr);
    read_hbm_word = {
      hbm_mem[addr + 32'd3],
      hbm_mem[addr + 32'd2],
      hbm_mem[addr + 32'd1],
      hbm_mem[addr]
    };
  endfunction

  function automatic logic [31:0] read_vmem_word(input logic [31:0] addr);
    read_vmem_word = {
      vmem_mem[addr + 32'd3],
      vmem_mem[addr + 32'd2],
      vmem_mem[addr + 32'd1],
      vmem_mem[addr]
    };
  endfunction

  task automatic set_error(input logic [7:0] code);
    begin
      state_q <= ST_ERROR;
      error_code_q <= code;
    end
  endtask

  task automatic write_hbm_word(input logic [31:0] addr, input logic [31:0] data);
    begin
      hbm_mem[addr] <= data[7:0];
      hbm_mem[addr + 32'd1] <= data[15:8];
      hbm_mem[addr + 32'd2] <= data[23:16];
      hbm_mem[addr + 32'd3] <= data[31:24];
    end
  endtask

  task automatic write_vmem_word(input logic [31:0] addr, input logic [31:0] data);
    begin
      vmem_mem[addr] <= data[7:0];
      vmem_mem[addr + 32'd1] <= data[15:8];
      vmem_mem[addr + 32'd2] <= data[23:16];
      vmem_mem[addr + 32'd3] <= data[31:24];
    end
  endtask

  task automatic retire_instruction;
    begin
      pc_q <= pc_q + 16'd1;
      state_q <= ST_EXEC;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      pc_q <= 16'd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      host_resp_q <= '{valid: 1'b0, rdata: '0, error: 1'b0};
      tc_cmd_q <= '0;
      tc_cmd_valid_q <= 1'b0;
      dma_src_space_q <= 3'd0;
      dma_dst_space_q <= 3'd0;
      dma_src_addr_q <= 32'd0;
      dma_dst_addr_q <= 32'd0;
      dma_len_q <= 32'd0;
      dma_idx_q <= 32'd0;
      clear_idx_q <= 32'd0;
      write_c_idx_q <= 32'd0;
      opcode_q <= 8'd0;
      flags_q <= 8'd0;
      target_q <= 8'd0;
      dst_q <= 16'd0;
      src0_q <= 16'd0;
      src1_q <= 16'd0;
      imm0_q <= 16'd0;
      imm1_q <= 16'd0;
      imm2_q <= 16'd0;
      for (prep_idx = 0; prep_idx < ARRAY_M*ARRAY_N; prep_idx++) begin
        tc_c_in[prep_idx] <= '0;
      end
      for (prep_idx = 0; prep_idx < ARRAY_M*ARRAY_K; prep_idx++) begin
        tc_a_tile[prep_idx] <= '0;
      end
      for (prep_idx = 0; prep_idx < ARRAY_K*ARRAY_N; prep_idx++) begin
        tc_b_tile[prep_idx] <= '0;
      end
    end else begin
      host_resp_q <= '{valid: 1'b0, rdata: '0, error: 1'b0};
      tc_cmd_valid_q <= 1'b0;

      if (host_req_valid) begin
        host_resp_q.valid <= 1'b1;
        if (host_req.addr[1:0] != 2'b00) begin
          host_resp_q.error <= 1'b1;
        end else if (host_req.addr == REG_CONTROL) begin
          if (host_req.write && host_req.wdata[0]) begin
            if (busy) begin
              host_resp_q.error <= 1'b1;
            end else begin
              pc_q <= 16'd0;
              error_code_q <= vtpu_pkg::ERR_NONE;
              state_q <= ST_EXEC;
            end
          end
          host_resp_q.rdata <= {31'd0, (state_q == ST_EXEC)};
        end else if (host_req.addr == REG_STATUS) begin
          host_resp_q.rdata <= {29'd0, error, busy, done};
        end else if (host_req.addr == REG_ERROR_CODE) begin
          host_resp_q.rdata <= {24'd0, error_code_q};
        end else if (host_req.addr == REG_PC) begin
          host_resp_q.rdata <= {16'd0, pc_q};
        end else if ((host_req.addr >= INSTR_BASE) && (host_req.addr < (INSTR_BASE + INSTR_BYTES))) begin
          host_offset = host_req.addr - INSTR_BASE;
          host_pc = host_offset >> 4;
          host_lane = (host_offset >> 2) & 3;
          if (host_req.write) begin
            if (busy) begin
              host_resp_q.error <= 1'b1;
            end else begin
              instr_mem[host_pc][host_lane*32 +: 32] <= host_req.wdata;
            end
          end else begin
            host_resp_q.rdata <= instr_mem[host_pc][host_lane*32 +: 32];
          end
        end else if ((host_req.addr >= HBM_BASE) && (host_req.addr < HBM_LIMIT)) begin
          host_offset = host_req.addr - HBM_BASE;
          if ((host_offset + 3) >= HBM_BYTES) begin
            host_resp_q.error <= 1'b1;
          end else if (host_req.write) begin
            if (busy) begin
              host_resp_q.error <= 1'b1;
            end else begin
              write_hbm_word(host_offset[31:0], host_req.wdata);
            end
          end else begin
            host_resp_q.rdata <= read_hbm_word(host_offset[31:0]);
          end
        end else begin
          host_resp_q.error <= 1'b1;
        end
      end

      unique case (state_q)
        ST_IDLE: begin
        end
        ST_EXEC: begin
          opcode_q <= instr_q.opcode;
          flags_q <= instr_q.flags;
          target_q <= instr_q.target;
          dst_q <= instr_q.dst;
          src0_q <= instr_q.src0;
          src1_q <= instr_q.src1;
          imm0_q <= instr_q.imm0;
          imm1_q <= instr_q.imm1;
          imm2_q <= instr_q.imm2;
          unique case (instr_q.opcode)
            vtpu_pkg::OPC_NOP,
            vtpu_pkg::OPC_BARRIER,
            vtpu_pkg::OPC_SYNC: begin
              retire_instruction();
            end
            vtpu_pkg::OPC_HALT: begin
              state_q <= ST_HALT;
            end
            vtpu_pkg::OPC_DMA_COPY,
            vtpu_pkg::OPC_LOAD_TILE,
            vtpu_pkg::OPC_STORE_TILE: begin
              dma_src_space_q <= instr_q.flags[2:0];
              dma_dst_space_q <= instr_q.flags[5:3];
              dma_src_addr_q <= {16'd0, instr_q.src0};
              dma_dst_addr_q <= {16'd0, instr_q.dst};
              dma_len_q <= {16'd0, instr_q.imm0};
              dma_idx_q <= 32'd0;
              if ((instr_q.src0[1:0] != 2'b00) || (instr_q.dst[1:0] != 2'b00) || (instr_q.imm0[1:0] != 2'b00)) begin
                set_error(vtpu_pkg::ERR_UNALIGNED);
              end else if (!(((instr_q.flags[2:0] == vtpu_pkg::MEM_HBM) && (instr_q.flags[5:3] == vtpu_pkg::MEM_VMEM0)) ||
                           ((instr_q.flags[2:0] == vtpu_pkg::MEM_VMEM0) && (instr_q.flags[5:3] == vtpu_pkg::MEM_HBM)))) begin
                set_error(vtpu_pkg::ERR_UNSUPPORTED);
              end else if (((instr_q.flags[2:0] == vtpu_pkg::MEM_HBM) && (({16'd0, instr_q.src0} + {16'd0, instr_q.imm0}) > HBM_BYTES)) ||
                           ((instr_q.flags[5:3] == vtpu_pkg::MEM_HBM) && (({16'd0, instr_q.dst} + {16'd0, instr_q.imm0}) > HBM_BYTES)) ||
                           ((instr_q.flags[2:0] == vtpu_pkg::MEM_VMEM0) && (({16'd0, instr_q.src0} + {16'd0, instr_q.imm0}) > VMEM_BYTES)) ||
                           ((instr_q.flags[5:3] == vtpu_pkg::MEM_VMEM0) && (({16'd0, instr_q.dst} + {16'd0, instr_q.imm0}) > VMEM_BYTES))) begin
                set_error(vtpu_pkg::ERR_BAD_ADDR);
              end else if (instr_q.imm0 == 16'd0) begin
                retire_instruction();
              end else begin
                state_q <= ST_DMA;
              end
            end
            vtpu_pkg::OPC_CLEAR: begin
              clear_idx_q <= 32'd0;
              if ((instr_q.flags[2:0] != vtpu_pkg::MEM_VMEM0) || (instr_q.dst[1:0] != 2'b00) || (instr_q.imm0[1:0] != 2'b00)) begin
                set_error(vtpu_pkg::ERR_UNSUPPORTED);
              end else if (({16'd0, instr_q.dst} + {16'd0, instr_q.imm0}) > VMEM_BYTES) begin
                set_error(vtpu_pkg::ERR_BAD_ADDR);
              end else if (instr_q.imm0 == 16'd0) begin
                retire_instruction();
              end else begin
                state_q <= ST_CLEAR;
              end
            end
            vtpu_pkg::OPC_MATMUL: begin
              if ((instr_q.target != 8'h10) ||
                  (instr_q.imm0 != ARRAY_M[15:0]) ||
                  (instr_q.imm1 != ARRAY_N[15:0]) ||
                  (instr_q.imm2 != ARRAY_K[15:0])) begin
                set_error(vtpu_pkg::ERR_BAD_TARGET);
              end else if (((instr_q.flags & ~8'h09) != 8'h00) || (instr_q.flags[3] != 1'b1)) begin
                set_error(vtpu_pkg::ERR_UNSUPPORTED);
              end else if ((({16'd0, instr_q.src0} + (ARRAY_M * ARRAY_K)) > VMEM_BYTES) ||
                           (({16'd0, instr_q.src1} + (ARRAY_K * ARRAY_N)) > VMEM_BYTES) ||
                           (({16'd0, instr_q.dst} + (ARRAY_M * ARRAY_N * 4)) > VMEM_BYTES)) begin
                set_error(vtpu_pkg::ERR_BAD_ADDR);
              end else begin
                state_q <= ST_PREP_MATMUL;
              end
            end
            default: begin
              set_error(vtpu_pkg::ERR_UNSUPPORTED);
            end
          endcase
        end
        ST_DMA: begin
          if (dma_src_space_q == vtpu_pkg::MEM_HBM) begin
            vmem_mem[dma_dst_addr_q + dma_idx_q] <= hbm_mem[dma_src_addr_q + dma_idx_q];
          end else begin
            hbm_mem[dma_dst_addr_q + dma_idx_q] <= vmem_mem[dma_src_addr_q + dma_idx_q];
          end
          if (dma_idx_q == (dma_len_q - 32'd1)) begin
            retire_instruction();
          end else begin
            dma_idx_q <= dma_idx_q + 32'd1;
          end
        end
        ST_CLEAR: begin
          vmem_mem[{16'd0, dst_q} + clear_idx_q] <= 8'd0;
          if (clear_idx_q == ({16'd0, imm0_q} - 32'd1)) begin
            retire_instruction();
          end else begin
            clear_idx_q <= clear_idx_q + 32'd1;
          end
        end
        ST_PREP_MATMUL: begin
          for (row_idx = 0; row_idx < ARRAY_M; row_idx++) begin
            for (col_idx = 0; col_idx < ARRAY_K; col_idx++) begin
              tc_a_tile[(row_idx * ARRAY_K) + col_idx] <= vmem_mem[{16'd0, src0_q} + (row_idx * ARRAY_K) + col_idx];
            end
          end
          for (row_idx = 0; row_idx < ARRAY_K; row_idx++) begin
            for (col_idx = 0; col_idx < ARRAY_N; col_idx++) begin
              tc_b_tile[(row_idx * ARRAY_N) + col_idx] <= vmem_mem[{16'd0, src1_q} + (row_idx * ARRAY_N) + col_idx];
            end
          end
          for (row_idx = 0; row_idx < ARRAY_M; row_idx++) begin
            for (col_idx = 0; col_idx < ARRAY_N; col_idx++) begin
              word_addr = {16'd0, dst_q} + (((row_idx * ARRAY_N) + col_idx) * 4);
              tc_c_in[(row_idx * ARRAY_N) + col_idx] <= flags_q[0] ? $signed(read_vmem_word(word_addr[31:0])) : '0;
            end
          end
          state_q <= ST_ISSUE_TC;
        end
        ST_ISSUE_TC: begin
          tc_cmd_q.opcode <= vtpu_pkg::OPC_MATMUL;
          tc_cmd_q.flags <= flags_q;
          tc_cmd_q.target <= target_q;
          tc_cmd_q.dst <= dst_q;
          tc_cmd_q.src0 <= src0_q;
          tc_cmd_q.src1 <= src1_q;
          tc_cmd_q.imm0 <= imm0_q;
          tc_cmd_q.imm1 <= imm1_q;
          tc_cmd_q.imm2 <= imm2_q;
          tc_cmd_valid_q <= 1'b1;
          state_q <= ST_WAIT_TC;
        end
        ST_WAIT_TC: begin
          if (tc_status.error) begin
            set_error(tc_status.error_code);
          end else if (tc_status.done) begin
            write_c_idx_q <= 32'd0;
            state_q <= ST_WRITE_C;
          end
        end
        ST_WRITE_C: begin
          write_vmem_word({16'd0, dst_q} + (write_c_idx_q * 4), tc_c_out[write_c_idx_q]);
          if (write_c_idx_q == ((ARRAY_M * ARRAY_N) - 1)) begin
            retire_instruction();
          end else begin
            write_c_idx_q <= write_c_idx_q + 32'd1;
          end
        end
        ST_HALT: begin
        end
        ST_ERROR: begin
        end
        default: begin
          set_error(vtpu_pkg::ERR_UNSUPPORTED);
        end
      endcase
    end
  end
endmodule
