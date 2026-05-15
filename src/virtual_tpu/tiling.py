from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator


@dataclass(frozen=True)
class Tile:
    start: int
    stop: int
    size: int


@dataclass(frozen=True)
class MatmulTile:
    m: Tile
    n: Tile
    k: Tile


def tiles(length: int, tile_size: int) -> Iterator[Tile]:
    if length < 0:
        raise ValueError("length must be nonnegative")
    if tile_size <= 0:
        raise ValueError("tile_size must be positive")
    for start in range(0, length, tile_size):
        stop = min(start + tile_size, length)
        yield Tile(start=start, stop=stop, size=stop - start)


def matmul_tiles(m: int, n: int, k: int, tile_m: int = 16, tile_n: int = 16, tile_k: int = 16) -> Iterator[MatmulTile]:
    for mt in tiles(m, tile_m):
        for nt in tiles(n, tile_n):
            for kt in tiles(k, tile_k):
                yield MatmulTile(m=mt, n=nt, k=kt)
