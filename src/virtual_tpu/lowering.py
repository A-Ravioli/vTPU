from __future__ import annotations

import numpy as np

from virtual_tpu.programs import Matmul16Layout, TiledMatmulLayout, matmul_16_program, matmul_tiled_packed_program


def lower_single_tile_matmul_16(layout: Matmul16Layout | None = None):
    """Return the serial 16x16 matmul program used by the MVP demo."""

    return matmul_16_program(layout)


def lower_packed_tiled_matmul(layout: TiledMatmulLayout | None = None):
    """Return a serial program for compiler-managed packed tile layout."""

    return matmul_tiled_packed_program(layout)


def pack_int8_tiles(matrix: np.ndarray, tile: int = 16) -> bytes:
    array = np.asarray(matrix, dtype=np.int8)
    if array.ndim != 2 or array.shape[0] % tile or array.shape[1] % tile:
        raise ValueError("matrix must be rank-2 with dimensions divisible by tile")
    chunks = []
    for row in range(0, array.shape[0], tile):
        for col in range(0, array.shape[1], tile):
            chunks.append(array[row : row + tile, col : col + tile].tobytes(order="C"))
    return b"".join(chunks)


def pack_int32_tiles(matrix: np.ndarray, tile: int = 16) -> bytes:
    array = np.asarray(matrix, dtype=np.int32)
    if array.ndim != 2 or array.shape[0] % tile or array.shape[1] % tile:
        raise ValueError("matrix must be rank-2 with dimensions divisible by tile")
    chunks = []
    for row in range(0, array.shape[0], tile):
        for col in range(0, array.shape[1], tile):
            chunks.append(array[row : row + tile, col : col + tile].tobytes(order="C"))
    return b"".join(chunks)


def unpack_int32_tiles(payload: bytes, rows: int, cols: int, tile: int = 16) -> np.ndarray:
    if rows % tile or cols % tile:
        raise ValueError("rows and cols must be divisible by tile")
    result = np.zeros((rows, cols), dtype=np.int32)
    offset = 0
    tile_bytes = tile * tile * 4
    for row in range(0, rows, tile):
        for col in range(0, cols, tile):
            tile_data = payload[offset : offset + tile_bytes]
            result[row : row + tile, col : col + tile] = np.frombuffer(tile_data, dtype=np.int32).reshape(tile, tile)
            offset += tile_bytes
    return result
