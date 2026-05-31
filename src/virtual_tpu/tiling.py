# tile iteration helpers for blocked matmul scheduling
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator


@dataclass(frozen=True)
class Tile:
    """half-open index range [start, stop) along one matrix dimension."""

    start: int
    stop: int
    size: int


@dataclass(frozen=True)
class MatmulTile:
    """one (m, n, k) tile triple for blocked matrix multiply."""

    m: Tile
    n: Tile
    k: Tile


def tiles(length: int, tile_size: int) -> Iterator[Tile]:
    """yield consecutive tiles covering [0, length), last tile may be partial."""

    if length < 0:
        raise ValueError("length must be nonnegative")
    if tile_size <= 0:
        raise ValueError("tile_size must be positive")
    for start in range(0, length, tile_size):
        stop = min(start + tile_size, length)
        yield Tile(start=start, stop=stop, size=stop - start)


def matmul_tiles(m: int, n: int, k: int, tile_m: int = 16, tile_n: int = 16, tile_k: int = 16) -> Iterator[MatmulTile]:
    """nested loop order: m outer, n middle, k inner (standard blocked matmul)."""

    for mt in tiles(m, tile_m):
        for nt in tiles(n, tile_n):
            for kt in tiles(k, tile_k):
                yield MatmulTile(m=mt, n=nt, k=kt)
