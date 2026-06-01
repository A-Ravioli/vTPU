"""Transformer kernels as vTPU instruction sequences (golden-verified, RTL-executable).

Each builder returns a list of Instruction objects operating on a caller-defined
VMEM layout (all fp32 byte offsets). The primitive ops (matmul / vector / reduce)
are RTL-verified in Phases 2-3; these kernels compose them into transformer
sub-operations. The host runtime (Phase 7) supplies constants and orchestrates
the layout across layers.

Conventions:
- All activation buffers are fp32 in VMEM (4 bytes/element).
- Scalars are length-1 fp32 buffers.
- Constants (eps, 1/H, +/-1, ones[]) are written to VMEM by the host beforehand.
"""
from __future__ import annotations

from dataclasses import dataclass

from virtual_tpu.isa import Instruction, ReduceOp, VectorOp, matmul, reduce_op, vector_op

F32 = 4  # bytes per fp32 element


def _v(dst, s0, length, op, s1=0, target=0x10):
    return vector_op(dst_addr=dst, src0_addr=s0, src1_addr=s1, length=length, op=op, target=target)


def _r(dst, src, length, op, columns=0, target=0x10):
    return reduce_op(dst_addr=dst, src_addr=src, length=length, op=op, columns=columns, target=target)


@dataclass(frozen=True)
class RMSNormLayout:
    x: int        # input  [H] fp32
    w: int        # weight [H] fp32
    y: int        # output [H] fp32
    inv_h: int    # const 1/H            (len 1)
    eps: int      # const eps            (len 1)
    ss: int       # scratch sum-of-sq    (len 1)
    mean: int     # scratch mean(+eps)   (len 1)
    denom: int    # scratch rsqrt        (len 1)
    h: int        # hidden size


def rmsnorm_program(L: RMSNormLayout, target: int = 0x10) -> list[Instruction]:
    """y = x * rsqrt(mean(x^2) + eps) * w   (RMSNorm)."""
    return [
        _r(L.ss, L.x, L.h, ReduceOp.FSUMSQ_ALL, target=target),
        _v(L.mean, L.ss, 1, VectorOp.FMUL, s1=L.inv_h, target=target),     # mean = ss / H
        _v(L.mean, L.mean, 1, VectorOp.FADD, s1=L.eps, target=target),     # + eps
        _v(L.denom, L.mean, 1, VectorOp.FRSQRT, target=target),            # 1/sqrt(.)
        _v(L.y, L.x, L.h, VectorOp.FSCALE_BCAST, s1=L.denom, target=target),  # x * denom
        _v(L.y, L.y, L.h, VectorOp.FMUL, s1=L.w, target=target),           # * weight
    ]


@dataclass(frozen=True)
class SoftmaxLayout:
    scores: int   # input  [L] fp32 (pre-mask logits)
    mask: int     # additive causal mask [L] fp32 (0 or -1e30)
    probs: int    # output [L] fp32
    ones: int     # const ones[L]
    neg_one: int  # const -1.0 (len 1)
    s: int        # scratch masked scores [L]
    mx: int       # scratch max (len 1)
    negmx: int    # scratch -max (len 1)
    shift: int    # scratch broadcast -max [L]
    e: int        # scratch exp [L]
    sm: int       # scratch sum (len 1)
    rs: int       # scratch 1/sum (len 1)
    length: int


def softmax_program(L: SoftmaxLayout, target: int = 0x10) -> list[Instruction]:
    """Numerically-stable softmax with an additive causal mask over a length-L row."""
    n = L.length
    return [
        _v(L.s, L.scores, n, VectorOp.FADD, s1=L.mask, target=target),       # apply mask
        _r(L.mx, L.s, n, ReduceOp.FMAX_ALL, target=target),                  # row max
        _v(L.negmx, L.mx, 1, VectorOp.FMUL, s1=L.neg_one, target=target),    # -max
        _v(L.shift, L.ones, n, VectorOp.FSCALE_BCAST, s1=L.negmx, target=target),  # broadcast -max
        _v(L.s, L.s, n, VectorOp.FADD, s1=L.shift, target=target),           # s - max
        _v(L.e, L.s, n, VectorOp.FEXP, target=target),                       # exp
        _r(L.sm, L.e, n, ReduceOp.FSUM_ALL, target=target),                  # sum
        _v(L.rs, L.sm, 1, VectorOp.FRECIP, target=target),                   # 1/sum
        _v(L.probs, L.e, n, VectorOp.FSCALE_BCAST, s1=L.rs, target=target),  # normalize
    ]


@dataclass(frozen=True)
class RopeLayout:
    x: int        # input  [d] fp32
    cos: int      # cos table [d] fp32
    sin: int      # sin table [d] fp32
    out: int      # output [d] fp32
    rh: int       # scratch rotate_half(x) [d]
    t2: int       # scratch rh*sin [d]
    pos_one: int  # const +1.0 (len 1)
    neg_one: int  # const -1.0 (len 1)
    d: int        # rotated dimension (even)


def rope_program(L: RopeLayout, target: int = 0x10) -> list[Instruction]:
    """out = x*cos + rotate_half(x)*sin, rotate_half(x) = [-x2, x1] (LLaMA/Qwen RoPE)."""
    half = L.d // 2
    return [
        # rh[0:half] = -x[half:d]
        _v(L.rh, L.x + half * F32, half, VectorOp.FSCALE_BCAST, s1=L.neg_one, target=target),
        # rh[half:d] = +x[0:half]
        _v(L.rh + half * F32, L.x, half, VectorOp.FSCALE_BCAST, s1=L.pos_one, target=target),
        # out = x * cos
        _v(L.out, L.x, L.d, VectorOp.FMUL, s1=L.cos, target=target),
        # t2 = rh * sin
        _v(L.t2, L.rh, L.d, VectorOp.FMUL, s1=L.sin, target=target),
        # out = out + t2
        _v(L.out, L.out, L.d, VectorOp.FADD, s1=L.t2, target=target),
    ]


@dataclass(frozen=True)
class SwiGLULayout:
    x_bf16: int   # input  [K] bf16 (packed)
    wg_bf16: int  # gate weight  [K][N] bf16
    wu_bf16: int  # up   weight  [K][N] bf16
    wd_bf16: int  # down weight  [N][K] bf16
    gate: int     # scratch [N] fp32
    up: int       # scratch [N] fp32
    h: int        # scratch [N] fp32
    h_bf16: int   # scratch [N] bf16 (packed)
    out: int      # output  [K] fp32
    k: int        # hidden size
    n: int        # intermediate size


def swiglu_program(L: SwiGLULayout, target: int = 0x10) -> list[Instruction]:
    """out = (silu(x @ Wg) * (x @ Wu)) @ Wd   — SwiGLU MLP for a single token (m=1)."""
    return [
        matmul(dst_addr=L.gate, src_a_addr=L.x_bf16, src_b_addr=L.wg_bf16, m=1, n=L.n, k=L.k, bf16=True, target=target),
        matmul(dst_addr=L.up, src_a_addr=L.x_bf16, src_b_addr=L.wu_bf16, m=1, n=L.n, k=L.k, bf16=True, target=target),
        _v(L.gate, L.gate, L.n, VectorOp.FSILU, target=target),          # silu(gate)
        _v(L.h, L.gate, L.n, VectorOp.FMUL, s1=L.up, target=target),     # * up
        _v(L.h_bf16, L.h, L.n, VectorOp.FQUANT_BF16, target=target),     # fp32 -> bf16
        matmul(dst_addr=L.out, src_a_addr=L.h_bf16, src_b_addr=L.wd_bf16, m=1, n=L.k, k=L.n, bf16=True, target=target),
    ]


@dataclass(frozen=True)
class AttnHeadLayout:
    q_bf16: int      # query  [d] bf16 (one token)
    k_bf16: int      # keys   [T][d] bf16
    v_bf16: int      # values [T][d] bf16
    probs_bf16: int  # scratch [T] bf16
    ctx: int         # output  [d] fp32
    sm: "SoftmaxLayout"  # softmax scratch/layout (sm.scores=raw, sm.probs=output)
    d: int           # head dim
    t: int           # context length (keys)


def attention_head_program(L: AttnHeadLayout, target: int = 0x10) -> list[Instruction]:
    """Single-head scaled-dot-product attention (causal mask via sm.mask).

    scores = q @ K^T ; p = softmax(scores) ; ctx = p @ V.
    Scaling by 1/sqrt(d) is folded into q by the host. The matmuls run in bf16
    (q,K,V,p stored bf16) with fp32 softmax in between.
    """
    return [
        matmul(dst_addr=L.sm.scores, src_a_addr=L.q_bf16, src_b_addr=L.k_bf16,
               m=1, n=L.t, k=L.d, bf16=True, transpose_b=True, target=target),
        *softmax_program(L.sm, target=target),
        _v(L.probs_bf16, L.sm.probs, L.t, VectorOp.FQUANT_BF16, target=target),
        matmul(dst_addr=L.ctx, src_a_addr=L.probs_bf16, src_b_addr=L.v_bf16,
               m=1, n=L.d, k=L.t, bf16=True, target=target),
    ]


# --------------------------------------------------------------------------
# Gated DeltaNet (linear-attention) — the 75% of Qwen3.5 layers
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class L2NormLayout:
    x: int      # input  [n] fp32
    out: int    # output [n] fp32
    ss: int     # scratch sum-of-squares (len 1)
    rinv: int   # scratch 1/||x||        (len 1)
    n: int


def l2norm_program(L: L2NormLayout, target: int = 0x10) -> list[Instruction]:
    """out = x / ||x||  (per-vector L2 normalization; DeltaNet normalizes q and k)."""
    return [
        _r(L.ss, L.x, L.n, ReduceOp.FSUMSQ_ALL, target=target),
        _v(L.rinv, L.ss, 1, VectorOp.FRSQRT, target=target),
        _v(L.out, L.x, L.n, VectorOp.FSCALE_BCAST, s1=L.rinv, target=target),
    ]


@dataclass(frozen=True)
class Conv1DLayout:
    taps_x: tuple[int, ...]  # history buffers, lag 0..K-1, each [C] fp32 (newest first)
    taps_w: tuple[int, ...]  # per-channel filter taps, each [C] fp32
    acc: int                 # scratch / output pre-activation [C] fp32
    tmp: int                 # scratch [C] fp32
    out: int                 # output [C] fp32 (after SiLU)
    c: int                   # channels


def conv1d_causal_program(L: Conv1DLayout, target: int = 0x10) -> list[Instruction]:
    """Depthwise causal Conv1D over the last K timesteps, then SiLU (Qwen DeltaNet conv).

    out[c] = silu( sum_j taps_w[j][c] * taps_x[j][c] ).  The host maintains the
    per-channel history ring buffer (taps_x) across decode steps.
    """
    assert len(L.taps_x) == len(L.taps_w) and len(L.taps_x) >= 1
    prog = [_v(L.acc, L.taps_w[0], L.c, VectorOp.FMUL, s1=L.taps_x[0], target=target)]
    for j in range(1, len(L.taps_x)):
        prog.append(_v(L.tmp, L.taps_w[j], L.c, VectorOp.FMUL, s1=L.taps_x[j], target=target))
        prog.append(_v(L.acc, L.acc, L.c, VectorOp.FADD, s1=L.tmp, target=target))
    prog.append(_v(L.out, L.acc, L.c, VectorOp.FSILU, target=target))
    return prog


@dataclass(frozen=True)
class DeltaNetStepLayout:
    # state (carried across timesteps): S is [d_v][d_k] fp32, row-major
    s: int
    s_bf16: int      # scratch bf16 copy of S
    s2_bf16: int     # scratch bf16 copy of updated S
    # per-step inputs (host-projected, q/k already L2-normalized -> bf16; v fp32)
    qb: int          # [d_k] bf16
    kb: int          # [d_k] bf16
    v: int           # [d_v] fp32
    g: int           # [d_v] fp32 output-gate pre-activation
    alpha: int       # const  alpha   (len 1)  decay gate
    neg_alpha: int   # const -alpha   (len 1)
    beta: int        # const  beta    (len 1)  delta learning rate
    # scratch
    u: int           # [d_v] fp32  = S @ k
    au: int          # [d_v] fp32  = -alpha*u
    vmt: int         # [d_v] fp32  = v - alpha*u
    w: int           # [d_v] fp32  = beta*(v - alpha*u)
    wb: int          # [d_v] bf16
    outer: int       # [d_v][d_k] fp32 = w (x) k
    o: int           # [d_v] fp32  = S_new @ q
    sg: int          # [d_v] fp32  = silu(g)
    out: int         # [d_v] fp32  output (gated)
    d_v: int
    d_k: int


def gated_deltanet_step_program(L: DeltaNetStepLayout, target: int = 0x10) -> list[Instruction]:
    """One Gated DeltaNet recurrent step:

        u   = S_{t-1} @ k
        S_t = alpha*S_{t-1} + (beta*(v - alpha*u)) (x) k     (rank-1 delta update + decay)
        o   = S_t @ q
        out = o * silu(g)                                     (SiLU output gate)

    S is the fp32 recurrent-state cache; matmuls run in bf16 (quantized copies).
    """
    dvdk = L.d_v * L.d_k
    return [
        _v(L.s_bf16, L.s, dvdk, VectorOp.FQUANT_BF16, target=target),
        matmul(dst_addr=L.u, src_a_addr=L.s_bf16, src_b_addr=L.kb, m=L.d_v, n=1, k=L.d_k, bf16=True, target=target),
        _v(L.au, L.u, L.d_v, VectorOp.FSCALE_BCAST, s1=L.neg_alpha, target=target),   # -alpha*u
        _v(L.vmt, L.v, L.d_v, VectorOp.FADD, s1=L.au, target=target),                 # v - alpha*u
        _v(L.w, L.vmt, L.d_v, VectorOp.FSCALE_BCAST, s1=L.beta, target=target),       # beta*(...)
        _v(L.wb, L.w, L.d_v, VectorOp.FQUANT_BF16, target=target),
        matmul(dst_addr=L.outer, src_a_addr=L.wb, src_b_addr=L.kb, m=L.d_v, n=L.d_k, k=1, bf16=True, target=target),
        _v(L.s, L.s, dvdk, VectorOp.FSCALE_BCAST, s1=L.alpha, target=target),         # alpha*S
        _v(L.s, L.s, dvdk, VectorOp.FADD, s1=L.outer, target=target),                 # + outer -> S_t
        _v(L.s2_bf16, L.s, dvdk, VectorOp.FQUANT_BF16, target=target),
        matmul(dst_addr=L.o, src_a_addr=L.s2_bf16, src_b_addr=L.qb, m=L.d_v, n=1, k=L.d_k, bf16=True, target=target),
        _v(L.sg, L.g, L.d_v, VectorOp.FSILU, target=target),
        _v(L.out, L.o, L.d_v, VectorOp.FMUL, s1=L.sg, target=target),
    ]

