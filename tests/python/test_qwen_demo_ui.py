import time

from virtual_tpu.qwen.demo_ui import DemoState


def test_demo_artifact_job_builds_qwen_bundle(tmp_path):
    state = DemoState(tmp_path)
    job = state.start_job({"mode": "artifact", "workload": "tiny", "mxu_dim": 16})

    deadline = time.time() + 10
    while job.status in {"queued", "running"} and time.time() < deadline:
        time.sleep(0.05)

    assert job.status == "succeeded", job.error
    assert job.result is not None
    assert job.result["run"]["workload"] == "tiny"
    assert job.result["run"]["program_instructions"] > 0
    assert job.result["artifacts"]["program_sha256"]
    assert job.result["expected"]["count"] == job.result["run"]["output"]["shape"][0]
