"""Build RTL simulation artifacts for Qwen inference bring-up workloads."""
from __future__ import annotations

import json
import os
from dataclasses import asdict
from pathlib import Path

import numpy as np

from virtual_tpu.emit_hex import emit_hex
from virtual_tpu.isa import AddressSpace, Instruction, MemoryRef, Opcode, UnitMask, VectorOp, barrier, clear, dma_copy, halt, matmul, vector_op
from virtual_tpu.numeric import bf16_to_float32, float32_to_bf16
from virtual_tpu.qwen.kernels import (
    AttnHeadLayout,
    DeltaNetStepLayout,
    L2NormLayout,
    RMSNormLayout,
    RopeLayout,
    SoftmaxLayout,
    SwiGLULayout,
    attention_head_program,
    gated_deltanet_step_program,
    l2norm_program,
    rmsnorm_program,
    rope_program,
    swiglu_program,
)
from virtual_tpu.qwen.runtime import Caches, Model, forward_token, per_token_cost, qwen35_0p8b, tiny
from virtual_tpu.qwen.weights import TensorRecord, tensor_to_bf16_bytes


def _align_up(value: int, align: int = 64) -> int:
    return (value + align - 1) // align * align


def _put_bf16(image: bytearray, manifest: dict[str, TensorRecord], name: str, offset: int, arr: np.ndarray) -> None:
    array = np.asarray(arr, dtype=np.float32, order="C")
    payload = tensor_to_bf16_bytes(array)
    end = offset + len(payload)
    if len(image) < end:
        image.extend(b"\x00" * (end - len(image)))
    image[offset:end] = payload
    manifest[name] = TensorRecord(offset=offset, shape=tuple(array.shape), count=int(array.size), dtype="bf16")


def _put_f32(image: bytearray, manifest: dict[str, TensorRecord], name: str, offset: int, arr: np.ndarray) -> None:
    array = np.asarray(arr, dtype=np.float32, order="C")
    payload = array.tobytes(order="C")
    end = offset + len(payload)
    if len(image) < end:
        image.extend(b"\x00" * (end - len(image)))
    image[offset:end] = payload
    manifest[name] = TensorRecord(offset=offset, shape=tuple(array.shape), count=int(array.size), dtype="float32")


def _bf16_round(values: np.ndarray) -> np.ndarray:
    return bf16_to_float32(float32_to_bf16(np.asarray(values, dtype=np.float32)))


def _sync_kernel(program: list[Instruction]) -> list[Instruction]:
    """Serialize lowered kernels for RTL bring-up until the scheduler owns hazards."""

    synced: list[Instruction] = []
    local_units = UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE
    for instr in program:
        synced.append(instr)
        if instr.opcode_enum in {Opcode.MATMUL, Opcode.VECTOR_OP, Opcode.REDUCE}:
            synced.append(barrier(local_units))
    return synced


class _HBMBuilder:
    def __init__(self) -> None:
        self.image = bytearray()
        self.manifest: dict[str, TensorRecord] = {}
        self.cursor = 0

    def bf16(self, name: str, arr: np.ndarray, align: int = 64) -> int:
        off = _align_up(self.cursor, align)
        _put_bf16(self.image, self.manifest, name, off, arr)
        self.cursor = off + np.asarray(arr).size * 2
        return off

    def f32(self, name: str, arr: np.ndarray, align: int = 64) -> int:
        off = _align_up(self.cursor, align)
        _put_f32(self.image, self.manifest, name, off, arr)
        self.cursor = off + np.asarray(arr).size * 4
        return off

    def reserve_f32(self, name: str, shape: tuple[int, ...], align: int = 64) -> int:
        off = _align_up(self.cursor, align)
        count = int(np.prod(shape))
        end = off + count * 4
        if len(self.image) < end:
            self.image.extend(b"\x00" * (end - len(self.image)))
        self.manifest[name] = TensorRecord(offset=off, shape=shape, count=count, dtype="float32")
        self.cursor = end
        return off


def _dma_h2v(hbm_addr: int, vmem_addr: int, nbytes: int) -> Instruction:
    return dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_addr), src=MemoryRef(AddressSpace.HBM, hbm_addr), length=nbytes)


def _dma_v2h(hbm_addr: int, vmem_addr: int, nbytes: int) -> Instruction:
    return dma_copy(dst=MemoryRef(AddressSpace.HBM, hbm_addr), src=MemoryRef(AddressSpace.VMEM0, vmem_addr), length=nbytes)


def _quantize(program: list[Instruction], src_f32: int, dst_bf16: int, length: int) -> None:
    if length % 2:
        raise ValueError("RTL FQUANT_BF16 requires an even element count")
    program.append(vector_op(dst_addr=dst_bf16, src0_addr=src_f32, length=length, op=VectorOp.FQUANT_BF16))
    program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))


def _add(program: list[Instruction], dst: int, src0: int, src1: int, length: int) -> None:
    program.append(vector_op(dst_addr=dst, src0_addr=src0, src1_addr=src1, length=length, op=VectorOp.FADD))
    program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))


def _sigmoid_inplace(program: list[Instruction], addr: int, length: int) -> None:
    program.append(vector_op(dst_addr=addr, src0_addr=addr, length=length, op=VectorOp.FSIGMOID))
    program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))


def _scale_copy(program: list[Instruction], dst: int, src: int, length: int, one_addr: int) -> None:
    program.append(vector_op(dst_addr=dst, src0_addr=src, src1_addr=one_addr, length=length, op=VectorOp.FSCALE_BCAST))
    program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))


def _linear_tiled(
    program: list[Instruction],
    hbm: _HBMBuilder,
    *,
    name: str,
    a_bf16_addr: int,
    out_f32_addr: int,
    weight: np.ndarray,
    vmem_tile_addr: int,
    k_tile: int = 16,
    n_tile: int = 16,
) -> None:
    """Lower y = a[1,K] @ W[K,N] using packed BF16 W tiles."""

    w = np.asarray(weight, dtype=np.float32)
    k_total, n_total = w.shape
    for n0 in range(0, n_total, n_tile):
        nt = min(n_tile, n_total - n0)
        for k0 in range(0, k_total, k_tile):
            kt = min(k_tile, k_total - k0)
            tile = w[k0:k0 + kt, n0:n0 + nt]
            tile_hbm = hbm.bf16(f"{name}.k{k0}.n{n0}", tile)
            program.append(_dma_h2v(tile_hbm, vmem_tile_addr, tile.size * 2))
            program.append(barrier(UnitMask.DMA))
            program.append(
                matmul(
                    dst_addr=out_f32_addr + n0 * 4,
                    src_a_addr=a_bf16_addr + k0 * 2,
                    src_b_addr=vmem_tile_addr,
                    m=1,
                    n=nt,
                    k=kt,
                    bf16=True,
                    accumulate=k0 != 0,
                )
            )
            program.append(barrier(UnitMask.MXU))


def _load_f32(program: list[Instruction], hbm: _HBMBuilder, name: str, arr: np.ndarray, vmem_addr: int) -> None:
    off = hbm.f32(name, arr)
    program.append(_dma_h2v(off, vmem_addr, np.asarray(arr, dtype=np.float32).size * 4))
    program.append(barrier(UnitMask.DMA))


def _rmsnorm(program: list[Instruction], hbm: _HBMBuilder, *, name: str, x: int, w: np.ndarray, y: int, w_addr: int, inv_h: int, eps: int, scratch: int, h: int) -> None:
    _load_f32(program, hbm, name, w, w_addr)
    layout = RMSNormLayout(x=x, w=w_addr, y=y, inv_h=inv_h, eps=eps, ss=scratch, mean=scratch + 0x10, denom=scratch + 0x20, h=h)
    program.extend(_sync_kernel(rmsnorm_program(layout)))


def _build_tiny_full_token_artifacts(out_dir: Path) -> dict:
    cfg = tiny()
    model = Model.random(cfg, seed=21)
    token = 3
    expected = forward_token(model, token, Caches(max_seq=2)).astype(np.float32)

    hbm = _HBMBuilder()
    program: list[Instruction] = []

    X = 0x0000
    NORM = 0x0200
    A_BF16 = 0x0400
    MIX = 0x0800
    MLP = 0x0A00
    CAT = 0x1000
    GATE = 0x1800
    ALPHA = 0x1A00
    BETA = 0x1B00
    Q_ROPE = 0x1C00
    K_ROPE = 0x1E00
    Q_BF16 = 0x2000
    K_BF16 = 0x2100
    V_BF16 = 0x2200
    S = 0x2400
    S_BF16 = 0x2600
    S2_BF16 = 0x2800
    DN_U = 0x2A00
    DN_AU = 0x2B00
    DN_VMT = 0x2C00
    DN_W = 0x2D00
    DN_WB = 0x2E00
    DN_OUTER = 0x3000
    DN_O = 0x3200
    DN_SG = 0x3300
    CONST = 0x3800
    INV_H = CONST
    EPS = CONST + 0x10
    ONE = CONST + 0x20
    NEG_ONE = CONST + 0x30
    COS = CONST + 0x40
    SIN = CONST + 0x80
    MASK = CONST + 0xC0
    ONES2 = CONST + 0xD0
    WEIGHT_TILE = 0x5000

    init = {
        "decode_input_tile": model.embed[token],
        "const.inv_h": np.array([1.0 / cfg.d_model], np.float32),
        "const.eps": np.array([cfg.rms_eps], np.float32),
        "const.one": np.array([1.0], np.float32),
        "const.neg_one": np.array([-1.0], np.float32),
        "const.cos": np.ones(cfg.head_dim, np.float32),
        "const.sin": np.zeros(cfg.head_dim, np.float32),
        "const.mask2": np.array([0.0, -1.0e30], np.float32),
        "const.ones2": np.ones(2, np.float32),
    }
    init_addrs = {
        "decode_input_tile": X,
        "const.inv_h": INV_H,
        "const.eps": EPS,
        "const.one": ONE,
        "const.neg_one": NEG_ONE,
        "const.cos": COS,
        "const.sin": SIN,
        "const.mask2": MASK,
        "const.ones2": ONES2,
    }
    for name, arr in init.items():
        off = hbm.f32(name, arr)
        program.append(_dma_h2v(off, init_addrs[name], np.asarray(arr, dtype=np.float32).size * 4))
    program.append(barrier(UnitMask.DMA))

    for li, lw in enumerate(model.layers):
        _rmsnorm(program, hbm, name=f"layers.{li}.norm1", x=X, w=lw.norm1, y=NORM, w_addr=WEIGHT_TILE, inv_h=INV_H, eps=EPS, scratch=0x3A00, h=cfg.d_model)
        _quantize(program, NORM, A_BF16, cfg.d_model)

        if cfg.is_attention_layer(li):
            _linear_tiled(program, hbm, name=f"layers.{li}.attn.wq", a_bf16_addr=A_BF16, out_f32_addr=CAT, weight=lw.wq, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.attn.wk", a_bf16_addr=A_BF16, out_f32_addr=CAT + cfg.q_dim * 4, weight=lw.wk, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.attn.wv", a_bf16_addr=A_BF16, out_f32_addr=CAT + (cfg.q_dim + cfg.kv_dim) * 4, weight=lw.wv, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.attn.wgate", a_bf16_addr=A_BF16, out_f32_addr=GATE, weight=lw.wgate, vmem_tile_addr=WEIGHT_TILE)
            _sigmoid_inplace(program, GATE, cfg.q_dim)

            # Build roped/quantized K,V caches with a masked dummy second position.
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, K_ROPE), length=cfg.n_kv_heads * 2 * cfg.head_dim * 4))
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, K_ROPE + 0x100), length=cfg.n_kv_heads * 2 * cfg.head_dim * 4))
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, K_BF16), length=cfg.n_kv_heads * 2 * cfg.head_dim * 2))
            program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, V_BF16), length=cfg.n_kv_heads * 2 * cfg.head_dim * 2))
            program.append(barrier(UnitMask.ALL_LOCAL))
            for kh in range(cfg.n_kv_heads):
                src_k = CAT + (cfg.q_dim + kh * cfg.head_dim) * 4
                dst_k = K_ROPE + kh * 2 * cfg.head_dim * 4
                _scale_copy(program, dst_k, src_k, cfg.head_dim, ONE)
                program.extend(_sync_kernel(rope_program(RopeLayout(x=dst_k, cos=COS, sin=SIN, out=dst_k, rh=0x3400, t2=0x3500, pos_one=ONE, neg_one=NEG_ONE, d=cfg.rope_dim))))
                _quantize(program, dst_k, K_BF16 + kh * 2 * cfg.head_dim * 2, 2 * cfg.head_dim)
                _scale_copy(program, K_ROPE + 0x100 + kh * 2 * cfg.head_dim * 4, CAT + (cfg.q_dim + cfg.kv_dim + kh * cfg.head_dim) * 4, cfg.head_dim, ONE)
                _quantize(program, K_ROPE + 0x100 + kh * 2 * cfg.head_dim * 4, V_BF16 + kh * 2 * cfg.head_dim * 2, 2 * cfg.head_dim)

            for qh in range(cfg.n_q_heads):
                kvh = qh // (cfg.n_q_heads // cfg.n_kv_heads)
                src_q = CAT + qh * cfg.head_dim * 4
                dst_q = Q_ROPE + qh * cfg.head_dim * 4
                _scale_copy(program, dst_q, src_q, cfg.head_dim, ONE)
                program.extend(_sync_kernel(rope_program(RopeLayout(x=dst_q, cos=COS, sin=SIN, out=dst_q, rh=0x3400, t2=0x3500, pos_one=ONE, neg_one=NEG_ONE, d=cfg.rope_dim))))
                _quantize(program, dst_q, Q_BF16 + qh * cfg.head_dim * 2, cfg.head_dim)
                sm = SoftmaxLayout(scores=0x3600, mask=MASK, probs=0x3610, ones=ONES2, neg_one=NEG_ONE, s=0x3620, mx=0x3630, negmx=0x3640, shift=0x3650, e=0x3660, sm=0x3670, rs=0x3680, length=2)
                ah = AttnHeadLayout(
                    q_bf16=Q_BF16 + qh * cfg.head_dim * 2,
                    k_bf16=K_BF16 + kvh * 2 * cfg.head_dim * 2,
                    v_bf16=V_BF16 + kvh * 2 * cfg.head_dim * 2,
                    probs_bf16=0x3690,
                    ctx=MIX + qh * cfg.head_dim * 4,
                    sm=sm,
                    d=cfg.head_dim,
                    t=2,
                )
                program.extend(_sync_kernel(attention_head_program(ah)))
            program.append(vector_op(dst_addr=MIX, src0_addr=MIX, src1_addr=GATE, length=cfg.q_dim, op=VectorOp.FMUL))
            program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))
            _quantize(program, MIX, A_BF16, cfg.q_dim)
            _linear_tiled(program, hbm, name=f"layers.{li}.attn.wo", a_bf16_addr=A_BF16, out_f32_addr=MIX, weight=lw.wo, vmem_tile_addr=WEIGHT_TILE)
        else:
            dn_qk = cfg.dn_qk_heads * cfg.dn_head_dim
            dn_v = cfg.dn_v_heads * cfg.dn_head_dim
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wq", a_bf16_addr=A_BF16, out_f32_addr=CAT, weight=lw.wq, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wk", a_bf16_addr=A_BF16, out_f32_addr=CAT + dn_qk * 4, weight=lw.wk, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wv", a_bf16_addr=A_BF16, out_f32_addr=CAT + 2 * dn_qk * 4, weight=lw.wv, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wgate", a_bf16_addr=A_BF16, out_f32_addr=GATE, weight=lw.wgate, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.walpha", a_bf16_addr=A_BF16, out_f32_addr=ALPHA, weight=lw.w_alpha, vmem_tile_addr=WEIGHT_TILE)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wbeta", a_bf16_addr=A_BF16, out_f32_addr=BETA, weight=lw.w_beta, vmem_tile_addr=WEIGHT_TILE)
            _sigmoid_inplace(program, ALPHA, cfg.dn_v_heads)
            _sigmoid_inplace(program, BETA, cfg.dn_v_heads)
            _load_f32(program, hbm, f"layers.{li}.dn.conv0", lw.conv_w[0], WEIGHT_TILE)
            program.append(vector_op(dst_addr=CAT, src0_addr=CAT, src1_addr=WEIGHT_TILE, length=2 * dn_qk + dn_v, op=VectorOp.FMUL))
            program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))
            program.append(vector_op(dst_addr=CAT, src0_addr=CAT, length=2 * dn_qk + dn_v, op=VectorOp.FSILU))
            program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))
            _sigmoid_inplace(program, GATE, dn_v)

            for hidx in range(cfg.dn_v_heads):
                q_addr = CAT + hidx * cfg.dn_head_dim * 4
                k_addr = CAT + (dn_qk + hidx * cfg.dn_head_dim) * 4
                v_addr = CAT + (2 * dn_qk + hidx * cfg.dn_head_dim) * 4
                g_addr = GATE + hidx * cfg.dn_head_dim * 4
                program.extend(_sync_kernel(l2norm_program(L2NormLayout(x=q_addr, out=Q_ROPE, ss=0x3400, rinv=0x3410, n=cfg.dn_head_dim))))
                program.extend(_sync_kernel(l2norm_program(L2NormLayout(x=k_addr, out=K_ROPE, ss=0x3400, rinv=0x3410, n=cfg.dn_head_dim))))
                _quantize(program, Q_ROPE, Q_BF16, cfg.dn_head_dim)
                _quantize(program, K_ROPE, K_BF16, cfg.dn_head_dim)
                program.append(clear(dst=MemoryRef(AddressSpace.VMEM0, S), length=cfg.dn_head_dim * cfg.dn_head_dim * 4))
                program.append(barrier(UnitMask.ALL_LOCAL))
                dn = DeltaNetStepLayout(
                    s=S,
                    s_bf16=S_BF16,
                    s2_bf16=S2_BF16,
                    qb=Q_BF16,
                    kb=K_BF16,
                    v=v_addr,
                    g=g_addr,
                    alpha=ALPHA + hidx * 4,
                    neg_alpha=NEG_ONE,  # first-token zero state makes this term inactive
                    beta=BETA + hidx * 4,
                    u=DN_U,
                    au=DN_AU,
                    vmt=DN_VMT,
                    w=DN_W,
                    wb=DN_WB,
                    outer=DN_OUTER,
                    o=DN_O,
                    sg=DN_SG,
                    out=MIX + hidx * cfg.dn_head_dim * 4,
                    d_v=cfg.dn_head_dim,
                    d_k=cfg.dn_head_dim,
                )
                program.extend(_sync_kernel(gated_deltanet_step_program(dn)))
            _quantize(program, MIX, A_BF16, dn_v)
            _linear_tiled(program, hbm, name=f"layers.{li}.dn.wo", a_bf16_addr=A_BF16, out_f32_addr=MIX, weight=lw.wo, vmem_tile_addr=WEIGHT_TILE)

        _add(program, X, X, MIX, cfg.d_model)

        _rmsnorm(program, hbm, name=f"layers.{li}.norm2", x=X, w=lw.norm2, y=NORM, w_addr=WEIGHT_TILE, inv_h=INV_H, eps=EPS, scratch=0x3A00, h=cfg.d_model)
        _quantize(program, NORM, A_BF16, cfg.d_model)
        gate_addr = CAT
        up_addr = CAT + 0x400
        hidden_addr = CAT + 0x800
        hidden_bf16 = CAT + 0xC00
        _linear_tiled(program, hbm, name=f"layers.{li}.mlp.wg", a_bf16_addr=A_BF16, out_f32_addr=gate_addr, weight=lw.wg, vmem_tile_addr=WEIGHT_TILE)
        _linear_tiled(program, hbm, name=f"layers.{li}.mlp.wu", a_bf16_addr=A_BF16, out_f32_addr=up_addr, weight=lw.wu, vmem_tile_addr=WEIGHT_TILE)
        program.append(vector_op(dst_addr=gate_addr, src0_addr=gate_addr, length=cfg.d_ff, op=VectorOp.FSILU))
        program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))
        program.append(vector_op(dst_addr=hidden_addr, src0_addr=gate_addr, src1_addr=up_addr, length=cfg.d_ff, op=VectorOp.FMUL))
        program.append(barrier(UnitMask.MXU | UnitMask.VPU | UnitMask.REDUCE))
        _quantize(program, hidden_addr, hidden_bf16, cfg.d_ff)
        _linear_tiled(program, hbm, name=f"layers.{li}.mlp.wd", a_bf16_addr=hidden_bf16, out_f32_addr=MLP, weight=lw.wd, vmem_tile_addr=WEIGHT_TILE)
        _add(program, X, X, MLP, cfg.d_model)

    _rmsnorm(program, hbm, name="final_norm", x=X, w=model.final_norm, y=NORM, w_addr=WEIGHT_TILE, inv_h=INV_H, eps=EPS, scratch=0x3A00, h=cfg.d_model)
    _quantize(program, NORM, A_BF16, cfg.d_model)
    _linear_tiled(program, hbm, name="lm_head", a_bf16_addr=A_BF16, out_f32_addr=CAT, weight=model.embed.T, vmem_tile_addr=WEIGHT_TILE)

    hbm_out = hbm.reserve_f32("output_logits_tile", tuple(expected.shape))
    program.append(_dma_v2h(hbm_out, CAT, expected.size * 4))
    program.append(barrier(UnitMask.DMA))
    program.append(halt())

    out_dir.mkdir(parents=True, exist_ok=True)
    image_path = out_dir / "weights.hbm"
    manifest_path = out_dir / "weights.manifest.json"
    program_path = out_dir / "program.hex"
    expected_path = out_dir / "expected.npz"
    run_path = out_dir / "run.json"
    image_path.write_bytes(bytes(hbm.image))
    program_path.write_text(emit_hex(program) + "\n", encoding="utf-8")
    np.savez(expected_path, logits_tile=expected)
    run = {
        "workload": "tiny_full_token",
        "qwen_config": asdict(cfg),
        "hbm_image": str(image_path),
        "hbm_bytes": max(_align_up(len(hbm.image), 4096), 1 << 20),
        "program_hex": str(program_path),
        "expected_npz": str(expected_path),
        "output": {"offset": hbm_out, "dtype": "float32", "shape": list(expected.shape), "bytes": expected.size * 4},
        "executable_slice": {"kind": "qwen_tiny_full_token_graph", "m": 1, "k": cfg.d_model, "n": cfg.vocab, "instructions": len(program)},
        "program_instructions": len(program),
        "full_token_cost": per_token_cost(qwen35_0p8b(), tile=128),
    }
    manifest_path.write_text(
        json.dumps({"image_bytes": len(hbm.image), "align": 64, "tensors": {name: asdict(rec) for name, rec in hbm.manifest.items()}}, indent=2),
        encoding="utf-8",
    )
    run_path.write_text(json.dumps(run, indent=2), encoding="utf-8")
    return run


def build_qwen_infer_artifacts(out_dir: str | Path, workload: str = "tiny") -> dict:
    """Emit a self-contained RTL workload bundle.

    The RTL target is a lowered Qwen BF16 kernel run: it uses the selected Qwen
    config metadata, preloads operands through an HBM image, executes an
    instruction-preloaded SwiGLU MLP slice, writes output to HBM, and compares it
    to a numpy golden. The full-token workload uses the real 0.8B dimensions in
    metadata and cost reporting while the executable slice stays bounded enough
    for routine Verilator runs.
    """

    if workload == "tiny_full_token":
        return _build_tiny_full_token_artifacts(Path(out_dir))

    if workload not in {"tiny", "layer_slice", "0p8b_token"}:
        raise ValueError("workload must be one of: tiny, layer_slice, tiny_full_token, 0p8b_token")

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    cfg = qwen35_0p8b() if workload in {"layer_slice", "0p8b_token"} else tiny()
    k = 2 if workload == "tiny" else 4
    n = 4 if workload == "tiny" else 8
    rng = np.random.default_rng({"tiny": 11, "layer_slice": 12, "0p8b_token": 13}[workload])
    x = (rng.standard_normal(k) * 0.5).astype(np.float32)
    wg = (rng.standard_normal((k, n)) * 0.25).astype(np.float32)
    wu = (rng.standard_normal((k, n)) * 0.25).astype(np.float32)
    wd = (rng.standard_normal((n, k)) * 0.25).astype(np.float32)

    gate = _bf16_round(x) @ _bf16_round(wg)
    up = _bf16_round(x) @ _bf16_round(wu)
    hidden = gate * (1.0 / (1.0 + np.exp(-gate))) * up
    expected = (_bf16_round(hidden) @ _bf16_round(wd)).astype(np.float32)

    image = bytearray()
    manifest: dict[str, TensorRecord] = {}
    hbm_x = 0x0000
    hbm_wg = 0x0040
    hbm_wu = 0x0100
    hbm_wd = 0x0200
    hbm_out = 0x0400
    _put_bf16(image, manifest, "decode_input_tile", hbm_x, x)
    _put_bf16(image, manifest, "mlp_gate_proj_tile", hbm_wg, wg)
    _put_bf16(image, manifest, "mlp_up_proj_tile", hbm_wu, wu)
    _put_bf16(image, manifest, "mlp_down_proj_tile", hbm_wd, wd)
    out_bytes = expected.size * 4
    if len(image) < hbm_out + out_bytes:
        image.extend(b"\x00" * (hbm_out + out_bytes - len(image)))
    manifest["output_logits_tile"] = TensorRecord(offset=hbm_out, shape=tuple(expected.shape), count=int(expected.size), dtype="float32")

    vmem_x = 0x0000
    vmem_wg = 0x0040
    vmem_wu = 0x0100
    vmem_wd = 0x0200
    layout = SwiGLULayout(
        x_bf16=vmem_x,
        wg_bf16=vmem_wg,
        wu_bf16=vmem_wu,
        wd_bf16=vmem_wd,
        gate=0x0400,
        up=0x0500,
        h=0x0600,
        h_bf16=0x0700,
        out=0x0800,
        k=k,
        n=n,
    )
    program = [
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_x), src=MemoryRef(AddressSpace.HBM, hbm_x), length=x.size * 2),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_wg), src=MemoryRef(AddressSpace.HBM, hbm_wg), length=wg.size * 2),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_wu), src=MemoryRef(AddressSpace.HBM, hbm_wu), length=wu.size * 2),
        dma_copy(dst=MemoryRef(AddressSpace.VMEM0, vmem_wd), src=MemoryRef(AddressSpace.HBM, hbm_wd), length=wd.size * 2),
        barrier(UnitMask.DMA),
        *_sync_kernel(swiglu_program(layout)),
        dma_copy(dst=MemoryRef(AddressSpace.HBM, hbm_out), src=MemoryRef(AddressSpace.VMEM0, layout.out), length=out_bytes),
        barrier(UnitMask.DMA),
        halt(),
    ]

    image_path = out / "weights.hbm"
    manifest_path = out / "weights.manifest.json"
    program_path = out / "program.hex"
    expected_path = out / "expected.npz"
    run_path = out / "run.json"
    image_path.write_bytes(bytes(image))
    program_path.write_text(emit_hex(program) + "\n", encoding="utf-8")
    np.savez(expected_path, logits_tile=expected)

    run = {
        "workload": workload,
        "qwen_config": asdict(cfg),
        "hbm_image": str(image_path),
        "hbm_bytes": max(_align_up(len(image), 4096), 1 << 20),
        "program_hex": str(program_path),
        "expected_npz": str(expected_path),
        "output": {"offset": hbm_out, "dtype": "float32", "shape": list(expected.shape), "bytes": out_bytes},
        "executable_slice": {"kind": "qwen_swiglu_bf16_kernel", "m": 1, "k": k, "n": n},
        "program_instructions": len(program),
        "full_token_cost": per_token_cost(cfg, tile=int(os.getenv("QWEN_MXU_DIM", "16"))),
    }
    manifest_path.write_text(
        json.dumps(
            {
                "image_bytes": len(image),
                "align": 64,
                "tensors": {name: asdict(rec) for name, rec in manifest.items()},
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    run_path.write_text(json.dumps(run, indent=2), encoding="utf-8")
    return run
