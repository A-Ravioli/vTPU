package vtpu_pkg;
  parameter int VTPU_INSTR_W = 128;
  parameter int VTPU_DATA_W = 8;
  parameter int VTPU_ACC_W = 32;
  parameter int VTPU_VMEM_BANKS = 16;
  parameter int VTPU_HBM_READ_LATENCY = 80;
  parameter int VTPU_HBM_WRITE_LATENCY = 80;
  parameter int VTPU_HBM_BYTES_PER_CYCLE = 32;

  localparam logic [7:0] MATMUL_FLAG_ACCUMULATE = 8'h01;
  localparam logic [7:0] MATMUL_FLAG_SIGNED = 8'h08;
  localparam logic [7:0] MATMUL_FLAG_BF16 = 8'h20;
  localparam logic [7:0] MATMUL_SUPPORTED_FLAGS = MATMUL_FLAG_ACCUMULATE |
                                                  MATMUL_FLAG_SIGNED |
                                                  MATMUL_FLAG_BF16;

  typedef enum logic [7:0] {
    OPC_NOP        = 8'h00,
    OPC_LOAD_TILE  = 8'h01,
    OPC_STORE_TILE = 8'h02,
    OPC_DMA_COPY   = 8'h03,
    OPC_MATMUL     = 8'h04,
    OPC_VECTOR_OP  = 8'h05,
    OPC_REDUCE     = 8'h06,
    OPC_BARRIER    = 8'h07,
    OPC_INFEED     = 8'h08,
    OPC_OUTFEED    = 8'h09,
    OPC_CLEAR      = 8'h0A,
    OPC_CONFIG     = 8'h0B,
    OPC_SYNC       = 8'h0C,
    OPC_HALT       = 8'hFF
  } opcode_t;

  typedef enum logic [2:0] {
    MEM_HBM    = 3'd0,
    MEM_CMEM   = 3'd1,
    MEM_VMEM0  = 3'd2,
    MEM_VMEM1  = 3'd3,
    MEM_INFEED = 3'd4,
    MEM_OUTFEED = 3'd5
  } mem_space_t;

  typedef struct packed {
    logic [7:0]   opcode;
    logic [7:0]   flags;
    logic [7:0]   target;
    logic [7:0]   reserved;
    logic [15:0]  dst;
    logic [15:0]  src0;
    logic [15:0]  src1;
    logic [15:0]  imm0;
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
    ERR_UNSUPPORTED = 8'h07
  } error_code_t;

  typedef struct packed {
    logic [15:0] dst_addr;
    logic [15:0] a_addr;
    logic [15:0] b_addr;
    logic [15:0] m;
    logic [15:0] n;
    logic [15:0] k;
    logic        accumulate;
  } mxu_cmd_t;

  typedef struct packed {
    logic [2:0]  src_space;
    logic [2:0]  dst_space;
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
    logic [7:0]  op;
    logic [15:0] imm;
  } vector_cmd_t;

  typedef struct packed {
    logic [15:0] dst_addr;
    logic [15:0] src_addr;
    logic [15:0] length;
    logic [7:0]  op;
    logic [15:0] columns;
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
