import json

import numpy as np

from virtual_tpu.isa import Instruction, Opcode
from virtual_tpu.qwen.rtl_artifacts import build_qwen_infer_artifacts


def test_qwen_rtl_artifact_bundle(tmp_path):
    run = build_qwen_infer_artifacts(tmp_path, "tiny")
    assert set(run) >= {"hbm_image", "program_hex", "expected_npz", "output", "qwen_config"}

    image = tmp_path / "weights.hbm"
    manifest = json.loads((tmp_path / "weights.manifest.json").read_text())
    program = (tmp_path / "program.hex").read_text().strip().splitlines()
    expected = np.load(tmp_path / "expected.npz")["logits_tile"]

    assert image.exists() and image.stat().st_size >= run["output"]["offset"] + run["output"]["bytes"]
    assert set(manifest["tensors"]) >= {
        "decode_input_tile",
        "mlp_gate_proj_tile",
        "mlp_up_proj_tile",
        "mlp_down_proj_tile",
        "output_logits_tile",
    }
    assert run["executable_slice"]["kind"] == "qwen_swiglu_bf16_kernel"
    assert run["output"]["dtype"] == "float32"
    assert expected.shape == tuple(run["output"]["shape"])
    assert Instruction.from_hex(program[-1]).opcode_enum is Opcode.HALT


def test_qwen_0p8b_artifact_uses_full_shape_sparse_stream(tmp_path, monkeypatch):
    monkeypatch.setenv("QWEN_MXU_DIM", "128")
    run = build_qwen_infer_artifacts(tmp_path, "0p8b_token")
    program = (tmp_path / "program.hex").read_text().strip().splitlines()

    assert run["workload"] == "0p8b_token"
    assert run["qwen_config"]["d_model"] == 1024
    assert run["executable_slice"]["tile"] == 128
    assert run["executable_slice"]["matmul_instructions"] == run["full_token_cost"]["matmul_instr"]
    assert run["program_instructions"] > 4096
    assert len(program) == run["program_instructions"]
    assert (tmp_path / "weights.hbm").stat().st_size < 128 * 1024
    assert Instruction.from_hex(program[-1]).opcode_enum is Opcode.HALT


def test_qwen_0p8b_autoregressive_artifact_metadata(tmp_path, monkeypatch):
    monkeypatch.setenv("QWEN_MXU_DIM", "128")
    monkeypatch.setenv("QWEN_DECODE_STEPS", "3")
    monkeypatch.setenv("QWEN_PROMPT_TOKEN", "17")
    run = build_qwen_infer_artifacts(tmp_path, "0p8b_autoregressive")

    assert run["workload"] == "0p8b_autoregressive"
    assert run["autoregressive"]["prompt_tokens"] == [17]
    assert run["autoregressive"]["decode_steps"] == 3
    assert run["autoregressive"]["expected_generated_tokens"] == [17, 0, 0, 0]
    assert run["executable_slice"]["matmul_instructions"] == run["full_token_cost"]["matmul_instr"]
