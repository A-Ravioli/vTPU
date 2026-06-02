"""Host runtime for the Qwen3.5 hybrid stack on the vTPU.

Provides:
  * QwenConfig with a real `qwen35_0p8b` preset and a `tiny` preset for sim.
  * A numpy reference forward of the hybrid (Gated DeltaNet + Gated Attention)
    decoder with RMSNorm, SwiGLU, RoPE, tied embeddings, plus KV cache and
    DeltaNet recurrent-state cache, and greedy autoregressive generation. This
    is the architecture the chip kernels (qwen/kernels.py) implement op-for-op;
    each kernel is independently golden+RTL verified, so this reference doubles
    as the correctness oracle for the composed model.
  * An instruction/MAC cost model (`per_token_cost`) used by the benchmark to
    project chip throughput.

Layer schedule: every 4th layer is full (Gated) Attention; the rest are Gated
DeltaNet (3:1), matching Qwen3.5 / Qwen3-Next.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from math import ceil

import numpy as np


@dataclass(frozen=True)
class QwenConfig:
    n_layers: int
    d_model: int
    d_ff: int                 # SwiGLU intermediate
    vocab: int
    # attention
    n_q_heads: int
    n_kv_heads: int
    head_dim: int
    rope_dim: int
    # deltanet
    dn_v_heads: int
    dn_qk_heads: int
    dn_head_dim: int
    conv_k: int = 4
    attn_every: int = 4       # 1 attention layer every `attn_every` layers
    rms_eps: float = 1e-6
    rope_theta: float = 1.0e6

    def is_attention_layer(self, i: int) -> bool:
        # layers ..3,7,11.. are attention; the rest DeltaNet (3:1)
        return (i % self.attn_every) == (self.attn_every - 1)

    @property
    def q_dim(self) -> int:
        return self.n_q_heads * self.head_dim

    @property
    def kv_dim(self) -> int:
        return self.n_kv_heads * self.head_dim


def qwen35_0p8b() -> QwenConfig:
    """Approximate Qwen3.5-0.8B shape (from the public model card)."""
    return QwenConfig(
        n_layers=24, d_model=1024, d_ff=3584, vocab=248320,
        n_q_heads=32, n_kv_heads=2, head_dim=256, rope_dim=64,
        dn_v_heads=64, dn_qk_heads=16, dn_head_dim=128, conv_k=4, attn_every=4,
    )


def tiny() -> QwenConfig:
    """Tiny but architecturally complete config for end-to-end sim."""
    return QwenConfig(
        n_layers=4, d_model=32, d_ff=64, vocab=48,
        n_q_heads=4, n_kv_heads=2, head_dim=8, rope_dim=4,
        dn_v_heads=4, dn_qk_heads=4, dn_head_dim=8, conv_k=3, attn_every=4,
    )


# ---------------------------------------------------------------------------
# numpy reference math (mirrors the chip kernels)
# ---------------------------------------------------------------------------

def _rmsnorm(x, w, eps):
    return x * (1.0 / np.sqrt((x * x).mean() + eps)) * w


def _silu(x):
    return x * (1.0 / (1.0 + np.exp(-x)))


def _rope_tables(cfg, pos):
    inv = 1.0 / (cfg.rope_theta ** (np.arange(0, cfg.rope_dim, 2) / cfg.rope_dim))
    ang = pos * inv
    return np.concatenate([np.cos(ang)] * 2), np.concatenate([np.sin(ang)] * 2)


def _apply_rope(vec, cos, sin):
    d = cos.shape[0]
    h = d // 2
    rot = np.concatenate([-vec[h:d], vec[:h]])
    out = vec.copy()
    out[:d] = vec[:d] * cos + rot * sin
    return out


@dataclass
class LayerWeights:
    norm1: np.ndarray
    norm2: np.ndarray
    # mlp
    wg: np.ndarray
    wu: np.ndarray
    wd: np.ndarray
    # attention OR deltanet projections
    wq: np.ndarray = None
    wk: np.ndarray = None
    wv: np.ndarray = None
    wo: np.ndarray = None
    wgate: np.ndarray = None    # output gate proj
    # deltanet extras
    conv_w: np.ndarray = None
    w_alpha: np.ndarray = None
    w_beta: np.ndarray = None


@dataclass
class Model:
    cfg: QwenConfig
    embed: np.ndarray                      # [vocab, d_model] (tied to lm_head)
    layers: list
    final_norm: np.ndarray

    @staticmethod
    def random(cfg: QwenConfig, seed: int = 0) -> "Model":
        rng = np.random.default_rng(seed)
        s = 0.08
        layers = []
        for i in range(cfg.n_layers):
            lw = LayerWeights(
                norm1=rng.standard_normal(cfg.d_model).astype(np.float32) * 0.1 + 1.0,
                norm2=rng.standard_normal(cfg.d_model).astype(np.float32) * 0.1 + 1.0,
                wg=(rng.standard_normal((cfg.d_model, cfg.d_ff)) * s).astype(np.float32),
                wu=(rng.standard_normal((cfg.d_model, cfg.d_ff)) * s).astype(np.float32),
                wd=(rng.standard_normal((cfg.d_ff, cfg.d_model)) * s).astype(np.float32),
            )
            if cfg.is_attention_layer(i):
                lw.wq = (rng.standard_normal((cfg.d_model, cfg.q_dim)) * s).astype(np.float32)
                lw.wk = (rng.standard_normal((cfg.d_model, cfg.kv_dim)) * s).astype(np.float32)
                lw.wv = (rng.standard_normal((cfg.d_model, cfg.kv_dim)) * s).astype(np.float32)
                lw.wo = (rng.standard_normal((cfg.q_dim, cfg.d_model)) * s).astype(np.float32)
                lw.wgate = (rng.standard_normal((cfg.d_model, cfg.q_dim)) * s).astype(np.float32)
            else:
                dn_qk = cfg.dn_qk_heads * cfg.dn_head_dim
                dn_v = cfg.dn_v_heads * cfg.dn_head_dim
                lw.wq = (rng.standard_normal((cfg.d_model, dn_qk)) * s).astype(np.float32)
                lw.wk = (rng.standard_normal((cfg.d_model, dn_qk)) * s).astype(np.float32)
                lw.wv = (rng.standard_normal((cfg.d_model, dn_v)) * s).astype(np.float32)
                lw.wo = (rng.standard_normal((dn_v, cfg.d_model)) * s).astype(np.float32)
                lw.wgate = (rng.standard_normal((cfg.d_model, dn_v)) * s).astype(np.float32)
                lw.conv_w = (rng.standard_normal((cfg.conv_k, dn_qk * 2 + dn_v)) * 0.2).astype(np.float32)
                lw.w_alpha = (rng.standard_normal((cfg.d_model, cfg.dn_v_heads)) * s).astype(np.float32)
                lw.w_beta = (rng.standard_normal((cfg.d_model, cfg.dn_v_heads)) * s).astype(np.float32)
            layers.append(lw)
        return Model(
            cfg=cfg,
            embed=(rng.standard_normal((cfg.vocab, cfg.d_model)) * 0.1).astype(np.float32),
            layers=layers,
            final_norm=(rng.standard_normal(cfg.d_model).astype(np.float32) * 0.1 + 1.0),
        )


@dataclass
class Caches:
    # attention KV cache per layer: lists of past k/v vectors
    kv: dict = field(default_factory=dict)
    # deltanet state S per layer per v-head: [d_v_head, d_qk_head]
    state: dict = field(default_factory=dict)
    # conv history per deltanet layer: deque-like list of recent projected vectors
    conv: dict = field(default_factory=dict)
    pos: int = 0
    max_seq: int | None = None


def _apply_rope_matrix(x, cos, sin):
    d = cos.shape[0]
    h = d // 2
    out = x.copy()
    rot = np.concatenate([-x[:, h:d], x[:, :h]], axis=1)
    out[:, :d] = x[:, :d] * cos + rot * sin
    return out


def _attention_layer(cfg, lw, x, cache: Caches, li: int):
    H, hd = cfg.n_q_heads, cfg.head_dim
    q = x @ lw.wq
    k = x @ lw.wk
    v = x @ lw.wv
    cos, sin = _rope_tables(cfg, cache.pos)
    # GQA: each kv head shared by H/n_kv_heads q heads
    group = cfg.n_q_heads // cfg.n_kv_heads
    # apply rope to q,k per head (partial), store this step's k,v
    kh = k.reshape(cfg.n_kv_heads, hd).copy()
    vh = v.reshape(cfg.n_kv_heads, hd).copy()
    kh = _apply_rope_matrix(kh, cos, sin)
    if cache.max_seq is None:
        kv = cache.kv.setdefault(li, {"k": [], "v": []})
        kv["k"].append(kh)
        kv["v"].append(vh)
        Kc = np.asarray(kv["k"], dtype=np.float32)  # [T, n_kv, hd]
        Vc = np.asarray(kv["v"], dtype=np.float32)
    else:
        kv = cache.kv.get(li)
        if kv is None:
            kv = {
                "k": np.empty((cache.max_seq, cfg.n_kv_heads, hd), dtype=np.float32),
                "v": np.empty((cache.max_seq, cfg.n_kv_heads, hd), dtype=np.float32),
            }
            cache.kv[li] = kv
        kv["k"][cache.pos] = kh
        kv["v"][cache.pos] = vh
        Kc = kv["k"][:cache.pos + 1]
        Vc = kv["v"][:cache.pos + 1]
    qh = _apply_rope_matrix(q.reshape(H, hd), cos, sin)
    scale = 1.0 / np.sqrt(hd)
    qg = qh.reshape(cfg.n_kv_heads, group, hd) * scale
    scores = np.einsum("tkd,kgd->kgt", Kc, qg, optimize=True)
    p = np.exp(scores - scores.max(axis=2, keepdims=True))
    p = p / p.sum(axis=2, keepdims=True)
    out = np.einsum("kgt,tkd->kgd", p, Vc, optimize=True).reshape(cfg.q_dim)
    gate = 1.0 / (1.0 + np.exp(-(x @ lw.wgate)))   # sigmoid output gate [q_dim]
    return (out * gate) @ lw.wo                     # [d_model]


def _deltanet_layer(cfg, lw, x, cache: Caches, li: int):
    dn_qk_h, dn_v_h, hdim = cfg.dn_qk_heads, cfg.dn_v_heads, cfg.dn_head_dim
    q = x @ lw.wq
    k = x @ lw.wk
    v = x @ lw.wv
    # causal conv1d over [q|k|v] channels
    cat = np.concatenate([q, k, v]).astype(np.float32)
    hist = cache.conv.setdefault(li, [])
    hist.insert(0, cat)
    del hist[cfg.conv_k:]
    acc = np.zeros_like(cat)
    for j, past in enumerate(hist):
        acc = acc + lw.conv_w[j] * past
    cat = _silu(acc)
    qd = cat[:dn_qk_h * hdim].reshape(dn_qk_h, hdim)
    kd = cat[dn_qk_h * hdim:2 * dn_qk_h * hdim].reshape(dn_qk_h, hdim)
    vd = cat[2 * dn_qk_h * hdim:].reshape(dn_v_h, hdim)
    alpha = 1.0 / (1.0 + np.exp(-(x @ lw.w_alpha)))     # (0,1) decay per v-head
    beta = 1.0 / (1.0 + np.exp(-(x @ lw.w_beta)))       # (0,1)
    group = dn_v_h // dn_qk_h
    states = cache.state.get(li)
    if states is None:
        states = np.zeros((dn_v_h, hdim, hdim), dtype=np.float32)
        cache.state[li] = states
    qk_idx = np.arange(dn_v_h) // group
    kd_g = kd[qk_idx]
    qd_g = qd[qk_idx]
    kn = kd_g / (np.linalg.norm(kd_g, axis=1, keepdims=True) + 1e-6)
    qn = qd_g / (np.linalg.norm(qd_g, axis=1, keepdims=True) + 1e-6)
    u = np.einsum("hij,hj->hi", states, kn, optimize=True)
    w = beta[:, None] * (vd - alpha[:, None] * u)
    states *= alpha[:, None, None]
    states += w[:, :, None] * kn[:, None, :]
    out = np.einsum("hij,hj->hi", states, qn, optimize=True).reshape(dn_v_h * hdim)
    gate = _silu(x @ lw.wgate)                       # SiLU output gate [dn_v]
    return (out * gate) @ lw.wo                       # [d_model]


def forward_token(model: Model, token: int, cache: Caches) -> np.ndarray:
    cfg = model.cfg
    x = model.embed[token].astype(np.float32)
    for li, lw in enumerate(model.layers):
        h = _rmsnorm(x, lw.norm1, cfg.rms_eps)
        if cfg.is_attention_layer(li):
            mix = _attention_layer(cfg, lw, h, cache, li)
        else:
            mix = _deltanet_layer(cfg, lw, h, cache, li)
        x = x + mix
        h2 = _rmsnorm(x, lw.norm2, cfg.rms_eps)
        mlp = _silu(h2 @ lw.wg) * (h2 @ lw.wu) @ lw.wd
        x = x + mlp
    x = _rmsnorm(x, model.final_norm, cfg.rms_eps)
    return x @ model.embed.T            # tied lm_head -> logits [vocab]


def generate(model: Model, prompt: list[int], n_new: int) -> list[int]:
    """Greedy autoregressive generation with KV + DeltaNet-state caches."""
    cache = Caches(max_seq=len(prompt) + n_new)
    out = list(prompt)
    logits = None
    for t in out:
        logits = forward_token(model, t, cache)
        cache.pos += 1
    for _ in range(n_new):
        nxt = int(np.argmax(logits))
        out.append(nxt)
        logits = forward_token(model, nxt, cache)
        cache.pos += 1
    return out


# ---------------------------------------------------------------------------
# chip instruction / MAC cost model
# ---------------------------------------------------------------------------

def _matmul_tiles(m, n, k, tile=16):
    return ceil(m / tile) * ceil(n / tile) * ceil(k / tile)


def per_token_cost(cfg: QwenConfig, tile: int = 16) -> dict:
    """Estimate chip instructions and MACs to decode one token (prefill context len 1).

    Counts matmul-tile instructions (token is m=1), vector/reduce ops, and MACs.
    Attention score/AV matmuls grow with context T; reported at T=1 (per-step floor).
    """
    matmul_instr = 0
    macs = 0
    vec_instr = 0

    def lin(d_in, d_out):
        nonlocal matmul_instr, macs
        matmul_instr += _matmul_tiles(1, d_out, d_in, tile)
        macs += d_in * d_out

    for i in range(cfg.n_layers):
        # two RMSNorms (~6 vec/reduce ops each) + residuals
        vec_instr += 2 * 6 + 2
        # MLP (SwiGLU)
        lin(cfg.d_model, cfg.d_ff)   # gate
        lin(cfg.d_model, cfg.d_ff)   # up
        lin(cfg.d_ff, cfg.d_model)   # down
        vec_instr += 3               # silu, mul, quant
        if cfg.is_attention_layer(i):
            lin(cfg.d_model, cfg.q_dim)
            lin(cfg.d_model, cfg.kv_dim)
            lin(cfg.d_model, cfg.kv_dim)
            lin(cfg.q_dim, cfg.d_model)       # o_proj
            lin(cfg.d_model, cfg.q_dim)       # gate
            vec_instr += cfg.n_q_heads * 9    # per-head softmax kernel
            macs += cfg.q_dim                 # qk/av at T=1 floor
        else:
            dn_qk = cfg.dn_qk_heads * cfg.dn_head_dim
            dn_v = cfg.dn_v_heads * cfg.dn_head_dim
            lin(cfg.d_model, dn_qk)           # q
            lin(cfg.d_model, dn_qk)           # k
            lin(cfg.d_model, dn_v)            # v
            lin(dn_v, cfg.d_model)            # o_proj
            lin(cfg.d_model, dn_v)            # gate
            # per v-head recurrence: 2 matmuls (S@k, S@q) + outer + vec ops
            hd = cfg.dn_head_dim
            for _h in range(cfg.dn_v_heads):
                matmul_instr += _matmul_tiles(hd, 1, hd, tile)   # S@k
                matmul_instr += _matmul_tiles(hd, hd, 1, tile)   # outer
                matmul_instr += _matmul_tiles(hd, 1, hd, tile)   # S@q
                macs += 3 * hd * hd
                vec_instr += 9
    # lm head (tied)
    lin(cfg.d_model, cfg.vocab)
    return {
        "matmul_instr": matmul_instr,
        "vector_instr": vec_instr,
        "total_instr": matmul_instr + vec_instr,
        "macs": macs,
    }
