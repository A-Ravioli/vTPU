# byte-addressable memory banks for the golden model (hbm, cmem, vmem, infeed/outfeed)
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from virtual_tpu.isa import AddressSpace


class MemoryError(ValueError):
    """Raised for deterministic memory model violations."""


@dataclass
class ByteMemory:
    """single contiguous byte array with bounds-checked read/write/clear."""

    name: str
    size_bytes: int
    data: bytearray = field(init=False)

    def __post_init__(self) -> None:
        if self.size_bytes <= 0:
            raise MemoryError(f"{self.name} size must be positive")
        self.data = bytearray(self.size_bytes)

    def read(self, addr: int, length: int) -> bytes:
        self._check_range(addr, length)
        return bytes(self.data[addr : addr + length])

    def write(self, addr: int, payload: bytes | bytearray | memoryview) -> None:
        length = len(payload)
        self._check_range(addr, length)
        self.data[addr : addr + length] = payload

    def clear(self, addr: int, length: int) -> None:
        self._check_range(addr, length)
        self.data[addr : addr + length] = b"\x00" * length

    def _check_range(self, addr: int, length: int) -> None:
        if addr < 0 or length < 0:
            raise MemoryError(f"{self.name}: negative address or length")
        if addr + length > self.size_bytes:
            raise MemoryError(
                f"{self.name}: access [{addr}, {addr + length}) exceeds {self.size_bytes} bytes"
            )


@dataclass
class MemorySystem:
    """all address spaces the simulator can access; sizes match typical mvp defaults."""

    hbm_bytes: int = 16 * 1024 * 1024  # bulk off-chip style storage
    cmem_bytes: int = 512 * 1024  # chip-level staging between hbm and tensor cores
    vmem_bytes: int = 256 * 1024  # per-tensor-core scratch
    hbm: ByteMemory = field(init=False)
    cmem: ByteMemory = field(init=False)
    vmem0: ByteMemory = field(init=False)
    vmem1: ByteMemory = field(init=False)
    infeed: ByteMemory = field(init=False)
    outfeed: ByteMemory = field(init=False)

    def __post_init__(self) -> None:
        self.hbm = ByteMemory("HBM", self.hbm_bytes)
        self.cmem = ByteMemory("CMEM", self.cmem_bytes)
        self.vmem0 = ByteMemory("VMEM0", self.vmem_bytes)
        self.vmem1 = ByteMemory("VMEM1", self.vmem_bytes)
        self.infeed = ByteMemory("INFEED", 256 * 4)  # host ingress buffer (mvp placeholder)
        self.outfeed = ByteMemory("OUTFEED", 256 * 4)

    def memory(self, space: AddressSpace | int) -> ByteMemory:
        """resolve an address-space enum to the backing byte array."""
        match AddressSpace(space):
            case AddressSpace.HBM:
                return self.hbm
            case AddressSpace.CMEM:
                return self.cmem
            case AddressSpace.VMEM0:
                return self.vmem0
            case AddressSpace.VMEM1:
                return self.vmem1
            case AddressSpace.INFEED:
                return self.infeed
            case AddressSpace.OUTFEED:
                return self.outfeed

    def read(self, space: AddressSpace | int, addr: int, length: int) -> bytes:
        return self.memory(space).read(addr, length)

    def write(self, space: AddressSpace | int, addr: int, payload: bytes | bytearray | memoryview) -> None:
        self.memory(space).write(addr, payload)

    def clear(self, space: AddressSpace | int, addr: int, length: int) -> None:
        self.memory(space).clear(addr, length)

    def write_i8_matrix(self, space: AddressSpace | int, addr: int, matrix: np.ndarray) -> None:
        """store a row-major int8 matrix as raw bytes (matmul operand tiles)."""
        array = np.asarray(matrix, dtype=np.int8, order="C")
        self.write(space, addr, array.tobytes(order="C"))

    def read_i8_matrix(self, space: AddressSpace | int, addr: int, rows: int, cols: int) -> np.ndarray:
        payload = self.read(space, addr, rows * cols)
        return np.frombuffer(payload, dtype=np.int8).reshape(rows, cols).copy()

    def write_i32_matrix(self, space: AddressSpace | int, addr: int, matrix: np.ndarray) -> None:
        """store a row-major int32 matrix (matmul accumulators / vector data)."""
        array = np.asarray(matrix, dtype=np.int32, order="C")
        self.write(space, addr, array.tobytes(order="C"))

    def read_i32_matrix(self, space: AddressSpace | int, addr: int, rows: int, cols: int) -> np.ndarray:
        payload = self.read(space, addr, rows * cols * 4)
        return np.frombuffer(payload, dtype=np.int32).reshape(rows, cols).copy()

    def write_i32_vector(self, space: AddressSpace | int, addr: int, vector: np.ndarray) -> None:
        array = np.asarray(vector, dtype=np.int32, order="C")
        self.write(space, addr, array.tobytes(order="C"))

    def read_i32_vector(self, space: AddressSpace | int, addr: int, length: int) -> np.ndarray:
        payload = self.read(space, addr, length * 4)
        return np.frombuffer(payload, dtype=np.int32).copy()

    def write_u16_matrix(self, space: AddressSpace | int, addr: int, matrix: np.ndarray) -> None:
        """store bf16 tiles as raw uint16 (hardware bit pattern)."""
        array = np.asarray(matrix, dtype=np.uint16, order="C")
        self.write(space, addr, array.tobytes(order="C"))

    def read_u16_matrix(self, space: AddressSpace | int, addr: int, rows: int, cols: int) -> np.ndarray:
        payload = self.read(space, addr, rows * cols * 2)
        return np.frombuffer(payload, dtype=np.uint16).reshape(rows, cols).copy()

    def write_f32_matrix(self, space: AddressSpace | int, addr: int, matrix: np.ndarray) -> None:
        """store float32 results (bf16 matmul path)."""
        array = np.asarray(matrix, dtype=np.float32, order="C")
        self.write(space, addr, array.tobytes(order="C"))

    def read_f32_matrix(self, space: AddressSpace | int, addr: int, rows: int, cols: int) -> np.ndarray:
        payload = self.read(space, addr, rows * cols * 4)
        return np.frombuffer(payload, dtype=np.float32).reshape(rows, cols).copy()
