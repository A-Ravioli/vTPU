"""Convert model weights into a bf16 HBM image + manifest for the vTPU.

The chip stores bf16 operands as raw little-endian uint16 (see rtl/mxu/mxu_top.sv
select_u16 and numeric.float32_to_bf16). This module lays named tensors out
contiguously in a single byte image at aligned offsets, suitable for preloading
into hbm_model_loadable via +hbm_image. A JSON manifest records each tensor's
byte offset, shape, and element count so the host runtime can DMA tiles by name.

The packing logic is dtype-agnostic about the source (numpy float arrays); a
safetensors directory loader is provided for real Qwen3.5-0.8B weights when the
optional `safetensors` dependency is available.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Mapping

import numpy as np

from virtual_tpu.numeric import bf16_to_float32, float32_to_bf16

BF16_BYTES = 2
DEFAULT_ALIGN = 64  # keep tiles aligned for DMA / bank friendliness


@dataclass(frozen=True)
class TensorRecord:
    """Where a tensor lives in the HBM image."""

    offset: int          # byte offset into the image
    shape: tuple[int, ...]
    count: int           # number of elements
    dtype: str = "bf16"

    @property
    def nbytes(self) -> int:
        return self.count * BF16_BYTES


def _align_up(value: int, align: int) -> int:
    return (value + align - 1) // align * align


def tensor_to_bf16_bytes(arr: np.ndarray) -> bytes:
    """float -> bf16 bit pattern -> little-endian uint16 bytes (chip storage format)."""
    bits = float32_to_bf16(np.asarray(arr, dtype=np.float32))
    return np.asarray(bits, dtype="<u2").tobytes(order="C")


def build_hbm_image(
    tensors: Mapping[str, np.ndarray],
    *,
    align: int = DEFAULT_ALIGN,
    base: int = 0,
    order: Iterable[str] | None = None,
) -> tuple[bytes, dict[str, TensorRecord]]:
    """Lay tensors out contiguously (aligned) into one bf16 image.

    Returns (image_bytes, manifest). Tensors are placed in `order` (or dict order),
    starting at `base`. Offsets are absolute byte addresses into HBM.
    """
    names = list(order) if order is not None else list(tensors.keys())
    chunks: list[bytes] = []
    manifest: dict[str, TensorRecord] = {}
    cursor = base
    if base:
        chunks.append(b"\x00" * base)
    for name in names:
        arr = np.asarray(tensors[name], dtype=np.float32)
        cursor_aligned = _align_up(cursor, align)
        if cursor_aligned > cursor:
            chunks.append(b"\x00" * (cursor_aligned - cursor))
            cursor = cursor_aligned
        payload = tensor_to_bf16_bytes(arr)
        manifest[name] = TensorRecord(offset=cursor, shape=tuple(arr.shape), count=int(arr.size))
        chunks.append(payload)
        cursor += len(payload)
    return b"".join(chunks), manifest


def write_image(
    image_path: str | Path,
    tensors: Mapping[str, np.ndarray],
    *,
    align: int = DEFAULT_ALIGN,
    base: int = 0,
    order: Iterable[str] | None = None,
) -> dict[str, TensorRecord]:
    """Write the binary image and a sidecar `<image>.manifest.json`. Returns the manifest."""
    image, manifest = build_hbm_image(tensors, align=align, base=base, order=order)
    image_path = Path(image_path)
    image_path.write_bytes(image)
    manifest_path = image_path.with_suffix(image_path.suffix + ".manifest.json")
    manifest_path.write_text(
        json.dumps(
            {
                "image_bytes": len(image),
                "align": align,
                "tensors": {name: asdict(rec) for name, rec in manifest.items()},
            },
            indent=2,
        )
    )
    return manifest


def load_manifest(image_path: str | Path) -> dict[str, TensorRecord]:
    manifest_path = Path(image_path).with_suffix(Path(image_path).suffix + ".manifest.json")
    data = json.loads(manifest_path.read_text())
    return {
        name: TensorRecord(offset=rec["offset"], shape=tuple(rec["shape"]), count=rec["count"], dtype=rec["dtype"])
        for name, rec in data["tensors"].items()
    }


def read_tensor_from_image(image: bytes, rec: TensorRecord) -> np.ndarray:
    """Decode a tensor from a bf16 image back to float32 (for verification)."""
    raw = image[rec.offset : rec.offset + rec.nbytes]
    bits = np.frombuffer(raw, dtype="<u2")
    return bf16_to_float32(bits).reshape(rec.shape)


def convert_safetensors_dir(
    model_dir: str | Path,
    image_path: str | Path,
    *,
    align: int = DEFAULT_ALIGN,
) -> dict[str, TensorRecord]:
    """Load every tensor from a HuggingFace safetensors model dir and pack to a bf16 image.

    Requires the optional `safetensors` package. Tensors are loaded as float32 then
    rounded to bf16; this works for Qwen3.5-0.8B's bf16/f32 checkpoints.
    """
    try:
        from safetensors import safe_open  # type: ignore
    except ImportError as exc:  # pragma: no cover - exercised only with real weights
        raise RuntimeError(
            "convert_safetensors_dir needs the 'safetensors' package installed"
        ) from exc

    model_dir = Path(model_dir)
    shards = sorted(model_dir.glob("*.safetensors"))
    if not shards:
        raise FileNotFoundError(f"no .safetensors files in {model_dir}")
    tensors: dict[str, np.ndarray] = {}
    for shard in shards:
        with safe_open(str(shard), framework="numpy") as f:  # type: ignore
            for name in f.keys():
                tensors[name] = f.get_tensor(name).astype(np.float32)
    return write_image(image_path, tensors, align=align)
