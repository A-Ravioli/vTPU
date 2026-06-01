# text assembler: mnemonics + SPACE:ADDR operands -> Instruction list
from __future__ import annotations

from collections.abc import Mapping, Sequence

from virtual_tpu.isa import (  # instruction builders and encoding constants
    AddressSpace,
    ISAError,
    MemoryRef,
    Opcode,
    ReduceOp,
    UnitMask,
    VectorOp,
    barrier,
    clear,
    dma_copy,
    halt,
    matmul,
    reduce_op,
    vector_op,
)


class AssemblerError(ValueError):
    """Raised when assembly source cannot be converted to instructions."""


# human-readable barrier unit names -> UnitMask bits
_BARRIER_NAMES = {
    "DMA": UnitMask.DMA,
    "MXU": UnitMask.MXU,
    "VPU": UnitMask.VPU,
    "REDUCE": UnitMask.REDUCE,
    "IO": UnitMask.IO,
    "INFEED": UnitMask.IO,
    "OUTFEED": UnitMask.IO,
    "ALL_TENSOR_CORES": UnitMask.ALL_TENSOR_CORES,
    "ALL_LOCAL": UnitMask.ALL_LOCAL,
}

_VECTOR_NAMES = {op.name: op for op in VectorOp}
_REDUCE_NAMES = {op.name: op for op in ReduceOp}


def assemble(source: str | Sequence[str], symbols: Mapping[str, int] | None = None) -> list[InstructionLike]:
    """parse assembly text into a list of encoded instructions."""

    lines = source.splitlines() if isinstance(source, str) else list(source)
    instructions: list[InstructionLike] = []
    symbol_table = _collect_symbols(lines, dict(symbols or {}))

    for line_no, raw_line in enumerate(lines, start=1):
        line = _strip_label(raw_line.split("#", 1)[0].strip())
        # skip blank lines and symbol definitions (FOO = 0x100)
        if not line or "=" in line and line.split("=", 1)[0].strip().isidentifier() and line.split("=", 1)[0].strip().isupper():
            continue
        try:
            instructions.append(_assemble_line(line, symbol_table))
        except (AssemblerError, ISAError, KeyError, ValueError) as exc:
            raise AssemblerError(f"line {line_no}: {raw_line.strip()}: {exc}") from exc

    return instructions


def emit_hex(program: Sequence[InstructionLike]) -> str:
    return "\n".join(instr.to_hex() for instr in program)


def debug_listing(program: Sequence[InstructionLike], asm_lines: Sequence[str] | None = None) -> str:
    """pc, hex encoding, and optional source line for each instruction."""

    rows = []
    for pc, instr in enumerate(program):
        asm = "" if asm_lines is None or pc >= len(asm_lines) else asm_lines[pc].strip()
        rows.append(f"{pc:04x}  {instr.to_hex()}  {asm}")
    return "\n".join(rows)


def _assemble_line(line: str, symbols: Mapping[str, int]) -> "InstructionLike":
    normalized = line.replace(",", " ")
    parts = [part for part in normalized.split() if part]
    if not parts:
        raise AssemblerError("empty line")

    mnemonic = parts[0].upper()
    operands = _parse_operands(parts[1:])

    if mnemonic == "NOP":
        return InstructionLike(Opcode.NOP.value)
    if mnemonic == "HALT":
        return halt()
    if mnemonic in {"DMA_COPY", "LOAD_TILE", "STORE_TILE"}:
        dst = _parse_mem_ref(_require_operand(operands, "dst"), symbols)
        src = _parse_mem_ref(_require_operand(operands, "src"), symbols)
        length = _parse_int(_require_operand(operands, "bytes"), symbols)
        opcode = Opcode[mnemonic]
        return dma_copy(dst=dst, src=src, length=length, opcode=opcode)
    if mnemonic == "CLEAR":
        dst = _parse_mem_ref(_require_operand(operands, "dst"), symbols)
        length = _parse_int(_require_operand(operands, "bytes"), symbols)
        return clear(dst=dst, length=length)
    if mnemonic == "MATMUL":
        target = _parse_target(operands.get("target", "TC0.MXU0"))
        dst = _parse_mem_ref(_require_operand(operands, "dst"), symbols)
        src0 = _parse_mem_ref(_require_operand(operands, "src0"), symbols)
        src1 = _parse_mem_ref(_require_operand(operands, "src1"), symbols)
        if dst.space not in {AddressSpace.VMEM0, AddressSpace.VMEM1}:
            raise AssemblerError("MATMUL dst must be VMEM0 or VMEM1 in the MVP")
        if src0.space != dst.space or src1.space != dst.space:
            raise AssemblerError("MATMUL operands must use the same VMEM space in the MVP")
        accumulate = _parse_bool(operands.get("accumulate", "false"))
        bf16 = _parse_bool(operands.get("bf16", "false"))
        instr = matmul(
            dst_addr=dst.addr,
            src_a_addr=src0.addr,
            src_b_addr=src1.addr,
            m=_parse_int(_require_operand(operands, "m"), symbols),
            n=_parse_int(_require_operand(operands, "n"), symbols),
            k=_parse_int(_require_operand(operands, "k"), symbols),
            target=target,
            accumulate=accumulate,
            bf16=bf16,
        )
        return instr
    if mnemonic == "VECTOR_OP":
        target = _parse_target(operands.get("target", "TC0.MXU0"))
        dst = _parse_mem_ref(_require_operand(operands, "dst"), symbols)
        src0 = _parse_mem_ref(_require_operand(operands, "src0"), symbols)
        src1_text = operands.get("src1")
        src1_addr = 0  # unused for unary ops like vrelu
        if src1_text is not None:
            src1_addr = _parse_mem_ref(src1_text, symbols).addr
        op = _parse_vector_op(_require_operand(operands, "op"))
        return vector_op(
            dst_addr=dst.addr,
            src0_addr=src0.addr,
            src1_addr=src1_addr,
            length=_parse_int(_require_operand(operands, "len"), symbols),
            op=op,
            target=target,
            imm=_parse_int(operands.get("imm", "0"), symbols) & 0xFFFF,
        )
    if mnemonic == "REDUCE":
        target = _parse_target(operands.get("target", "TC0.MXU0"))
        dst = _parse_mem_ref(_require_operand(operands, "dst"), symbols)
        src = _parse_mem_ref(_require_operand(operands, "src"), symbols)
        op = _parse_reduce_op(_require_operand(operands, "op"))
        return reduce_op(
            dst_addr=dst.addr,
            src_addr=src.addr,
            length=_parse_int(_require_operand(operands, "len"), symbols),
            op=op,
            target=target,
            columns=_parse_int(operands.get("cols", "0"), symbols),
        )
    if mnemonic == "BARRIER":
        token = operands.get("unit") or operands.get("mask") or operands.get("_0")
        if token is None:
            raise AssemblerError("BARRIER requires a unit name or mask")
        return barrier(_parse_barrier_mask(token, symbols))

    try:
        opcode = Opcode[mnemonic]
    except KeyError as exc:
        raise AssemblerError(f"unknown opcode {mnemonic}") from exc
    return InstructionLike(opcode.value)


def _parse_operands(parts: Sequence[str]) -> dict[str, str]:
    operands: dict[str, str] = {}
    positional = 0
    for part in parts:
        if "=" in part:
            key, value = part.split("=", 1)
            operands[key.lower()] = value
        else:
            operands[f"_{positional}"] = part
            positional += 1
    return operands


def _collect_symbols(lines: Sequence[str], symbols: dict[str, int]) -> dict[str, int]:
    """first pass: collect FOO = addr constants and label: pc mappings."""

    pc = 0
    for raw_line in lines:
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            key = key.strip()
            if key.isidentifier() and key.isupper():
                symbols[key] = _parse_int(value.strip(), symbols)
                continue
        if ":" in line:
            label, remainder = line.split(":", 1)
            if label.strip().isidentifier():
                symbols[label.strip()] = pc
                line = remainder.strip()
        if line:
            pc += 1
    return symbols


def _strip_label(line: str) -> str:
    if ":" in line:
        label, remainder = line.split(":", 1)
        if label.strip().isidentifier():
            return remainder.strip()
    return line


def _require_operand(operands: Mapping[str, str], key: str) -> str:
    try:
        return operands[key]
    except KeyError as exc:
        raise AssemblerError(f"missing operand {key}") from exc


def _parse_mem_ref(text: str, symbols: Mapping[str, int]) -> MemoryRef:
    if ":" not in text:
        raise AssemblerError(f"memory reference must be SPACE:ADDR, got {text}")
    space_text, addr_text = text.split(":", 1)
    try:
        space = AddressSpace[space_text.upper()]
    except KeyError as exc:
        raise AssemblerError(f"unknown address space {space_text}") from exc
    return MemoryRef(space=space, addr=_parse_int(addr_text, symbols))


def _parse_target(text: str) -> int:
    """parse TC0.MXU0 style targets into the 8-bit target byte (high nibble = tc, low = mxu)."""

    upper = text.upper()
    if upper.startswith("0X") or upper.isdigit():
        return int(upper, 0)
    pieces = upper.split(".")
    if len(pieces) != 2 or not pieces[0].startswith("TC"):
        raise AssemblerError(f"target must look like TC0.MXU0, got {text}")
    tc_id = int(pieces[0][2:])
    if tc_id < 0 or tc_id > 3:
        raise AssemblerError("MVP target TensorCore id must be in [0, 3]")
    tc_mask = 1 << tc_id
    unit = pieces[1]
    if unit == "ALL":
        mxu_selector = 0xF  # broadcast to all mxus on this tc
    elif unit.startswith("MXU"):
        mxu_selector = int(unit[3:])
        if mxu_selector < 0 or mxu_selector > 3:
            raise AssemblerError("MVP MXU selector must be in [0, 3]")
    else:
        raise AssemblerError(f"unknown target unit {unit}")
    return (tc_mask << 4) | mxu_selector


def _parse_barrier_mask(text: str, symbols: Mapping[str, int]) -> UnitMask | int:
    upper = text.upper()
    if "|" in upper:
        mask = UnitMask(0)
        for piece in upper.split("|"):
            mask |= _parse_barrier_mask(piece, symbols)
        return mask
    if upper in _BARRIER_NAMES:
        return _BARRIER_NAMES[upper]
    return _parse_int(text, symbols)


def _parse_vector_op(text: str) -> VectorOp:
    upper = text.upper()
    try:
        return _VECTOR_NAMES[upper]
    except KeyError:
        return VectorOp(int(text, 0))


def _parse_reduce_op(text: str) -> ReduceOp:
    upper = text.upper()
    try:
        return _REDUCE_NAMES[upper]
    except KeyError:
        return ReduceOp(int(text, 0))


def _parse_int(text: str, symbols: Mapping[str, int]) -> int:
    if text in symbols:
        return int(symbols[text])
    try:
        return int(text.replace("_", ""), 0)
    except ValueError as exc:
        raise AssemblerError(f"unknown integer or symbol {text}") from exc


def _parse_bool(text: str) -> bool:
    lowered = text.lower()
    if lowered in {"1", "true", "yes", "on"}:
        return True
    if lowered in {"0", "false", "no", "off"}:
        return False
    raise AssemblerError(f"invalid boolean {text}")


from virtual_tpu.isa import Instruction as InstructionLike
