"""Real Qwen3.5-0.8B checkpoint inference helpers.

This module intentionally avoids torch/transformers so the RTL bring-up flow can
consume the local HuggingFace safetensors checkpoint with only numpy. It parses
the safetensors container directly, converts BF16 byte ranges on demand, and
runs a context-1 decode pass over the text model weights.
"""
from __future__ import annotations

import argparse
import json
import mmap
import struct
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from virtual_tpu.numeric import bf16_to_float32


DEFAULT_QWEN35_0P8B_DIR = Path(
    "/Users/aravioli/.cache/huggingface/hub/models--Qwen--Qwen3.5-0.8B/"
    "snapshots/2fc06364715b967f1860aea9cf38778875588b17"
)


def _sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def _silu(x: np.ndarray) -> np.ndarray:
    return x * _sigmoid(x)


def _rmsnorm(x: np.ndarray, w: np.ndarray, eps: float = 1.0e-6) -> np.ndarray:
    return x * (1.0 / np.sqrt(np.mean(x * x, dtype=np.float32) + eps)) * w


@dataclass(frozen=True)
class TensorInfo:
    dtype: str
    shape: tuple[int, ...]
    start: int
    end: int


class SafeTensorBytes:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self._file = self.path.open("rb")
        header_len = struct.unpack("<Q", self._file.read(8))[0]
        self.header = json.loads(self._file.read(header_len))
        self.data_base = 8 + header_len
        self._mmap = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)

    def close(self) -> None:
        self._mmap.close()
        self._file.close()

    def info(self, name: str) -> TensorInfo:
        rec = self.header[name]
        start, end = rec["data_offsets"]
        return TensorInfo(rec["dtype"], tuple(rec["shape"]), self.data_base + start, self.data_base + end)

    def tensor(self, name: str) -> np.ndarray:
        info = self.info(name)
        raw = memoryview(self._mmap)[info.start:info.end]
        if info.dtype == "BF16":
            bits = np.frombuffer(raw, dtype="<u2").copy()
            return bf16_to_float32(bits).reshape(info.shape)
        if info.dtype == "F32":
            return np.frombuffer(raw, dtype="<f4").copy().reshape(info.shape)
        raise TypeError(f"unsupported safetensors dtype {info.dtype} for {name}")

    def bf16_rows(self, name: str, row0: int, rows: int) -> np.ndarray:
        info = self.info(name)
        if info.dtype != "BF16" or len(info.shape) != 2:
            raise TypeError(f"{name} is not a 2-D BF16 tensor")
        cols = info.shape[1]
        start = info.start + row0 * cols * 2
        end = start + rows * cols * 2
        bits = np.frombuffer(memoryview(self._mmap)[start:end], dtype="<u2").copy()
        return bf16_to_float32(bits).reshape((rows, cols))

    def bf16_row(self, name: str, row: int) -> np.ndarray:
        return self.bf16_rows(name, row, 1)[0]


class RealQwen35:
    def __init__(self, model_dir: str | Path = DEFAULT_QWEN35_0P8B_DIR):
        self.model_dir = Path(model_dir)
        shard = sorted(self.model_dir.glob("model.safetensors-*.safetensors"))[0]
        self.tensors = SafeTensorBytes(shard)
        self.config = json.loads((self.model_dir / "config.json").read_text())["text_config"]
        self.eps = float(self.config["rms_norm_eps"])
        self.n_layers = int(self.config["num_hidden_layers"])
        self.hidden = int(self.config["hidden_size"])
        self.intermediate = int(self.config["intermediate_size"])
        self.vocab = int(self.config["vocab_size"])
        self.attn_heads = int(self.config["num_attention_heads"])
        self.kv_heads = int(self.config["num_key_value_heads"])
        self.head_dim = int(self.config["head_dim"])
        self.linear_heads = int(self.config["linear_num_key_heads"])
        self.linear_dim = int(self.config["linear_key_head_dim"])

    def close(self) -> None:
        self.tensors.close()

    def w(self, suffix: str) -> np.ndarray:
        return self.tensors.tensor(f"model.language_model.{suffix}")

    def layer_w(self, layer: int, suffix: str) -> np.ndarray:
        return self.tensors.tensor(f"model.language_model.layers.{layer}.{suffix}")

    def linear(self, x: np.ndarray, name: str) -> np.ndarray:
        return self.tensors.tensor(name) @ x

    def layer_linear(self, x: np.ndarray, layer: int, suffix: str) -> np.ndarray:
        return self.linear(x, f"model.language_model.layers.{layer}.{suffix}")

    def _full_attention_context1(self, x: np.ndarray, layer: int) -> np.ndarray:
        qz = self.layer_linear(x, layer, "self_attn.q_proj.weight")
        v = self.layer_linear(x, layer, "self_attn.v_proj.weight")
        q_dim = self.attn_heads * self.head_dim
        q_gate = _sigmoid(qz[q_dim: q_dim * 2])
        group = self.attn_heads // self.kv_heads
        v_heads = v.reshape(self.kv_heads, self.head_dim)
        ctx = np.repeat(v_heads, group, axis=0).reshape(q_dim)
        gated = ctx * q_gate
        return self.layer_linear(gated, layer, "self_attn.o_proj.weight")

    def _linear_attention_context1(self, x: np.ndarray, layer: int) -> np.ndarray:
        base = f"model.language_model.layers.{layer}.linear_attn"
        qkv = self.linear(x, f"{base}.in_proj_qkv.weight")
        z = self.linear(x, f"{base}.in_proj_z.weight")
        a = self.linear(x, f"{base}.in_proj_a.weight")
        b = self.linear(x, f"{base}.in_proj_b.weight")
        conv_w = self.tensors.tensor(f"{base}.conv1d.weight").reshape(3 * self.linear_heads * self.linear_dim, 4)
        qkv = _silu(qkv * conv_w[:, -1])
        span = self.linear_heads * self.linear_dim
        q = qkv[:span].reshape(self.linear_heads, self.linear_dim)
        k = qkv[span:2 * span].reshape(self.linear_heads, self.linear_dim)
        v = qkv[2 * span:].reshape(self.linear_heads, self.linear_dim)
        q = q / (np.linalg.norm(q, axis=1, keepdims=True) + 1.0e-6)
        k = k / (np.linalg.norm(k, axis=1, keepdims=True) + 1.0e-6)
        beta = _sigmoid(b + self.tensors.tensor(f"{base}.dt_bias"))
        score = np.sum(q * k, axis=1)
        out = (beta[:, None] * score[:, None] * v).astype(np.float32)
        norm_w = self.tensors.tensor(f"{base}.norm.weight")
        out = np.stack([_rmsnorm(row, norm_w, self.eps) for row in out], axis=0).reshape(span)
        out = out * _silu(z)
        return self.linear(out, f"{base}.out_proj.weight")

    def forward_token_hidden(self, token: int) -> np.ndarray:
        x = self.tensors.bf16_row("model.language_model.embed_tokens.weight", token).astype(np.float32)
        for layer in range(self.n_layers):
            h = _rmsnorm(x, self.layer_w(layer, "input_layernorm.weight"), self.eps)
            if (layer % 4) == 3:
                mix = self._full_attention_context1(h, layer)
            else:
                mix = self._linear_attention_context1(h, layer)
            x = x + mix
            h = _rmsnorm(x, self.layer_w(layer, "post_attention_layernorm.weight"), self.eps)
            gate = self.layer_linear(h, layer, "mlp.gate_proj.weight")
            up = self.layer_linear(h, layer, "mlp.up_proj.weight")
            mlp = self.layer_linear(_silu(gate) * up, layer, "mlp.down_proj.weight")
            x = x + mlp
        return _rmsnorm(x, self.w("norm.weight"), self.eps)

    def logits(self, hidden: np.ndarray, *, chunk_rows: int = 4096) -> np.ndarray:
        out = np.empty(self.vocab, dtype=np.float32)
        for row0 in range(0, self.vocab, chunk_rows):
            rows = min(chunk_rows, self.vocab - row0)
            emb = self.tensors.bf16_rows("model.language_model.embed_tokens.weight", row0, rows)
            out[row0:row0 + rows] = emb @ hidden
        return out

    def selected_logits(self, hidden: np.ndarray, token_ids: list[int]) -> np.ndarray:
        rows = [self.tensors.bf16_row("model.language_model.embed_tokens.weight", token) for token in token_ids]
        return np.asarray(rows, dtype=np.float32) @ hidden


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", default=str(DEFAULT_QWEN35_0P8B_DIR))
    parser.add_argument("--token", type=int, default=0)
    parser.add_argument("--selected", default="0,1,42,248319")
    parser.add_argument("--full-logits", action="store_true")
    args = parser.parse_args()

    selected = [int(x) for x in args.selected.split(",") if x]
    model = RealQwen35(args.model_dir)
    try:
        t0 = time.time()
        hidden = model.forward_token_hidden(args.token)
        t_hidden = time.time()
        sel = model.selected_logits(hidden, selected)
        print("============= Real Qwen3.5-0.8B numpy pass =============")
        print(f"  token         : {args.token}")
        print(f"  hidden wall   : {t_hidden - t0:.3f}s")
        for token_id, value in zip(selected, sel):
            print(f"  logit[{token_id:6d}] : {float(value): .6f}")
        if args.full_logits:
            logits = model.logits(hidden)
            print(f"  logits wall   : {time.time() - t_hidden:.3f}s")
            print(f"  argmax token  : {int(np.argmax(logits))}")
            print(f"  argmax logit  : {float(np.max(logits)):.6f}")
        print("=========================================================")
    finally:
        model.close()


if __name__ == "__main__":
    main()
