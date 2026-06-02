import os
from pathlib import Path


def env_flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def waves_enabled() -> bool:
    return env_flag("WAVES", False)


def rebuild_enabled() -> bool:
    return env_flag("REBUILD", False)


def verilator_build_args(repo: Path, *extra: str, optimize: bool = False) -> list[str]:
    args = ["-I" + str(repo / "rtl/common"), "--Wno-UNUSEDPARAM", "--Wno-UNUSEDSIGNAL"]
    if optimize:
        args.append("-O3")
    threads = os.getenv("VERILATOR_THREADS")
    if threads:
        args += ["--threads", threads]
    args += list(extra)
    return args
