# python golden model: fetch-decode-execute loop over instruction programs
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from typing import Sequence

import numpy as np

from virtual_tpu.isa import (  # encoding helpers and matmul flag bits
    ISAError,
    MATMUL_FLAG_ACCUMULATE,
    MATMUL_FLAG_BF16,
    MATMUL_FLAG_SPLIT_2X2,
    MATMUL_FLAG_TRANSPOSE_B,
    SUPPORTED_MATMUL_FLAGS,
    AddressSpace,
    Instruction,
    Opcode,
    ReduceOp,
    VectorOp,
    unpack_dma_flags,
)
from virtual_tpu.memory import MemoryError, MemorySystem
from virtual_tpu.numeric import bf16_matmul, wrap_i32


class ExecutionError(RuntimeError):
    """Raised when the golden model detects an illegal program behavior."""


class HaltReason(Enum):
    RUNNING = auto()
    HALT = auto()
    ERROR = auto()
    TIMEOUT = auto()


@dataclass(frozen=True)
class ExecutionResult:
    """outcome of run(): whether we stopped, why, and where."""

    halted: bool
    reason: HaltReason
    pc: int
    steps: int
    error: str | None = None


@dataclass
class PerformanceCounters:
    """rough activity metrics for layout search and perf analysis."""

    instructions_retired: int = 0
    dma_bytes: int = 0
    mxu_active_cycles: int = 0
    vector_active_cycles: int = 0
    reduce_active_cycles: int = 0
    hbm_stall_cycles: int = 0
    vmem_bank_conflicts: int = 0


@dataclass
class GoldenExecutor:
    """interpret a program against a MemorySystem; one instruction per step()."""

    program: Sequence[Instruction]
    memory: MemorySystem
    pc: int = 0
    halted: bool = False
    error: str | None = None
    counters: PerformanceCounters | None = None

    def __post_init__(self) -> None:
        if self.counters is None:
            self.counters = PerformanceCounters()

    def run(self, max_steps: int = 10_000) -> ExecutionResult:
        """execute until halt, error, or step limit."""

        steps = 0
        while not self.halted and steps < max_steps:
            self.step()
            steps += 1
        if self.halted and self.error is None:
            return ExecutionResult(True, HaltReason.HALT, self.pc, steps)
        if self.halted:
            return ExecutionResult(True, HaltReason.ERROR, self.pc, steps, self.error)
        return ExecutionResult(False, HaltReason.TIMEOUT, self.pc, steps, "program timed out")

    def step(self) -> None:
        if self.halted:
            return
        if self.pc < 0 or self.pc >= len(self.program):
            self._fail(f"pc {self.pc} outside program")
            return

        instr = self.program[self.pc]
        try:
            opcode = instr.opcode_enum
            if opcode == Opcode.NOP:
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode in {Opcode.DMA_COPY, Opcode.LOAD_TILE, Opcode.STORE_TILE}:
                self._execute_dma(instr)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode == Opcode.CLEAR:
                self._execute_clear(instr)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode == Opcode.MATMUL:
                self._execute_matmul(instr)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode == Opcode.VECTOR_OP:
                self._execute_vector_op(instr)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode == Opcode.REDUCE:
                self._execute_reduce(instr)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode in {Opcode.BARRIER, Opcode.SYNC}:
                # mvp golden model treats barriers as no-ops (sync is assumed immediate)
                self.counters.instructions_retired += 1
                self.pc += 1
            elif opcode == Opcode.HALT:
                self.halted = True
                self.counters.instructions_retired += 1
                self.pc += 1
            else:
                self._fail(f"opcode {opcode.name} is not implemented in the MVP golden model")
        except (ISAError, MemoryError, ExecutionError, ValueError) as exc:
            self._fail(str(exc))

    def _execute_dma(self, instr: Instruction) -> None:
        src_space, dst_space = unpack_dma_flags(instr.flags)
        length = instr.imm0
        # 32-bit addresses: low 16 bits in src0/dst, high 16 bits in imm2/imm1.
        src_addr = (instr.imm2 << 16) | instr.src0
        dst_addr = (instr.imm1 << 16) | instr.dst
        self._require_aligned(src_addr, dst_addr, length)
        if length == 0:
            return
        payload = self.memory.read(src_space, src_addr, length)
        self.memory.write(dst_space, dst_addr, payload)
        self.counters.dma_bytes += length
        if src_space == AddressSpace.HBM or dst_space == AddressSpace.HBM:
            self.counters.hbm_stall_cycles += 80 + ((length + 31) // 32)  # rough hbm latency model

    def _execute_clear(self, instr: Instruction) -> None:
        try:
            dst_space = AddressSpace(instr.flags & 0x7)  # low 3 bits = address space (not dma flags)
        except ValueError as exc:
            raise ExecutionError(f"invalid CLEAR address space {instr.flags & 0x7}") from exc
        self._require_aligned(instr.dst, 0, instr.imm0)
        self.memory.clear(dst_space, instr.dst, instr.imm0)

    def _execute_matmul(self, instr: Instruction) -> None:
        unsupported = instr.flags & ~SUPPORTED_MATMUL_FLAGS
        if unsupported:
            raise ExecutionError(f"unsupported MATMUL flags 0x{unsupported:02x}")
        if instr.imm0 == 0 or instr.imm1 == 0 or instr.imm2 == 0:
            raise ExecutionError("MATMUL dimensions must be nonzero")
        m, n, k = instr.imm0, instr.imm1, instr.imm2
        if instr.flags & MATMUL_FLAG_SPLIT_2X2:
            self._execute_split_matmul(instr, m, n, k)
            return
        for vmem_space in self._target_vmem_spaces(instr.target):
            self.counters.mxu_active_cycles += k
            transpose_b = bool(instr.flags & MATMUL_FLAG_TRANSPOSE_B)
            if instr.flags & MATMUL_FLAG_BF16:
                a_bf16 = self.memory.read_u16_matrix(vmem_space, instr.src0, m, k)
                if transpose_b:  # B stored [n][k]; transpose to [k][n]
                    b_bf16 = self.memory.read_u16_matrix(vmem_space, instr.src1, n, k).T
                else:
                    b_bf16 = self.memory.read_u16_matrix(vmem_space, instr.src1, k, n)
                c_result = bf16_matmul(a_bf16, b_bf16)
                if instr.flags & MATMUL_FLAG_ACCUMULATE:
                    c_result = c_result + self.memory.read_f32_matrix(vmem_space, instr.dst, m, n)
                self.memory.write_f32_matrix(vmem_space, instr.dst, c_result.astype(np.float32))
                continue

            a = self.memory.read_i8_matrix(vmem_space, instr.src0, m, k).astype(np.int64)
            if transpose_b:
                b = self.memory.read_i8_matrix(vmem_space, instr.src1, n, k).T.astype(np.int64)
            else:
                b = self.memory.read_i8_matrix(vmem_space, instr.src1, k, n).astype(np.int64)
            if instr.flags & MATMUL_FLAG_ACCUMULATE:
                c_base = self.memory.read_i32_matrix(vmem_space, instr.dst, m, n).astype(np.int64)
            else:
                c_base = np.zeros((m, n), dtype=np.int64)

            result = wrap_i32(c_base + (a @ b))
            self.memory.write_i32_matrix(vmem_space, instr.dst, result)

    def _execute_split_matmul(self, instr: Instruction, m: int, n: int, k: int) -> None:
        """Four independent m×k @ k×n matmuls on the split 2×2 array.

        Data layout in VMEM (contiguous packed tiles):
          A tiles: src_a, src_a + m*k, src_a + 2*m*k, src_a + 3*m*k  (int8)
          B tiles: src_b, src_b + k*n, src_b + 2*k*n, src_b + 3*k*n  (int8)
          C tiles: dst,   dst + m*n*4, dst + 2*m*n*4, dst + 3*m*n*4  (int32)

        Hardware executes all four partitions concurrently; the golden model runs them
        sequentially for simplicity while producing identical outputs.
        """
        if m > 8 or n > 8:
            raise ExecutionError("SPLIT_2X2 matmul: m and n must be <= 8")
        a_stride = m * k           # bytes per A tile (int8)
        b_stride = k * n           # bytes per B tile (int8)
        c_stride = m * n * 4      # bytes per C tile (int32)
        for vmem_space in self._target_vmem_spaces(instr.target):
            # All 4 partitions run in parallel on hardware; active cycles = k (not 4*k)
            self.counters.mxu_active_cycles += k
            for p in range(4):
                a_addr = instr.src0 + p * a_stride
                b_addr = instr.src1 + p * b_stride
                c_addr = instr.dst  + p * c_stride
                a = self.memory.read_i8_matrix(vmem_space, a_addr, m, k).astype(np.int64)
                b = self.memory.read_i8_matrix(vmem_space, b_addr, k, n).astype(np.int64)
                if instr.flags & MATMUL_FLAG_ACCUMULATE:
                    c_base = self.memory.read_i32_matrix(vmem_space, c_addr, m, n).astype(np.int64)
                else:
                    c_base = np.zeros((m, n), dtype=np.int64)
                result = wrap_i32(c_base + (a @ b))
                self.memory.write_i32_matrix(vmem_space, c_addr, result)

    def _execute_vector_op(self, instr: Instruction) -> None:
        if instr.imm0 == 0:
            raise ExecutionError("VECTOR_OP length must be nonzero")
        self.counters.vector_active_cycles += max(1, (instr.imm0 + 15) // 16)  # ~16 elements per cycle
        op = VectorOp(instr.imm1)
        length = instr.imm0
        if int(op) >= int(VectorOp.FADD):
            self._execute_vector_fp(instr, op, length)
            return
        for vmem_space in self._target_vmem_spaces(instr.target):
            src0 = self.memory.read_i32_vector(vmem_space, instr.src0, length).astype(np.int64)

            if op == VectorOp.VADD:
                src1 = self.memory.read_i32_vector(vmem_space, instr.src1, length).astype(np.int64)
                result = src0 + src1
            elif op == VectorOp.VMUL:
                src1 = self.memory.read_i32_vector(vmem_space, instr.src1, length).astype(np.int64)
                result = src0 * src1
            elif op == VectorOp.VSCALE:
                result = src0 * np.int64(_sign_extend_16(instr.imm2))
            elif op == VectorOp.VRELU:
                result = np.maximum(src0, 0)
            elif op == VectorOp.VCLAMP:
                limit = abs(_sign_extend_16(instr.imm2))
                result = np.clip(src0, -limit, limit)
            elif op == VectorOp.VMAX:
                src1 = self.memory.read_i32_vector(vmem_space, instr.src1, length).astype(np.int64)
                result = np.maximum(src0, src1)
            else:
                raise ExecutionError(f"unsupported VECTOR_OP {op}")
            self.memory.write_i32_vector(vmem_space, instr.dst, wrap_i32(result))

    def _execute_vector_fp(self, instr: Instruction, op: VectorOp, length: int) -> None:
        """fp32 elementwise / unary vector ops (ideal-math reference for the RTL fp fabric)."""
        if op == VectorOp.FQUANT_BF16:
            from virtual_tpu.numeric import float32_to_bf16
            for vmem_space in self._target_vmem_spaces(instr.target):
                src = self.memory.read_f32_vector(vmem_space, instr.src0, length).astype(np.float32)
                bits = float32_to_bf16(src)  # uint16, packed little-endian 2-per-word
                self.memory.write(vmem_space, instr.dst, np.asarray(bits, dtype="<u2").tobytes())
            return
        for vmem_space in self._target_vmem_spaces(instr.target):
            src0 = self.memory.read_f32_vector(vmem_space, instr.src0, length).astype(np.float32)
            if op == VectorOp.FADD:
                src1 = self.memory.read_f32_vector(vmem_space, instr.src1, length).astype(np.float32)
                result = src0 + src1
            elif op == VectorOp.FMUL:
                src1 = self.memory.read_f32_vector(vmem_space, instr.src1, length).astype(np.float32)
                result = src0 * src1
            elif op == VectorOp.FMAX:
                src1 = self.memory.read_f32_vector(vmem_space, instr.src1, length).astype(np.float32)
                result = np.maximum(src0, src1)
            elif op == VectorOp.FEXP:
                result = np.exp(src0)
            elif op == VectorOp.FRECIP:
                result = np.float32(1.0) / src0
            elif op == VectorOp.FRSQRT:
                result = np.float32(1.0) / np.sqrt(src0)
            elif op == VectorOp.FSIGMOID:
                result = np.float32(1.0) / (np.float32(1.0) + np.exp(-src0))
            elif op == VectorOp.FSILU:
                result = src0 * (np.float32(1.0) / (np.float32(1.0) + np.exp(-src0)))
            elif op == VectorOp.FSCALE_BCAST:
                scalar = self.memory.read_f32_vector(vmem_space, instr.src1, 1).astype(np.float32)[0]
                result = src0 * scalar
            else:
                raise ExecutionError(f"unsupported fp VECTOR_OP {op}")
            self.memory.write_f32_vector(vmem_space, instr.dst, result.astype(np.float32))

    def _execute_reduce_fp(self, instr: Instruction, op: ReduceOp, length: int) -> None:
        """fp32 reductions (ideal-math reference for the RTL fp fabric)."""
        for vmem_space in self._target_vmem_spaces(instr.target):
            values = self.memory.read_f32_vector(vmem_space, instr.src0, length).astype(np.float32)
            if op == ReduceOp.FSUM_ALL:
                result = np.array([values.sum(dtype=np.float32)], dtype=np.float32)
            elif op == ReduceOp.FMAX_ALL:
                result = np.array([values.max()], dtype=np.float32)
            elif op == ReduceOp.FSUMSQ_ALL:
                result = np.array([(values * values).sum(dtype=np.float32)], dtype=np.float32)
            else:
                columns = instr.imm2
                if columns == 0 or length % columns != 0:
                    raise ExecutionError("row fp REDUCE requires imm0=rows*cols and nonzero imm2 columns")
                matrix = values.reshape(length // columns, columns)
                if op == ReduceOp.FSUM_ROWS:
                    result = matrix.sum(axis=1, dtype=np.float32)
                elif op == ReduceOp.FMAX_ROWS:
                    result = matrix.max(axis=1)
                else:
                    raise ExecutionError(f"unsupported fp REDUCE {op}")
            self.memory.write_f32_vector(vmem_space, instr.dst, result.astype(np.float32))

    def _execute_reduce(self, instr: Instruction) -> None:
        if instr.imm0 == 0:
            raise ExecutionError("REDUCE length must be nonzero")
        self.counters.reduce_active_cycles += max(1, (instr.imm0 + 15) // 16)
        op = ReduceOp(instr.imm1)
        length = instr.imm0
        if int(op) >= int(ReduceOp.FSUM_ALL):
            self._execute_reduce_fp(instr, op, length)
            return

        for vmem_space in self._target_vmem_spaces(instr.target):
            if op in {ReduceOp.SUM_ALL, ReduceOp.MAX_ALL}:
                values = self.memory.read_i32_vector(vmem_space, instr.src0, length).astype(np.int64)
                result = np.array([values.sum() if op == ReduceOp.SUM_ALL else values.max()], dtype=np.int64)
            else:
                columns = instr.imm2
                if columns == 0 or length % columns != 0:
                    raise ExecutionError("row/column REDUCE requires imm0 rows*columns and nonzero imm2 columns")
                matrix = self.memory.read_i32_vector(vmem_space, instr.src0, length).astype(np.int64).reshape(length // columns, columns)
                if op == ReduceOp.SUM_ROWS:
                    result = matrix.sum(axis=1)
                elif op == ReduceOp.MAX_ROWS:
                    result = matrix.max(axis=1)
                elif op == ReduceOp.SUM_COLS:
                    result = matrix.sum(axis=0)
                elif op == ReduceOp.MAX_COLS:
                    result = matrix.max(axis=0)
                else:
                    raise ExecutionError(f"unsupported REDUCE {op}")
            self.memory.write_i32_vector(vmem_space, instr.dst, wrap_i32(result))

    def _target_vmem_spaces(self, target: int) -> list[AddressSpace]:
        """decode target byte: high nibble = tensor core(s), low nibble = mxu selector (unused here)."""

        tc_mask = (target >> 4) & 0xF
        unit_mask = target & 0xF
        if unit_mask > 0xF:
            raise ExecutionError(f"invalid unit target 0x{target:02x}")
        spaces: list[AddressSpace] = []
        if tc_mask & 0x1:
            spaces.append(AddressSpace.VMEM0)
        if tc_mask & 0x2:
            spaces.append(AddressSpace.VMEM1)
        if tc_mask & ~0x3:
            raise ExecutionError(f"golden model supports TC0/TC1 targets, got 0x{target:02x}")
        if not spaces:
            raise ExecutionError(f"target selects no TensorCore, got 0x{target:02x}")
        return spaces

    def _require_aligned(self, *values: int) -> None:
        for value in values:
            if value % 4 != 0:
                raise ExecutionError(f"DMA/CLEAR value {value} is not 4-byte aligned")

    def _fail(self, message: str) -> None:
        self.error = message
        self.halted = True


def _sign_extend_16(value: int) -> int:
    """treat imm2 as a signed 16-bit immediate for vscale / vclamp."""

    return value - 0x10000 if value & 0x8000 else value
