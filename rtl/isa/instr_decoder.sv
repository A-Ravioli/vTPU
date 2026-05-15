// Module: instr_decoder
// Purpose: Decode the custom 128-bit educational instruction format.
// Public TPU inspiration: TPU-like accelerators use explicit instruction/control streams.
// Educational simplification: This decoder recognizes only the custom public-derived MVP ISA.
// Inputs: raw 128-bit instruction.
// Outputs: decoded instruction and illegal flag.
// State: Combinational.
// Latency: Zero cycles.
// Backpressure: None.
// Error behavior: illegal is high for unknown opcode, reserved bits, unsupported MATMUL flags, or bad target.
// Tests: Python ISA tests validate the same encoding.
module instr_decoder (
  input  logic [127:0] instr_raw,
  output vtpu_pkg::decoded_instr_t decoded,
  output logic illegal
);
  vtpu_pkg::instr_t unpacked;
  logic opcode_known;
  logic matmul_flags_ok;
  logic target_ok;
  logic mem_flags_ok;

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
      vtpu_pkg::OPC_BARRIER,
      vtpu_pkg::OPC_CLEAR,
      vtpu_pkg::OPC_SYNC,
      vtpu_pkg::OPC_HALT: opcode_known = 1'b1;
      default: opcode_known = 1'b0;
    endcase

    matmul_flags_ok = (unpacked.opcode != vtpu_pkg::OPC_MATMUL) ||
                      ((unpacked.flags & 8'h76) == 8'h00);
    target_ok = (unpacked.opcode != vtpu_pkg::OPC_MATMUL) ||
                (unpacked.target == 8'h10);
    mem_flags_ok = !((unpacked.opcode inside {
                      vtpu_pkg::OPC_LOAD_TILE,
                      vtpu_pkg::OPC_STORE_TILE,
                      vtpu_pkg::OPC_DMA_COPY
                    }) && ((unpacked.flags[2:0] > 3'd5) || (unpacked.flags[5:3] > 3'd5)));

    illegal = !opcode_known ||
              (unpacked.reserved != 8'h00) ||
              !matmul_flags_ok ||
              !target_ok ||
              !mem_flags_ok;
  end
endmodule
