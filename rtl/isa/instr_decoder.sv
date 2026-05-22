// Module: instr_decoder
// Purpose: Decode and validate the custom 128-bit educational instruction format.
// Public TPU inspiration: TPU-like accelerators use explicit instruction/control streams.
// Educational simplification: Validation is architectural, while bounds are checked by target units.
// Inputs: raw 128-bit instruction.
// Outputs: decoded instruction, illegal flag, and stable error code.
// State: Combinational.
// Latency: Zero cycles.
// Backpressure: None.
// Error behavior: illegal is high for unknown opcode, reserved bits, bad spaces, bad flags, or bad targets.
module instr_decoder (
  input  logic [127:0] instr_raw,
  output vtpu_pkg::decoded_instr_t decoded,
  output logic illegal,
  output logic [7:0] error_code
);
  vtpu_pkg::instr_t unpacked;
  logic opcode_known;
  logic target_required;
  logic target_ok;
  logic dma_spaces_ok;
  logic clear_space_ok;
  logic matmul_flags_ok;
  logic matmul_dims_ok;
  logic vector_ok;
  logic reduce_ok;

  function automatic logic local_mem_space_ok(input logic [2:0] space);
    local_mem_space_ok = (space == vtpu_pkg::MEM_CMEM) ||
                         (space == vtpu_pkg::MEM_VMEM0) ||
                         (space == vtpu_pkg::MEM_VMEM1);
  endfunction

  function automatic logic dma_mem_space_ok(input logic [2:0] space);
    dma_mem_space_ok = (space == vtpu_pkg::MEM_HBM) ||
                       (space == vtpu_pkg::MEM_CMEM) ||
                       (space == vtpu_pkg::MEM_VMEM0) ||
                       (space == vtpu_pkg::MEM_VMEM1);
  endfunction

  always_comb begin
    unpacked = vtpu_pkg::unpack_instr(instr_raw);
    decoded.opcode = vtpu_pkg::opcode_t'(unpacked.opcode);
    decoded.flags = unpacked.flags;
    decoded.target = unpacked.target;
    decoded.dst = unpacked.dst;
    decoded.src0 = unpacked.src0;
    decoded.src1 = unpacked.src1;
    decoded.imm0 = unpacked.imm0;
    decoded.imm1 = unpacked.imm1;
    decoded.imm2 = unpacked.imm2;

    unique case (unpacked.opcode)
      vtpu_pkg::OPC_NOP,
      vtpu_pkg::OPC_LOAD_TILE,
      vtpu_pkg::OPC_STORE_TILE,
      vtpu_pkg::OPC_DMA_COPY,
      vtpu_pkg::OPC_MATMUL,
      vtpu_pkg::OPC_VECTOR_OP,
      vtpu_pkg::OPC_REDUCE,
      vtpu_pkg::OPC_BARRIER,
      vtpu_pkg::OPC_CLEAR,
      vtpu_pkg::OPC_SYNC,
      vtpu_pkg::OPC_HALT: opcode_known = 1'b1;
      default: opcode_known = 1'b0;
    endcase

    target_required = (unpacked.opcode == vtpu_pkg::OPC_MATMUL) ||
                      (unpacked.opcode == vtpu_pkg::OPC_VECTOR_OP) ||
                      (unpacked.opcode == vtpu_pkg::OPC_REDUCE);
    target_ok = !target_required ||
                ((unpacked.target[7:6] == 2'b00) && (unpacked.target[5:4] != 2'b00));

    dma_spaces_ok = !((unpacked.opcode == vtpu_pkg::OPC_LOAD_TILE) ||
                      (unpacked.opcode == vtpu_pkg::OPC_STORE_TILE) ||
                      (unpacked.opcode == vtpu_pkg::OPC_DMA_COPY)) ||
                    (dma_mem_space_ok(unpacked.flags[2:0]) &&
                     dma_mem_space_ok(unpacked.flags[5:3]));

    clear_space_ok = (unpacked.opcode != vtpu_pkg::OPC_CLEAR) ||
                     ((unpacked.flags[7:3] == 5'd0) && local_mem_space_ok(unpacked.flags[2:0]));

    matmul_flags_ok = (unpacked.opcode != vtpu_pkg::OPC_MATMUL) ||
                      ((unpacked.flags & ~vtpu_pkg::MATMUL_SUPPORTED_FLAGS) == 8'h00);
    matmul_dims_ok = (unpacked.opcode != vtpu_pkg::OPC_MATMUL) ||
                     ((unpacked.imm0 != 16'd0) &&
                      (unpacked.imm1 != 16'd0) &&
                      (unpacked.imm2 != 16'd0));

    vector_ok = (unpacked.opcode != vtpu_pkg::OPC_VECTOR_OP) ||
                ((unpacked.imm1 <= 16'd5) && (unpacked.imm0 != 16'd0));
    reduce_ok = (unpacked.opcode != vtpu_pkg::OPC_REDUCE) ||
                ((unpacked.imm1 <= 16'd5) &&
                 (unpacked.imm0 != 16'd0) &&
                 ((unpacked.imm1 <= 16'd1) || (unpacked.imm2 != 16'd0)));

    illegal = !opcode_known ||
              (unpacked.reserved != 8'h00) ||
              !target_ok ||
              !dma_spaces_ok ||
              !clear_space_ok ||
              !matmul_flags_ok ||
              !matmul_dims_ok ||
              !vector_ok ||
              !reduce_ok;

    if (!opcode_known) begin
      error_code = vtpu_pkg::ERR_BAD_OPCODE;
    end else if (unpacked.reserved != 8'h00) begin
      error_code = vtpu_pkg::ERR_UNSUPPORTED;
    end else if (!target_ok) begin
      error_code = vtpu_pkg::ERR_BAD_TARGET;
    end else if (!dma_spaces_ok || !clear_space_ok) begin
      error_code = vtpu_pkg::ERR_UNSUPPORTED;
    end else if (!matmul_flags_ok) begin
      error_code = vtpu_pkg::ERR_BAD_FLAGS;
    end else if (!matmul_dims_ok || !vector_ok || !reduce_ok) begin
      error_code = vtpu_pkg::ERR_UNSUPPORTED;
    end else begin
      error_code = vtpu_pkg::ERR_NONE;
    end
  end
endmodule
