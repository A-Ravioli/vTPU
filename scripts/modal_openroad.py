from __future__ import annotations

import os
import shutil
import subprocess
import tarfile
import time
from pathlib import Path

import modal


APP_NAME = "vtpu-openroad-flow"
ARTIFACT_VOLUME_NAME = "vtpu-openroad-artifacts"

REPO_ROOT = Path(__file__).resolve().parents[1]
REMOTE_REPO = Path("/work/vTPU")
REMOTE_FLOW = Path("/OpenROAD-flow-scripts/flow")
REMOTE_ARTIFACTS = Path("/artifacts")

TARGETS = {
    "full": "physical/openroad/designs/sky130hd/vtpu_pd_full/config.mk",
    "tiny": "physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk",
    "smoke": "physical/openroad/designs/sky130hd/vtpu_pd_smoke/config.mk",
    "mxu": "physical/openroad/designs/sky130hd/vtpu_pd_mxu_gds/config.mk",
}

DESIGN_NICKNAMES = {
    "full": "vtpu_pd_full",
    "tiny": "vtpu_pd_tiny",
    "smoke": "vtpu_pd_smoke",
    "mxu": "vtpu_pd_mxu_gds",
}

STEPS = {
    "all": "",
    "floorplan": "do-2_1_floorplan",
    "synth": "do-yosys",
    "canonicalize": "do-yosys-canonicalize",
}


def _ignore_upload(path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(REPO_ROOT)
    except ValueError:
        rel = path
    parts = set(rel.parts)
    return bool(
        parts
        & {
            ".git",
            ".venv",
            ".pytest_cache",
            "__pycache__",
            "sim_build",
            "obj_dir",
            "virtual_tpu.egg-info",
            "results",
        }
    )


image = (
    modal.Image.from_registry("openroad/orfs:latest", add_python="3.11")
    .add_local_dir(REPO_ROOT, str(REMOTE_REPO), ignore=_ignore_upload)
)

artifacts = modal.Volume.from_name(ARTIFACT_VOLUME_NAME, create_if_missing=True)
app = modal.App(APP_NAME, image=image, volumes={str(REMOTE_ARTIFACTS): artifacts})


def _run(command: list[str], *, cwd: Path, env: dict[str, str]) -> int:
    print(f"+ {' '.join(command)}", flush=True)
    proc = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        print(line, end="", flush=True)
    return proc.wait()


def _archive_run(target: str, step: str, started_at: str) -> str:
    run_name = f"{target}_{step}_{started_at}"
    out_dir = REMOTE_ARTIFACTS / run_name
    out_dir.mkdir(parents=True, exist_ok=True)

    design_nickname = DESIGN_NICKNAMES[target]
    design_results = REMOTE_FLOW / "results/sky130hd" / design_nickname / "base"
    design_logs = REMOTE_FLOW / "logs/sky130hd" / design_nickname / "base"
    design_reports = REMOTE_FLOW / "reports/sky130hd" / design_nickname / "base"

    for name, src in (("results", design_results), ("logs", design_logs), ("reports", design_reports)):
        dst = out_dir / name
        if src.exists():
            shutil.copytree(src, dst, dirs_exist_ok=True)

    gds_files = sorted((out_dir / "results").glob("*.gds")) if (out_dir / "results").exists() else []
    summary = out_dir / "SUMMARY.txt"
    summary.write_text(
        "\n".join(
            [
                f"target={target}",
                f"step={step}",
                f"started_at={started_at}",
                f"gds_count={len(gds_files)}",
                *[f"gds={path}" for path in gds_files],
                "",
            ]
        ),
        encoding="utf-8",
    )

    tar_path = REMOTE_ARTIFACTS / f"{run_name}.tar.gz"
    with tarfile.open(tar_path, "w:gz") as tar:
        tar.add(out_dir, arcname=run_name)
    artifacts.commit()
    return str(tar_path)


def _run_openroad_impl(target: str = "full", step: str = "all") -> dict[str, object]:
    if target not in TARGETS:
        raise ValueError(f"unknown target {target!r}; expected one of {sorted(TARGETS)}")
    if step not in STEPS:
        raise ValueError(f"unknown step {step!r}; expected one of {sorted(STEPS)}")

    started_at = time.strftime("%Y%m%d_%H%M%S")
    design_config = REMOTE_REPO / TARGETS[target]
    make_target = STEPS[step]
    env = os.environ.copy()
    env["OPENROAD_FLOW_ROOT"] = str(REMOTE_FLOW)

    final_report = REMOTE_FLOW / "scripts/final_report.tcl"
    if final_report.exists():
        text = final_report.read_text(encoding="utf-8")
        text = text.replace("if { [ord::openroad_gui_compiled] } {", "if { 0 && [ord::openroad_gui_compiled] } {")
        final_report.write_text(text, encoding="utf-8")

    command = ["bash", "-lc", "source /OpenROAD-flow-scripts/env.sh && " + " ".join(
        part
        for part in [
            "make",
            f"DESIGN_CONFIG={design_config}",
            make_target,
        ]
        if part
    )]
    code = _run(command, cwd=REMOTE_FLOW, env=env)
    archive = _archive_run(target, step, started_at)
    return {"exit_code": code, "artifact_tar": archive, "target": target, "step": step}


@app.function(cpu=32, memory=131072, ephemeral_disk=524288, timeout=24 * 60 * 60)
def run_openroad_large(target: str = "full", step: str = "all") -> dict[str, object]:
    return _run_openroad_impl(target=target, step=step)


@app.function(cpu=8, memory=32768, ephemeral_disk=524288, timeout=6 * 60 * 60)
def run_openroad_small(target: str = "mxu", step: str = "all") -> dict[str, object]:
    return _run_openroad_impl(target=target, step=step)


@app.local_entrypoint()
def main(target: str = "full", step: str = "all"):
    if target == "full":
        result = run_openroad_large.remote(target=target, step=step)
    else:
        result = run_openroad_small.remote(target=target, step=step)
    print(result)
