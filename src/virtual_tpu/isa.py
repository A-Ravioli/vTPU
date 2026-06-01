# virtual tpu instruction set: opcodes, 128-bit encoding, and python helpers to build instructions
from __future__ import annotations  # forward refs in type hints (e.g. Instruction.decode return type)

from dataclasses import dataclass
from enum import IntEnum, IntFlag


class ISAError(ValueError):
    """Raised when an instruction cannot be represented in the custom ISA."""


class Opcode(IntEnum):
    """numeric opcodes — must stay in sync with rtl/vtpu_pkg.sv."""

    NOP = 0x00
    LOAD_TILE = 0x01  # dma alias: load a tile into local memory
    STORE_TILE = 0x02  # dma alias: store a tile back out
    DMA_COPY = 0x03  # explicit copy between address spaces
    MATMUL = 0x04
    VECTOR_OP = 0x05  # elementwise ops on vmem (vadd, relu, ...)
    REDUCE = 0x06  # sum/max over rows/cols/all
    BARRIER = 0x07  # wait until listed units are idle
    INFEED = 0x08  # host -> chip ingress (mvp placeholder)
    OUTFEED = 0x09  # chip -> host egress
    CLEAR = 0x0A  # zero a byte range in one memory space
    CONFIG = 0x0B
    SYNC = 0x0C
    HALT = 0xFF  # end program


class AddressSpace(IntEnum):
    """which memory bank an address refers to (encoded in dma flags or clear flags)."""

    HBM = 0  # high-bandwidth / bulk off-chip style memory
    CMEM = 1  # chip-level staging between hbm and tensor cores
    VMEM0 = 2  # tensor core 0 scratch
    VMEM1 = 3  # tensor core 1 scratch
    INFEED = 4
    OUTFEED = 5


class UnitMask(IntFlag):
    """bitmask for BARRIER: which execution units must finish before continuing."""

    DMA = 1 << 0
    MXU = 1 << 1  # matrix multiply unit
    VPU = 1 << 2  # vector unit
    REDUCE = 1 << 3
    IO = 1 << 4
    ALL_TENSOR_CORES = 1 << 5
    ALL_LOCAL = 1 << 6


class VectorOp(IntEnum):
    """sub-opcode for VECTOR_OP; stored in instruction imm1."""

    VADD = 0
    VMUL = 1
    VSCALE = 2
    VRELU = 3
    VCLAMP = 4
    VMAX = 5


class ReduceOp(IntEnum):
    """sub-opcode for REDUCE; stored in instruction imm1."""

    SUM_ALL = 0
    MAX_ALL = 1
    SUM_ROWS = 2
    MAX_ROWS = 3
    SUM_COLS = 4
    MAX_COLS = 5


# matmul modifier bits packed into the instruction flags byte
MATMUL_FLAG_ACCUMULATE = 1 << 0  # add into existing dst instead of overwrite
MATMUL_FLAG_TRANSPOSE_A = 1 << 1
MATMUL_FLAG_TRANSPOSE_B = 1 << 2
MATMUL_FLAG_SIGNED = 1 << 3  # int8 path (default on in matmul builder)
MATMUL_FLAG_FIXED_POINT = 1 << 4
MATMUL_FLAG_BF16 = 1 << 5
MATMUL_FLAG_SATURATE_STORE = 1 << 6
# Split 2×2: divide the 16×16 PE array into four independent 8×8 sub-arrays.
# m and n encode per-partition dimensions (max 8).  A/B/C tiles are packed contiguously:
# a_tile = [A0 | A1 | A2 | A3]  (each Ap is m×k bytes)
# b_tile = [B0 | B1 | B2 | B3]  (each Bp is k×n bytes)
# c_tile = [C0 | C1 | C2 | C3]  (each Cp is m×n int32 = m*n*4 bytes)
MATMUL_FLAG_SPLIT_2X2 = 1 << 7

SUPPORTED_MATMUL_FLAGS = (
    MATMUL_FLAG_ACCUMULATE | MATMUL_FLAG_SIGNED | MATMUL_FLAG_BF16 | MATMUL_FLAG_SPLIT_2X2
)

# one 128-bit instruction word: (field name, bit shift from lsb, mask)
FIELD_LAYOUT = (
    ("opcode", 120, 0xFF),
    ("flags", 112, 0xFF),
    ("target", 104, 0xFF),  # high nibble: tensor core(s); low nibble: unit(s)
    ("reserved", 96, 0xFF),
    ("dst", 80, 0xFFFF),
    ("src0", 64, 0xFFFF),
    ("src1", 48, 0xFFFF),
    ("imm0", 32, 0xFFFF),  # meaning depends on opcode (length, m, ...)
    ("imm1", 16, 0xFFFF),
    ("imm2", 0, 0xFFFF),
)


@dataclass(frozen=True)
class MemoryRef:
    """pointer to a byte offset inside a specific address space (used by dma_copy / clear)."""

    space: AddressSpace
    addr: int

    def __post_init__(self) -> None:
        object.__setattr__(self, "space", AddressSpace(self.space))  # coerce int -> enum
        _require_range("addr", self.addr, 32)


@dataclass(frozen=True)
class Instruction:
    """decoded instruction fields; pack/unpack into 16 big-endian bytes for sim + rtl."""

    opcode: int
    flags: int = 0
    target: int = 0
    reserved: int = 0
    dst: int = 0
    src0: int = 0
    src1: int = 0
    imm0: int = 0
    imm1: int = 0
    imm2: int = 0

    def __post_init__(self) -> None:
        for name, _shift, mask in FIELD_LAYOUT:
            _require_range(name, getattr(self, name), mask.bit_length())

    @property
    def opcode_enum(self) -> Opcode:
        try:
            return Opcode(self.opcode)
        except ValueError as exc:
            raise ISAError(f"illegal opcode 0x{self.opcode:02x}") from exc

    def encode(self) -> int:
        """pack all fields into a single 128-bit integer (msb = opcode)."""
        value = 0
        for name, shift, mask in FIELD_LAYOUT:
            value |= (getattr(self, name) & mask) << shift
        return value

    def to_bytes(self) -> bytes:
        return self.encode().to_bytes(16, byteorder="big", signed=False)

    def to_hex(self) -> str:
        return f"{self.encode():032x}"

    @classmethod
    def decode(cls, value: int) -> "Instruction":
        _require_range("instruction", value, 128)
        fields = {
            name: (value >> shift) & mask
            for name, shift, mask in FIELD_LAYOUT
        }
        return cls(**fields)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Instruction":
        if len(data) != 16:
            raise ISAError(f"instruction must be 16 bytes, got {len(data)}")
        return cls.decode(int.from_bytes(data, byteorder="big", signed=False))

    @classmethod
    def from_hex(cls, text: str) -> "Instruction":
        cleaned = text.strip().removeprefix("0x").replace("_", "")
        if len(cleaned) > 32:
            raise ISAError("instruction hex is wider than 128 bits")
        return cls.decode(int(cleaned, 16))


def pack_dma_flags(src_space: AddressSpace, dst_space: AddressSpace) -> int:
    """low 3 bits = src space, next 3 bits = dst space (fits in flags byte)."""

    src = AddressSpace(src_space).value
    dst = AddressSpace(dst_space).value
    return src | (dst << 3)


def unpack_dma_flags(flags: int) -> tuple[AddressSpace, AddressSpace]:
    src_raw = flags & 0x7
    dst_raw = (flags >> 3) & 0x7
    try:
        return AddressSpace(src_raw), AddressSpace(dst_raw)
    except ValueError as exc:
        raise ISAError(f"invalid DMA address space in flags 0x{flags:02x}") from exc


def dma_copy(
    *,
    dst: MemoryRef,
    src: MemoryRef,
    length: int,
    opcode: Opcode = Opcode.DMA_COPY,
) -> Instruction:
    """build a dma (or load/store tile alias): copy length bytes src -> dst."""

    if length > 0xFFFF:
        raise ISAError("MVP DMA length must fit imm0")
    if dst.addr > 0xFFFF or src.addr > 0xFFFF:
        raise ISAError("MVP DMA addresses must fit 16-bit instruction fields")
    return Instruction(
        opcode=opcode.value,
        flags=pack_dma_flags(src.space, dst.space),
        dst=dst.addr,
        src0=src.addr,
        imm0=length,
    )


def clear(*, dst: MemoryRef, length: int) -> Instruction:
    """zero length bytes starting at dst (space encoded in flags, not pack_dma_flags)."""

    if length > 0xFFFF:
        raise ISAError("MVP CLEAR length must fit imm0")
    if dst.addr > 0xFFFF:
        raise ISAError("MVP CLEAR address must fit 16-bit instruction field")
    return Instruction(
        opcode=Opcode.CLEAR.value,
        flags=AddressSpace(dst.space).value,
        dst=dst.addr,
        imm0=length,
    )


def matmul(
    *,
    dst_addr: int,
    src_a_addr: int,
    src_b_addr: int,
    m: int,
    n: int,
    k: int,
    target: int = 0x10,  # default tc0; see golden _target_vmem_spaces
    accumulate: bool = False,
    bf16: bool = False,
) -> Instruction:
    """c = a @ b with dimensions m×k and k×n -> m×n; addresses are vmem byte offsets."""

    for name, value in (
        ("dst_addr", dst_addr),
        ("src_a_addr", src_a_addr),
        ("src_b_addr", src_b_addr),
        ("m", m),
        ("n", n),
        ("k", k),
    ):
        if value > 0xFFFF:
            raise ISAError(f"{name} must fit 16 bits in the MVP encoding")
    flags = MATMUL_FLAG_SIGNED
    if accumulate:
        flags |= MATMUL_FLAG_ACCUMULATE
    if bf16:
        flags |= MATMUL_FLAG_BF16
    return Instruction(
        opcode=Opcode.MATMUL.value,
        flags=flags,
        target=target,
        dst=dst_addr,
        src0=src_a_addr,
        src1=src_b_addr,
        imm0=m,
        imm1=n,
        imm2=k,
    )


def barrier(mask: UnitMask | int) -> Instruction:
    """stall until every unit bit set in mask is done (dma, mxu, vpu, ...)."""

    return Instruction(opcode=Opcode.BARRIER.value, imm0=int(mask) & 0xFFFF)


def vector_op(
    *,
    dst_addr: int,
    src0_addr: int,
    src1_addr: int = 0,  # unused for unary ops like vrelu
    length: int,
    op: VectorOp | int,
    target: int = 0x10,
    imm: int = 0,  # extra operand for vscale / vclamp etc.
) -> Instruction:
    """elementwise vector op over length elements in vmem (length often tile-sized)."""

    for name, value in (
        ("dst_addr", dst_addr),
        ("src0_addr", src0_addr),
        ("src1_addr", src1_addr),
        ("length", length),
        ("imm", imm),
    ):
        if value < 0 or value > 0xFFFF:
            raise ISAError(f"{name} must fit 16 bits in the MVP encoding")
    vector_op_value = int(VectorOp(op))
    return Instruction(
        opcode=Opcode.VECTOR_OP.value,
        target=target,
        dst=dst_addr,
        src0=src0_addr,
        src1=src1_addr,
        imm0=length,
        imm1=vector_op_value,
        imm2=imm,
    )


def reduce_op(
    *,
    dst_addr: int,
    src_addr: int,
    length: int,
    op: ReduceOp | int,
    target: int = 0x10,
    columns: int = 0,  # matrix width when reducing rows/cols
) -> Instruction:
    """reduce over a vmem buffer; imm2 holds column count for row/col reductions."""

    for name, value in (
        ("dst_addr", dst_addr),
        ("src_addr", src_addr),
        ("length", length),
        ("columns", columns),
    ):
        if value < 0 or value > 0xFFFF:
            raise ISAError(f"{name} must fit 16 bits in the MVP encoding")
    reduce_op_value = int(ReduceOp(op))
    return Instruction(
        opcode=Opcode.REDUCE.value,
        target=target,
        dst=dst_addr,
        src0=src_addr,
        imm0=length,
        imm1=reduce_op_value,
        imm2=columns,
    )


def split_matmul(
    *,
    dst_addr: int,
    src_a_addr: int,
    src_b_addr: int,
    m: int,
    n: int,
    k: int,
    target: int = 0x10,
    accumulate: bool = False,
) -> Instruction:
    """Four independent m×k @ k×n matmuls packed into one instruction (split 2×2 mode).

    Data layout in VMEM:
      A tiles: [A0 | A1 | A2 | A3] at src_a_addr, each m*k bytes (int8)
      B tiles: [B0 | B1 | B2 | B3] at src_b_addr, each k*n bytes (int8)
      C tiles: [C0 | C1 | C2 | C3] at dst_addr,   each m*n*4 bytes (int32)

    m and n must be <= 8 (half the 16×16 array dimensions).
    """
    if m > 8 or n > 8:
        raise ISAError("split_matmul: m and n must be <= 8 (half the array size)")
    for name, value in (
        ("dst_addr", dst_addr),
        ("src_a_addr", src_a_addr),
        ("src_b_addr", src_b_addr),
        ("m", m),
        ("n", n),
        ("k", k),
    ):
        if value > 0xFFFF:
            raise ISAError(f"{name} must fit 16 bits in the MVP encoding")
    flags = MATMUL_FLAG_SIGNED | MATMUL_FLAG_SPLIT_2X2
    if accumulate:
        flags |= MATMUL_FLAG_ACCUMULATE
    return Instruction(
        opcode=Opcode.MATMUL.value,
        flags=flags,
        target=target,
        dst=dst_addr,
        src0=src_a_addr,
        src1=src_b_addr,
        imm0=m,
        imm1=n,
        imm2=k,
    )


def halt() -> Instruction:
    """stop fetching / executing (program end)."""

    return Instruction(opcode=Opcode.HALT.value)


def _require_range(name: str, value: int, bits: int) -> None:
    if not isinstance(value, int):
        raise ISAError(f"{name} must be an integer")
    if value < 0 or value >= (1 << bits):
        raise ISAError(f"{name}={value} does not fit unsigned {bits}-bit field")
