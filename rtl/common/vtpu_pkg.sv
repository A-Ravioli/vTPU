// shared types and constants for the custom isa — must stay in sync with src/virtual_tpu/isa.py
package vtpu_pkg;
  parameter int VTPU_INSTR_W = 128;
  parameter int VTPU_DATA_W = 8;
  parameter int VTPU_ACC_W = 32;
  parameter int VTPU_VMEM_BANKS = 16;
  parameter int VTPU_HBM_READ_LATENCY = 80;
  parameter int VTPU_HBM_WRITE_LATENCY = 80;
  parameter int VTPU_HBM_BYTES_PER_CYCLE = 32;

  // mmio register map (host accesses these while chip is idle)
  localparam logic [31:0] VTPU_REG_CONTROL = 32'h0000_0000;  // bit0=start, bit1=clear counters
  localparam logic [31:0] VTPU_REG_STATUS = 32'h0000_0004;
  localparam logic [31:0] VTPU_REG_ERROR_CODE = 32'h0000_0008;
  localparam logic [31:0] VTPU_REG_PC = 32'h0000_000C;
  localparam logic [31:0] VTPU_COUNTER_BASE = 32'h0000_0100;  // 64-bit counters, 8 bytes each
  localparam logic [31:0] VTPU_INSTR_BASE = 32'h0000_1000;  // 128-bit program load window
  localparam logic [31:0] VTPU_HBM_BASE = 32'h0010_0000;  // debug peek/poke into hbm

  localparam int VTPU_COUNTER_CYCLES = 0;
  localparam int VTPU_COUNTER_INSTRUCTIONS = 1;
  localparam int VTPU_COUNTER_DMA_BYTES = 2;
  localparam int VTPU_COUNTER_DMA_ACTIVE = 3;
  localparam int VTPU_COUNTER_HBM_STALL = 4;
  localparam int VTPU_COUNTER_CMEM_ACCESSES = 5;
  localparam int VTPU_COUNTER_VMEM_ACCESSES = 6;
  localparam int VTPU_COUNTER_VMEM_BANK_CONFLICTS = 7;
  localparam int VTPU_COUNTER_MXU_ACTIVE = 8;
  localparam int VTPU_COUNTER_VECTOR_ACTIVE = 9;
  localparam int VTPU_COUNTER_REDUCE_ACTIVE = 10;
  localparam int VTPU_COUNTER_BARRIER_WAIT = 11;
  localparam int VTPU_COUNTER_ERRORS = 12;
  localparam int VTPU_COUNTER_TC0_ACTIVE = 13;
  localparam int VTPU_COUNTER_TC1_ACTIVE = 14;
  localparam int VTPU_COUNTER_TC0_MXU0_ACTIVE = 15;
  localparam int VTPU_COUNTER_TC0_MXU1_ACTIVE = 16;
  localparam int VTPU_COUNTER_TC0_MXU2_ACTIVE = 17;
  localparam int VTPU_COUNTER_TC0_MXU3_ACTIVE = 18;
  localparam int VTPU_COUNTER_TC1_MXU0_ACTIVE = 19;
  localparam int VTPU_COUNTER_TC1_MXU1_ACTIVE = 20;
  localparam int VTPU_COUNTER_TC1_MXU2_ACTIVE = 21;
  localparam int VTPU_COUNTER_TC1_MXU3_ACTIVE = 22;
  localparam int VTPU_COUNTER_DMA_IDLE = 23;
  localparam int VTPU_COUNTER_MXU_IDLE = 24;
  localparam int VTPU_COUNTER_VECTOR_IDLE = 25;
  localparam int VTPU_COUNTER_REDUCE_IDLE = 26;
  localparam int VTPU_NUM_COUNTERS = 27;

  // matmul modifier bits in the instruction flags byte
  localparam logic [7:0] MATMUL_FLAG_ACCUMULATE = 8'h01;  // add into existing dst
  localparam logic [7:0] MATMUL_FLAG_SIGNED = 8'h08;
  localparam logic [7:0] MATMUL_FLAG_BF16 = 8'h20;  // simulation bf16 matmul path
  localparam logic [7:0] MATMUL_SUPPORTED_FLAGS = MATMUL_FLAG_ACCUMULATE |
                                                  MATMUL_FLAG_SIGNED |
                                                  MATMUL_FLAG_BF16;

  typedef enum logic [7:0] {
    OPC_NOP        = 8'h00,
    OPC_LOAD_TILE  = 8'h01,  // dma alias: load tile into local memory
    OPC_STORE_TILE = 8'h02,  // dma alias: store tile back out
    OPC_DMA_COPY   = 8'h03,
    OPC_MATMUL     = 8'h04,
    OPC_VECTOR_OP  = 8'h05,  // elementwise ops on vmem
    OPC_REDUCE     = 8'h06,
    OPC_BARRIER    = 8'h07,  // wait until listed units are idle
    OPC_INFEED     = 8'h08,  // host -> chip ingress (mvp placeholder)
    OPC_OUTFEED    = 8'h09,
    OPC_CLEAR      = 8'h0A,  // zero a byte range in one memory space
    OPC_CONFIG     = 8'h0B,
    OPC_SYNC       = 8'h0C,
    OPC_HALT       = 8'hFF
  } opcode_t;

  typedef enum logic [2:0] {
    MEM_HBM    = 3'd0,  // high-bandwidth bulk storage
    MEM_CMEM   = 3'd1,  // chip-level staging between hbm and tensor cores
    MEM_VMEM0  = 3'd2,  // tensor core 0 scratch
    MEM_VMEM1  = 3'd3,  // tensor core 1 scratch
    MEM_INFEED = 3'd4,
    MEM_OUTFEED = 3'd5
  } mem_space_t;

  // raw 128-bit instruction word layout (msb = opcode)
  typedef struct packed {
    logic [7:0]   opcode;
    logic [7:0]   flags;
    logic [7:0]   target;  // high nibble: tensor core(s); low nibble: mxu selector
    logic [7:0]   reserved;
    logic [15:0]  dst;
    logic [15:0]  src0;
    logic [15:0]  src1;
    logic [15:0]  imm0;  // meaning depends on opcode (length, m, ...)
    logic [15:0]  imm1;
    logic [15:0]  imm2;
  } instr_t;

  typedef struct packed {
    opcode_t      opcode;
    logic [7:0]   flags;
    logic [7:0]   target;
    logic [15:0]  dst;
    logic [15:0]  src0;
    logic [15:0]  src1;
    logic [15:0]  imm0;
    logic [15:0]  imm1;
    logic [15:0]  imm2;
  } decoded_instr_t;

  typedef struct packed {
    logic        busy;
    logic        done;
    logic        error;
    logic [7:0]  error_code;
  } unit_status_t;

  typedef enum logic [7:0] {
    ERR_NONE = 8'h00,
    ERR_BAD_OPCODE = 8'h01,
    ERR_BAD_TARGET = 8'h02,
    ERR_BAD_FLAGS = 8'h03,
    ERR_BAD_ADDR = 8'h04,
    ERR_UNALIGNED = 8'h05,
    ERR_BUSY = 8'h06,
    ERR_UNSUPPORTED = 8'h07,
    ERR_TIMEOUT = 8'h08
  } error_code_t;

  typedef struct packed {
    logic [15:0] dst_addr;
    logic [15:0] a_addr;
    logic [15:0] b_addr;
    logic [15:0] m;
    logic [15:0] n;
    logic [15:0] k;
    logic        accumulate;
    logic        bf16;
  } mxu_cmd_t;

  typedef struct packed {
    logic [2:0]  src_space;  // low 3 bits of dma flags
    logic [2:0]  dst_space;  // next 3 bits of dma flags
    logic [31:0] src_addr;
    logic [31:0] dst_addr;
    logic [31:0] len_bytes;
  } dma_cmd_t;

  typedef struct packed {
    logic [7:0]  opcode;
    logic [7:0]  flags;
    logic [7:0]  target;
    logic [15:0] dst;
    logic [15:0] src0;
    logic [15:0] src1;
    logic [15:0] imm0;
    logic [15:0] imm1;
    logic [15:0] imm2;
  } tc_cmd_t;

  typedef struct packed {
    logic [15:0] dst_addr;
    logic [15:0] src0_addr;
    logic [15:0] src1_addr;
    logic [15:0] length;
    logic [7:0]  op;  // vector sub-opcode (vadd, vrelu, ...)
    logic [15:0] imm;
  } vector_cmd_t;

  typedef struct packed {
    logic [15:0] dst_addr;
    logic [15:0] src_addr;
    logic [15:0] length;
    logic [7:0]  op;  // reduce sub-opcode (sum_all, max_rows, ...)
    logic [15:0] columns;  // matrix width for row/col reductions
  } reduce_cmd_t;

  typedef struct packed {
    logic        valid;
    logic        write;
    logic [2:0]  space;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
  } mem_req_t;

  typedef struct packed {
    logic        ready;
    logic        valid;
    logic [31:0] rdata;
    logic        error;
    logic [7:0]  error_code;
  } mem_resp_t;

  typedef struct packed {
    logic        valid;
    logic        write;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
  } vmem_req_t;

  typedef struct packed {
    logic        ready;
    logic        valid;
    logic [31:0] rdata;
    logic        error;
  } vmem_resp_t;

  typedef vmem_req_t vmem_read_req_t;
  typedef vmem_resp_t vmem_read_resp_t;
  typedef vmem_req_t vmem_write_req_t;

  typedef struct packed {
    logic        valid;
    logic        write;
    logic [31:0] addr;
    logic [31:0] wdata;
  } host_req_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] rdata;
    logic        error;
  } host_resp_t;

  // split a 128-bit big-endian instruction word into named fields
  function automatic instr_t unpack_instr(input logic [127:0] raw);
    unpack_instr.opcode   = raw[127:120];
    unpack_instr.flags    = raw[119:112];
    unpack_instr.target   = raw[111:104];
    unpack_instr.reserved = raw[103:96];
    unpack_instr.dst      = raw[95:80];
    unpack_instr.src0     = raw[79:64];
    unpack_instr.src1     = raw[63:48];
    unpack_instr.imm0     = raw[47:32];
    unpack_instr.imm1     = raw[31:16];
    unpack_instr.imm2     = raw[15:0];
  endfunction
endpackage
