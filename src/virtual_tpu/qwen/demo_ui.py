"""Local web UI for Qwen inference bring-up on the vTPU chip simulator."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import traceback
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import numpy as np

from virtual_tpu.qwen.rtl_artifacts import build_qwen_infer_artifacts


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BUILD_ROOT = REPO_ROOT / "sim_build" / "qwen_demo_ui"
WORKLOADS = {
    "tiny": {
        "label": "Tiny SwiGLU slice",
        "description": "Fast BF16 MLP kernel bundle for smoke demos.",
        "rtl": True,
    },
    "layer_slice": {
        "label": "0.8B metadata slice",
        "description": "Small executable slice with Qwen3.5-0.8B config metadata.",
        "rtl": True,
    },
    "tiny_full_token": {
        "label": "Tiny full-token graph",
        "description": "Architecturally complete tiny decoder token graph.",
        "rtl": True,
    },
    "0p8b_token": {
        "label": "0.8B full-shape token stream",
        "description": "Full-shape sparse matmul stream for fast BF16 RTL harnessing.",
        "rtl": True,
    },
    "0p8b_autoregressive": {
        "label": "0.8B autoregressive stream",
        "description": "Full-shape sparse decode metadata with generated token checks.",
        "rtl": True,
    },
    "0p8b_real_lm_head": {
        "label": "Real checkpoint LM head",
        "description": "Selected-logit BF16 matmul from local safetensors checkpoint.",
        "rtl": True,
    },
    "0p8b_real_mlp": {
        "label": "Real checkpoint MLP block",
        "description": "Layer MLP slice from local safetensors checkpoint.",
        "rtl": True,
    },
}


@dataclass
class DemoJob:
    id: str
    mode: str
    workload: str
    status: str = "queued"
    started_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    result: dict[str, Any] | None = None
    error: str | None = None
    log: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "mode": self.mode,
            "workload": self.workload,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "elapsed": (self.finished_at or time.time()) - self.started_at,
            "result": self.result,
            "error": self.error,
            "log": self.log[-20000:],
        }


class DemoState:
    def __init__(self, build_root: Path):
        self.build_root = build_root
        self.jobs: dict[str, DemoJob] = {}
        self.active_job_id: str | None = None
        self.lock = threading.Lock()

    def start_job(self, payload: dict[str, Any]) -> DemoJob:
        workload = _coerce_workload(payload.get("workload"))
        mode = str(payload.get("mode", "artifact")).strip()
        if mode not in {"artifact", "rtl"}:
            raise ValueError("mode must be artifact or rtl")

        with self.lock:
            if self.active_job_id:
                active = self.jobs.get(self.active_job_id)
                if active and active.status in {"queued", "running"}:
                    raise RuntimeError("another demo job is already running")
            job = DemoJob(id=uuid.uuid4().hex[:12], mode=mode, workload=workload)
            self.jobs[job.id] = job
            self.active_job_id = job.id

        thread = threading.Thread(target=self._run_job, args=(job, payload), daemon=True)
        thread.start()
        return job

    def _run_job(self, job: DemoJob, payload: dict[str, Any]) -> None:
        job.status = "running"
        try:
            env = _job_env(payload)
            out_dir = self.build_root / job.id / job.workload
            if job.mode == "artifact":
                started = time.time()
                with _temporary_env(env):
                    run = build_qwen_infer_artifacts(out_dir, job.workload)
                job.result = _summarize_artifacts(run, started)
                job.log = _artifact_log(job.result)
            else:
                job.result = _run_rtl(job, env)
            job.status = "succeeded"
        except Exception as exc:  # pragma: no cover - surfaced through UI
            job.status = "failed"
            job.error = str(exc)
            job.log = (job.log + "\n" + traceback.format_exc()).strip()
        finally:
            job.finished_at = time.time()
            with self.lock:
                if self.active_job_id == job.id:
                    self.active_job_id = None

    def get_job(self, job_id: str) -> DemoJob | None:
        with self.lock:
            return self.jobs.get(job_id)

    def status(self) -> dict[str, Any]:
        with self.lock:
            latest = next(reversed(self.jobs.values()), None) if self.jobs else None
            active = self.jobs.get(self.active_job_id) if self.active_job_id else None
        return {
            "workloads": WORKLOADS,
            "build_root": str(self.build_root),
            "repo_root": str(REPO_ROOT),
            "active_job": active.to_json() if active else None,
            "latest_job": latest.to_json() if latest else None,
        }


class DemoHandler(BaseHTTPRequestHandler):
    server_version = "QwenDemoUI/0.1"

    @property
    def demo_state(self) -> DemoState:
        return self.server.demo_state  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path in {"/", "/index.html"}:
            self._send_html(INDEX_HTML)
            return
        if path == "/api/status":
            self._send_json(self.demo_state.status())
            return
        if path.startswith("/api/job/"):
            job_id = path.rsplit("/", 1)[-1]
            job = self.demo_state.get_job(job_id)
            if not job:
                self._send_json({"error": "job not found"}, HTTPStatus.NOT_FOUND)
                return
            self._send_json(job.to_json())
            return
        self._send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path != "/api/run":
            self._send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        try:
            payload = self._read_json()
            job = self.demo_state.start_job(payload)
            self._send_json(job.to_json(), HTTPStatus.ACCEPTED)
        except RuntimeError as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.CONFLICT)
        except Exception as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise ValueError("JSON body must be an object")
        return data

    def _send_html(self, body: str, status: HTTPStatus = HTTPStatus.OK) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_json(self, body: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        payload = json.dumps(body, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class DemoServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], build_root: Path):
        super().__init__(server_address, DemoHandler)
        self.demo_state = DemoState(build_root)

    def server_bind(self) -> None:
        # HTTPServer does a reverse DNS lookup for server_name; keep localhost
        # startup instant and deterministic on machines with slow DNS.
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


def _coerce_workload(value: Any) -> str:
    workload = str(value or "tiny").strip()
    if workload not in WORKLOADS:
        raise ValueError(f"unknown workload: {workload}")
    return workload


def _job_env(payload: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    env["PYTHONPATH"] = f"{REPO_ROOT / 'src'}:{REPO_ROOT}:{REPO_ROOT / 'tests/cocotb'}"
    env["QWEN_WORKLOAD"] = _coerce_workload(payload.get("workload"))

    for src, dst in [
        ("mxu_dim", "QWEN_MXU_DIM"),
        ("decode_steps", "QWEN_DECODE_STEPS"),
        ("prompt_token", "QWEN_PROMPT_TOKEN"),
        ("layer", "QWEN_LAYER"),
        ("mlp_intermediate", "QWEN_MLP_INTERMEDIATE"),
        ("mlp_out_dim", "QWEN_MLP_OUT_DIM"),
    ]:
        if payload.get(src) not in {None, ""}:
            env[dst] = str(int(payload[src]))

    selected_logits = str(payload.get("selected_logits", "")).strip()
    if selected_logits:
        parts = [str(int(part.strip())) for part in selected_logits.split(",") if part.strip()]
        env["QWEN_SELECTED_LOGITS"] = ",".join(parts)

    model_dir = str(payload.get("model_dir", "")).strip()
    if model_dir:
        env["QWEN_MODEL_DIR"] = model_dir

    if payload.get("fast_bf16") not in {None, ""}:
        env["FAST_BF16_MXU"] = "1" if payload.get("fast_bf16") else "0"
    if payload.get("zero_shortcut") not in {None, ""}:
        env["FAST_BF16_ZERO_TILE_SHORTCUT"] = "1" if payload.get("zero_shortcut") else "0"
    return env


@contextmanager
def _temporary_env(env: dict[str, str]):
    changed = {key: value for key, value in env.items() if key.startswith("QWEN_")}
    old = {key: os.environ.get(key) for key in changed}
    try:
        os.environ.update(changed)
        yield
    finally:
        for key, value in old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _run_rtl(job: DemoJob, env: dict[str, str]) -> dict[str, Any]:
    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "-q",
        "tests/rtl/test_qwen_inference_runner.py",
        "-s",
    ]
    started = time.time()
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    job.log = (proc.stdout + "\n" + proc.stderr).strip()
    if proc.returncode != 0:
        raise RuntimeError(f"RTL simulator exited with status {proc.returncode}")

    build_dir = _latest_qwen_build_dir(job.workload, env)
    run_path = build_dir / "run.json"
    if not run_path.exists():
        raise RuntimeError(f"RTL run completed, but {run_path} was not found")
    run = json.loads(run_path.read_text(encoding="utf-8"))
    summary = _summarize_artifacts(run, started)
    summary["rtl"] = {
        "command": " ".join(cmd),
        "returncode": proc.returncode,
        "harness": _parse_harness(job.log),
    }
    return summary


def _latest_qwen_build_dir(workload: str, env: dict[str, str]) -> Path:
    token_workload = workload in {
        "tiny_full_token",
        "0p8b_token",
        "0p8b_autoregressive",
        "0p8b_real_lm_head",
        "0p8b_real_mlp",
    }
    mxu_dim = int(env.get("QWEN_MXU_DIM", "128" if token_workload else "16"))
    fast_bf16 = env.get("FAST_BF16_MXU", "1" if token_workload else "0") == "1"
    zero_shortcut = env.get(
        "FAST_BF16_ZERO_TILE_SHORTCUT",
        "1" if workload in {"0p8b_token", "0p8b_autoregressive"} else "0",
    ) == "1"
    return REPO_ROOT / "sim_build" / "qwen_infer" / f"{workload}_mxu{mxu_dim}_fast{int(fast_bf16)}_zero{int(zero_shortcut)}"


def _summarize_artifacts(run: dict[str, Any], started: float) -> dict[str, Any]:
    program_path = Path(run["program_hex"])
    hbm_path = Path(run["hbm_image"])
    expected_path = Path(run["expected_npz"])
    manifest_path = hbm_path.with_name("weights.manifest.json")
    program_lines = program_path.read_text(encoding="utf-8").strip().splitlines()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    expected = _expected_summary(expected_path)
    program_digest = hashlib.sha256(program_path.read_bytes()).hexdigest()[:16]
    hbm_digest = hashlib.sha256(hbm_path.read_bytes()).hexdigest()[:16]
    return {
        "run": run,
        "elapsed": time.time() - started,
        "artifacts": {
            "run_json": str(Path(run["program_hex"]).with_name("run.json")),
            "hbm_image": str(hbm_path),
            "program_hex": str(program_path),
            "expected_npz": str(expected_path),
            "manifest": str(manifest_path),
            "program_sha256": program_digest,
            "hbm_sha256": hbm_digest,
            "program_head": program_lines[:5],
            "program_tail": program_lines[-5:],
            "manifest_tensors": sorted((manifest.get("tensors") or {}).keys())[:24],
            "manifest_tensor_count": len(manifest.get("tensors") or {}),
            "hbm_file_bytes": hbm_path.stat().st_size,
        },
        "expected": expected,
    }


def _expected_summary(path: Path) -> dict[str, Any]:
    with np.load(path) as data:
        key = "logits_tile" if "logits_tile" in data else data.files[0]
        raw = np.asarray(data[key], dtype=np.float32)
        shape = list(raw.shape)
        arr = raw.reshape(-1)
        selected = data["selected_logits"].astype(int).tolist() if "selected_logits" in data else None
    sample_count = min(12, int(arr.size))
    return {
        "key": key,
        "count": int(arr.size),
        "shape": shape,
        "min": float(np.min(arr)) if arr.size else None,
        "max": float(np.max(arr)) if arr.size else None,
        "mean": float(np.mean(arr)) if arr.size else None,
        "sample": [float(x) for x in arr[:sample_count]],
        "selected_logits": selected,
    }


def _artifact_log(summary: dict[str, Any]) -> str:
    run = summary["run"]
    artifacts = summary["artifacts"]
    expected = summary["expected"]
    lines = [
        "============= Qwen artifact bundle =============",
        f"  workload      : {run['workload']}",
        f"  executable    : {run.get('executable_slice', {}).get('kind', 'unknown')}",
        f"  instructions  : {run.get('program_instructions', 0):,}",
        f"  hbm bytes     : {run.get('hbm_bytes', 0):,}",
        f"  program sha   : {artifacts['program_sha256']}",
        f"  hbm sha       : {artifacts['hbm_sha256']}",
        f"  expected      : {expected['count']:,} float32 values",
        "================================================",
    ]
    return "\n".join(lines)


def _parse_harness(log: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    for raw in log.splitlines():
        line = raw.strip()
        if not line.startswith(("workload", "executable", "decode steps", "generated", "wall", "wall/token", "sim cycles/sec", "cycles", "dma_bytes", "matmul_ops", "vector_ops", "reduce_ops")):
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip().replace(" ", "_")] = value.strip()
    return data


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Run the local Qwen vTPU demo UI.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--build-root", default=str(DEFAULT_BUILD_ROOT))
    args = parser.parse_args(argv)

    build_root = Path(args.build_root).resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    server = DemoServer((args.host, args.port), build_root)
    url = f"http://{args.host}:{server.server_port}"
    print(f"Qwen vTPU demo UI running at {url}")
    print("Press Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Qwen vTPU demo UI.")
    finally:
        server.server_close()


INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Qwen on vTPU chip sim</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f8f5;
      --ink: #1b1f23;
      --muted: #64706b;
      --line: #d9dfd6;
      --panel: #ffffff;
      --panel-2: #f0f5f2;
      --accent: #0f766e;
      --accent-2: #b45309;
      --ok: #15803d;
      --bad: #b91c1c;
      --dark: #101418;
      --code: #111827;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font: 14px/1.45 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    button, input, select, textarea { font: inherit; }
    .shell {
      display: grid;
      grid-template-columns: 360px minmax(0, 1fr);
      min-height: 100vh;
    }
    aside {
      border-right: 1px solid var(--line);
      background: #fbfcfa;
      padding: 22px;
    }
    main { padding: 22px; }
    h1, h2, h3, p { margin: 0; }
    h1 { font-size: 22px; line-height: 1.15; letter-spacing: 0; }
    h2 { font-size: 13px; margin-bottom: 10px; text-transform: uppercase; color: var(--muted); }
    h3 { font-size: 15px; margin-bottom: 8px; }
    .sub { color: var(--muted); margin-top: 7px; }
    .stack { display: grid; gap: 16px; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
    }
    label { display: grid; gap: 6px; color: var(--muted); font-size: 12px; }
    input, select, textarea {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 9px 10px;
      background: white;
      color: var(--ink);
      min-height: 38px;
    }
    textarea { resize: vertical; min-height: 68px; }
    .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    button {
      min-height: 40px;
      border: 1px solid transparent;
      border-radius: 6px;
      cursor: pointer;
      background: var(--dark);
      color: white;
      font-weight: 650;
    }
    button.secondary {
      background: white;
      color: var(--ink);
      border-color: var(--line);
    }
    button:disabled { opacity: .5; cursor: progress; }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 28px;
      padding: 4px 9px;
      border-radius: 999px;
      background: var(--panel-2);
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
    }
    .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--muted);
    }
    .status.running .dot { background: var(--accent-2); }
    .status.succeeded .dot { background: var(--ok); }
    .status.failed .dot { background: var(--bad); }
    .hero {
      display: grid;
      grid-template-columns: minmax(0, 1.2fr) minmax(260px, .8fr);
      gap: 16px;
      align-items: stretch;
      margin-bottom: 16px;
    }
    .metric-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 10px;
    }
    .metric {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      min-height: 86px;
    }
    .metric .label { color: var(--muted); font-size: 12px; }
    .metric .value {
      display: block;
      margin-top: 8px;
      font-size: clamp(17px, 2vw, 24px);
      font-weight: 750;
      overflow-wrap: anywhere;
    }
    .flow {
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      gap: 8px;
    }
    .stage {
      min-height: 74px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      padding: 12px;
      display: grid;
      align-content: center;
      gap: 4px;
    }
    .stage strong { font-size: 13px; }
    .stage span { color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
    .results {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(320px, .75fr);
      gap: 16px;
    }
    pre {
      margin: 0;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      background: var(--code);
      color: #d1fae5;
      border-radius: 8px;
      padding: 14px;
      min-height: 260px;
      max-height: 520px;
      overflow: auto;
      font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    .table {
      display: grid;
      gap: 8px;
    }
    .row {
      display: grid;
      grid-template-columns: 140px minmax(0, 1fr);
      gap: 12px;
      padding-bottom: 8px;
      border-bottom: 1px solid var(--line);
    }
    .row span:first-child { color: var(--muted); }
    .row span:last-child {
      overflow-wrap: anywhere;
      font-size: 13px;
      line-height: 1.35;
    }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 3px 8px;
      background: var(--panel-2);
      color: var(--muted);
      font-size: 12px;
    }
    .hidden { display: none !important; }
    @media (max-width: 980px) {
      .shell { grid-template-columns: 1fr; }
      aside { border-right: 0; border-bottom: 1px solid var(--line); }
      .hero, .results { grid-template-columns: 1fr; }
      .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .flow { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <aside class="stack">
      <section>
        <h1>Qwen inference on the vTPU chip sim</h1>
        <p class="sub">Build a simulator-ready workload bundle, then optionally run the RTL cocotb harness against the virtual chip.</p>
      </section>

      <section class="panel stack">
        <h2>Run Controls</h2>
        <label>Workload
          <select id="workload"></select>
        </label>
        <p id="workloadDescription" class="sub"></p>
        <div class="grid-2">
          <label>MXU dimension
            <input id="mxuDim" type="number" min="1" max="128" value="128" />
          </label>
          <label>Prompt token
            <input id="promptToken" type="number" min="0" value="17" />
          </label>
        </div>
        <div class="grid-2">
          <label>Decode steps
            <input id="decodeSteps" type="number" min="1" max="64" value="3" />
          </label>
          <label>Layer
            <input id="layer" type="number" min="0" max="23" value="0" />
          </label>
        </div>
        <div class="grid-2">
          <label>MLP intermediate
            <input id="mlpIntermediate" type="number" min="1" value="512" />
          </label>
          <label>MLP out dim
            <input id="mlpOutDim" type="number" min="1" value="128" />
          </label>
        </div>
        <label>Selected logits
          <input id="selectedLogits" value="0,1,42,248319" />
        </label>
        <label>Model dir
          <input id="modelDir" placeholder="optional local Qwen checkpoint path" />
        </label>
        <div class="actions">
          <button id="artifactBtn">Build bundle</button>
          <button class="secondary" id="rtlBtn">Run RTL sim</button>
        </div>
      </section>

      <section class="panel">
        <h2>Job</h2>
        <div id="status" class="status"><i class="dot"></i><span>Idle</span></div>
        <p id="jobMeta" class="sub" style="margin-top: 10px;">No run yet.</p>
      </section>
    </aside>

    <main>
      <section class="hero">
        <div class="panel stack">
          <h2>Simulator Path</h2>
          <div class="flow">
            <div class="stage"><strong>Host</strong><span>run metadata + ISA hex</span></div>
            <div class="stage"><strong>HBM</strong><span>bf16 tensor image</span></div>
            <div class="stage"><strong>VMEM</strong><span>DMA tile staging</span></div>
            <div class="stage"><strong>MXU/VPU</strong><span>Qwen kernels</span></div>
            <div class="stage"><strong>Logits</strong><span>HBM output compare</span></div>
          </div>
        </div>
        <div class="panel">
          <h2>Artifacts</h2>
          <div id="artifactTable" class="table"></div>
        </div>
      </section>

      <section class="metric-grid" style="margin-bottom: 16px;">
        <div class="metric"><span class="label">Instructions</span><span id="instructions" class="value">-</span></div>
        <div class="metric"><span class="label">MACs/token</span><span id="macs" class="value">-</span></div>
        <div class="metric"><span class="label">HBM bytes</span><span id="hbmBytes" class="value">-</span></div>
        <div class="metric"><span class="label">Elapsed</span><span id="elapsed" class="value">-</span></div>
      </section>

      <section class="results">
        <div class="panel stack">
          <h2>Run Log</h2>
          <pre id="log">Ready.</pre>
        </div>
        <div class="panel stack">
          <h2>Output</h2>
          <div id="outputTable" class="table"></div>
          <div>
            <h3>Expected sample</h3>
            <div id="sample" class="chips"></div>
          </div>
          <div>
            <h3>Manifest tensors</h3>
            <div id="tensors" class="chips"></div>
          </div>
        </div>
      </section>
    </main>
  </div>

  <script>
    const els = {
      workload: document.querySelector("#workload"),
      workloadDescription: document.querySelector("#workloadDescription"),
      mxuDim: document.querySelector("#mxuDim"),
      promptToken: document.querySelector("#promptToken"),
      decodeSteps: document.querySelector("#decodeSteps"),
      layer: document.querySelector("#layer"),
      mlpIntermediate: document.querySelector("#mlpIntermediate"),
      mlpOutDim: document.querySelector("#mlpOutDim"),
      selectedLogits: document.querySelector("#selectedLogits"),
      modelDir: document.querySelector("#modelDir"),
      artifactBtn: document.querySelector("#artifactBtn"),
      rtlBtn: document.querySelector("#rtlBtn"),
      status: document.querySelector("#status"),
      jobMeta: document.querySelector("#jobMeta"),
      artifactTable: document.querySelector("#artifactTable"),
      outputTable: document.querySelector("#outputTable"),
      instructions: document.querySelector("#instructions"),
      macs: document.querySelector("#macs"),
      hbmBytes: document.querySelector("#hbmBytes"),
      elapsed: document.querySelector("#elapsed"),
      log: document.querySelector("#log"),
      sample: document.querySelector("#sample"),
      tensors: document.querySelector("#tensors")
    };
    let workloads = {};
    let pollTimer = null;

    const fmt = new Intl.NumberFormat();
    const fmtSmall = new Intl.NumberFormat(undefined, { maximumFractionDigits: 3 });

    async function init() {
      const status = await fetchJson("/api/status");
      workloads = status.workloads;
      for (const [key, meta] of Object.entries(workloads)) {
        const option = document.createElement("option");
        option.value = key;
        option.textContent = meta.label;
        els.workload.append(option);
      }
      els.workload.value = "tiny";
      updateDescription();
      els.workload.addEventListener("change", updateDescription);
      els.artifactBtn.addEventListener("click", () => run("artifact"));
      els.rtlBtn.addEventListener("click", () => run("rtl"));
      renderEmpty(status);
    }

    function updateDescription() {
      const meta = workloads[els.workload.value] || {};
      els.workloadDescription.textContent = meta.description || "";
      const tokenWorkload = ["tiny_full_token", "0p8b_token", "0p8b_autoregressive", "0p8b_real_lm_head", "0p8b_real_mlp"].includes(els.workload.value);
      els.mxuDim.value = tokenWorkload ? 128 : 16;
    }

    async function run(mode) {
      setBusy(true);
      clearInterval(pollTimer);
      const payload = {
        mode,
        workload: els.workload.value,
        mxu_dim: numberValue(els.mxuDim),
        prompt_token: numberValue(els.promptToken),
        decode_steps: numberValue(els.decodeSteps),
        layer: numberValue(els.layer),
        mlp_intermediate: numberValue(els.mlpIntermediate),
        mlp_out_dim: numberValue(els.mlpOutDim),
        selected_logits: els.selectedLogits.value,
        model_dir: els.modelDir.value
      };
      try {
        const job = await fetchJson("/api/run", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        renderJob(job);
        pollTimer = setInterval(() => poll(job.id), 1000);
        await poll(job.id);
      } catch (error) {
        setBusy(false);
        setStatus("failed", "Failed");
        els.log.textContent = String(error.message || error);
      }
    }

    async function poll(id) {
      const job = await fetchJson(`/api/job/${id}`);
      renderJob(job);
      if (!["queued", "running"].includes(job.status)) {
        clearInterval(pollTimer);
        setBusy(false);
      }
    }

    function renderJob(job) {
      setStatus(job.status, job.status[0].toUpperCase() + job.status.slice(1));
      els.jobMeta.textContent = `${job.mode} / ${job.workload} / ${fmtSmall.format(job.elapsed)}s`;
      els.elapsed.textContent = `${fmtSmall.format(job.elapsed)}s`;
      els.log.textContent = job.error ? `${job.error}\n\n${job.log || ""}` : (job.log || "Running...");
      if (job.result) renderResult(job.result);
    }

    function renderResult(result) {
      const run = result.run || {};
      const slice = run.executable_slice || {};
      const cost = run.full_token_cost || {};
      const artifacts = result.artifacts || {};
      const expected = result.expected || {};
      els.instructions.textContent = fmt.format(run.program_instructions || slice.matmul_instructions || cost.total_instr || 0);
      els.macs.textContent = cost.macs ? fmt.format(cost.macs) : (slice.macs ? fmt.format(slice.macs) : "-");
      els.hbmBytes.textContent = fmt.format(run.hbm_bytes || artifacts.hbm_file_bytes || 0);
      table(els.artifactTable, [
        ["Workload", run.workload || "-"],
        ["Executable", slice.kind || "-"],
        ["Program SHA", artifacts.program_sha256 || "-"],
        ["HBM SHA", artifacts.hbm_sha256 || "-"],
        ["Build root", artifacts.run_json || "-"]
      ]);
      table(els.outputTable, [
        ["Output dtype", (run.output || {}).dtype || "-"],
        ["Output shape", JSON.stringify((run.output || {}).shape || [])],
        ["Logit count", fmt.format(expected.count || 0)],
        ["Range", expected.min == null ? "-" : `${fmtSmall.format(expected.min)} to ${fmtSmall.format(expected.max)}`],
        ["Mean", expected.mean == null ? "-" : fmtSmall.format(expected.mean)]
      ]);
      chips(els.sample, (expected.sample || []).map(x => fmtSmall.format(x)));
      chips(els.tensors, artifacts.manifest_tensors || []);
    }

    function renderEmpty(status) {
      table(els.artifactTable, [
        ["Repo", status.repo_root],
        ["Build root", status.build_root],
        ["Harness", "tests/rtl/test_qwen_inference_runner.py"]
      ]);
      table(els.outputTable, [["No output", "Run a bundle or RTL sim."]]);
    }

    function table(node, rows) {
      node.innerHTML = "";
      for (const [key, value] of rows) {
        const row = document.createElement("div");
        row.className = "row";
        row.innerHTML = `<span></span><span></span>`;
        row.children[0].textContent = key;
        row.children[1].textContent = value;
        node.append(row);
      }
    }

    function chips(node, values) {
      node.innerHTML = "";
      if (!values.length) {
        const empty = document.createElement("span");
        empty.className = "chip";
        empty.textContent = "-";
        node.append(empty);
        return;
      }
      for (const value of values) {
        const chip = document.createElement("span");
        chip.className = "chip";
        chip.textContent = value;
        node.append(chip);
      }
    }

    function numberValue(input) {
      return input.value === "" ? null : Number(input.value);
    }

    function setBusy(isBusy) {
      els.artifactBtn.disabled = isBusy;
      els.rtlBtn.disabled = isBusy;
    }

    function setStatus(status, label) {
      els.status.className = `status ${status}`;
      els.status.querySelector("span").textContent = label;
    }

    async function fetchJson(url, options) {
      const response = await fetch(url, options);
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || response.statusText);
      return body;
    }

    init().catch(error => {
      setStatus("failed", "Failed");
      els.log.textContent = String(error.message || error);
    });
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
