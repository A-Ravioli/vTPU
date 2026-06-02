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
