from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum, IntFlag


class ISAError(ValueError):
    """Raised when an instruction cannot be represented in the custom ISA."""


class Opcode(IntEnum):
    NOP = 0x00
    LOAD_TILE = 0x01
    STORE_TILE = 0x02
    DMA_COPY = 0x03
    MATMUL = 0x04
    VECTOR_OP = 0x05
    REDUCE = 0x06
    BARRIER = 0x07
    INFEED = 0x08
    OUTFEED = 0x09
    CLEAR = 0x0A
    CONFIG = 0x0B
    SYNC = 0x0C
    HALT = 0xFF


class AddressSpace(IntEnum):
    HBM = 0
    CMEM = 1
    VMEM0 = 2
    VMEM1 = 3
    INFEED = 4
    OUTFEED = 5


class UnitMask(IntFlag):
    DMA = 1 << 0
    MXU = 1 << 1
    VPU = 1 << 2
    REDUCE = 1 << 3
    IO = 1 << 4
    ALL_TENSOR_CORES = 1 << 5
    ALL_LOCAL = 1 << 6


class VectorOp(IntEnum):
    VADD = 0
    VMUL = 1
    VSCALE = 2
    VRELU = 3
    VCLAMP = 4
    VMAX = 5


class ReduceOp(IntEnum):
    SUM_ALL = 0
    MAX_ALL = 1
    SUM_ROWS = 2
    MAX_ROWS = 3
    SUM_COLS = 4
    MAX_COLS = 5


MATMUL_FLAG_ACCUMULATE = 1 << 0
MATMUL_FLAG_TRANSPOSE_A = 1 << 1
MATMUL_FLAG_TRANSPOSE_B = 1 << 2
MATMUL_FLAG_SIGNED = 1 << 3
MATMUL_FLAG_FIXED_POINT = 1 << 4
MATMUL_FLAG_BF16 = 1 << 5
MATMUL_FLAG_SATURATE_STORE = 1 << 6

SUPPORTED_MATMUL_FLAGS = MATMUL_FLAG_ACCUMULATE | MATMUL_FLAG_SIGNED | MATMUL_FLAG_BF16

FIELD_LAYOUT = (
    ("opcode", 120, 0xFF),
    ("flags", 112, 0xFF),
    ("target", 104, 0xFF),
    ("reserved", 96, 0xFF),
    ("dst", 80, 0xFFFF),
    ("src0", 64, 0xFFFF),
    ("src1", 48, 0xFFFF),
    ("imm0", 32, 0xFFFF),
    ("imm1", 16, 0xFFFF),
    ("imm2", 0, 0xFFFF),
)


@dataclass(frozen=True)
class MemoryRef:
    space: AddressSpace
    addr: int

    def __post_init__(self) -> None:
        object.__setattr__(self, "space", AddressSpace(self.space))
        _require_range("addr", self.addr, 32)


@dataclass(frozen=True)
class Instruction:
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
    target: int = 0x10,
    accumulate: bool = False,
    bf16: bool = False,
) -> Instruction:
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
    return Instruction(opcode=Opcode.BARRIER.value, imm0=int(mask) & 0xFFFF)


def vector_op(
    *,
    dst_addr: int,
    src0_addr: int,
    src1_addr: int = 0,
    length: int,
    op: VectorOp | int,
    target: int = 0x10,
    imm: int = 0,
) -> Instruction:
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
    columns: int = 0,
) -> Instruction:
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


def halt() -> Instruction:
    return Instruction(opcode=Opcode.HALT.value)


def _require_range(name: str, value: int, bits: int) -> None:
    if not isinstance(value, int):
        raise ISAError(f"{name} must be an integer")
    if value < 0 or value >= (1 << bits):
        raise ISAError(f"{name}={value} does not fit unsigned {bits}-bit field")
