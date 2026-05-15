from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Allocation:
    name: str
    offset: int
    size: int


@dataclass
class LinearMemoryPlanner:
    alignment: int = 256
    cursor: int = 0
    allocations: list[Allocation] | None = None

    def __post_init__(self) -> None:
        if self.alignment <= 0:
            raise ValueError("alignment must be positive")
        if self.allocations is None:
            self.allocations = []

    def allocate(self, name: str, size: int) -> Allocation:
        if size < 0:
            raise ValueError("size must be nonnegative")
        offset = _align_up(self.cursor, self.alignment)
        alloc = Allocation(name=name, offset=offset, size=size)
        self.allocations.append(alloc)
        self.cursor = offset + size
        return alloc


def _align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment
