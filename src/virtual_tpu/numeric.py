from __future__ import annotations

import numpy as np


def wrap_i32(values: np.ndarray) -> np.ndarray:
    wrapped = ((values.astype(np.int64) + (1 << 31)) % (1 << 32)) - (1 << 31)
    return wrapped.astype(np.int32)


def float32_to_bf16(values: np.ndarray) -> np.ndarray:
    as_f32 = np.asarray(values, dtype=np.float32)
    bits = as_f32.view(np.uint32)
    rounding_bias = np.uint32(0x7FFF) + ((bits >> np.uint32(16)) & np.uint32(1))
    return ((bits + rounding_bias) >> np.uint32(16)).astype(np.uint16)


def bf16_to_float32(values: np.ndarray) -> np.ndarray:
    as_u16 = np.asarray(values, dtype=np.uint16)
    return (as_u16.astype(np.uint32) << np.uint32(16)).view(np.float32)


def bf16_matmul(a_bf16: np.ndarray, b_bf16: np.ndarray) -> np.ndarray:
    a = bf16_to_float32(a_bf16).astype(np.float32)
    b = bf16_to_float32(b_bf16).astype(np.float32)
    return (a @ b).astype(np.float32)
