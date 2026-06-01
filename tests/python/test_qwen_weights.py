import numpy as np

from virtual_tpu.numeric import bf16_to_float32, float32_to_bf16
from virtual_tpu.qwen.weights import (
    BF16_BYTES,
    build_hbm_image,
    load_manifest,
    read_tensor_from_image,
    write_image,
)


def _tensors():
    rng = np.random.default_rng(7)
    return {
        "embed_tokens.weight": rng.standard_normal((32, 8)).astype(np.float32),
        "layer0.q_proj.weight": rng.standard_normal((8, 16)).astype(np.float32),
        "layer0.norm.weight": rng.standard_normal((8,)).astype(np.float32),
    }


def test_image_layout_alignment_and_roundtrip():
    tensors = _tensors()
    image, manifest = build_hbm_image(tensors, align=64)
    # every tensor aligned, non-overlapping, exact size
    prev_end = 0
    for name, rec in manifest.items():
        assert rec.offset % 64 == 0, f"{name} not aligned"
        assert rec.offset >= prev_end
        assert rec.nbytes == rec.count * BF16_BYTES
        prev_end = rec.offset + rec.nbytes
        # decode equals the canonical bf16 rounding of the source
        got = read_tensor_from_image(image, rec)
        want = bf16_to_float32(float32_to_bf16(tensors[name]))
        np.testing.assert_array_equal(got, want)
    assert len(image) >= prev_end


def test_write_and_load_manifest(tmp_path):
    tensors = _tensors()
    img_path = tmp_path / "weights.bin"
    manifest = write_image(img_path, tensors, align=64)
    reloaded = load_manifest(img_path)
    assert {k: (v.offset, v.shape, v.count) for k, v in reloaded.items()} == {
        k: (v.offset, v.shape, v.count) for k, v in manifest.items()
    }
    # image on disk decodes correctly via the reloaded manifest
    image = img_path.read_bytes()
    for name, rec in reloaded.items():
        got = read_tensor_from_image(image, rec)
        want = bf16_to_float32(float32_to_bf16(tensors[name]))
        np.testing.assert_array_equal(got, want)


def test_little_endian_uint16_storage():
    # 1.0f -> bf16 0x3F80 -> bytes 80 3F (little-endian)
    image, manifest = build_hbm_image({"x": np.array([1.0], dtype=np.float32)}, align=4)
    rec = manifest["x"]
    assert image[rec.offset : rec.offset + 2] == bytes([0x80, 0x3F])
