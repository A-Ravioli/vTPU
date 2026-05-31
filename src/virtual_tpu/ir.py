# minimal graph ir for compiler: tensors plus matmul/relu/add ops
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


DType = Literal["int8", "int32", "bf16"]
MemoryName = Literal["HBM", "CMEM", "VMEM0", "VMEM1"]


@dataclass(frozen=True)
class Tensor:
    """named buffer with shape, dtype, and preferred memory bank."""

    name: str
    shape: tuple[int, ...]
    dtype: DType
    memory: MemoryName = "HBM"


@dataclass(frozen=True)
class MatMul:
    """2d matrix multiply: out = lhs @ rhs."""

    lhs: Tensor
    rhs: Tensor
    out: Tensor


@dataclass(frozen=True)
class Relu:
    """elementwise relu: out = max(0, src)."""

    src: Tensor
    out: Tensor


@dataclass(frozen=True)
class Add:
    """elementwise add: out = lhs + rhs."""

    lhs: Tensor
    rhs: Tensor
    out: Tensor


def matmul(lhs: Tensor, rhs: Tensor, name: str = "matmul_out") -> MatMul:
    """build a matmul node; output is int32 in the same memory as lhs."""

    if len(lhs.shape) != 2 or len(rhs.shape) != 2:
        raise ValueError("matmul tensors must be rank-2")
    if lhs.shape[1] != rhs.shape[0]:
        raise ValueError("matmul inner dimensions do not match")
    out = Tensor(name=name, shape=(lhs.shape[0], rhs.shape[1]), dtype="int32", memory=lhs.memory)
    return MatMul(lhs=lhs, rhs=rhs, out=out)


def relu(src: Tensor, name: str = "relu_out") -> Relu:
    return Relu(src=src, out=Tensor(name=name, shape=src.shape, dtype=src.dtype, memory=src.memory))


def add(lhs: Tensor, rhs: Tensor, name: str = "add_out") -> Add:
    if lhs.shape != rhs.shape:
        raise ValueError("add tensors must have identical shapes")
    return Add(lhs=lhs, rhs=rhs, out=Tensor(name=name, shape=lhs.shape, dtype=lhs.dtype, memory=lhs.memory))
