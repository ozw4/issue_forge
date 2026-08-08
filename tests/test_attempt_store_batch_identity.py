from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "attempt_store.sh"


def read_state(path: Path) -> dict[str, str]:
    return dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines())


def attempt_dirs(root: Path) -> list[Path]:
    return sorted(path for path in root.iterdir() if path.is_dir() and path.name not in {"latest", "pending"})


def test_same_batch_range_uses_separate_run_attempt_stores(tmp_path: Path) -> None:
    queue = tmp_path / ".work" / "queue"
    compatibility_root = queue / "batches" / "batch-10-12" / "attempts"
    compatibility_log = queue / "batches" / "batch-10-12" / "checks.log"
    runs = queue / "runs"

    script = f"""
set -euo pipefail
source {shlex.quote(str(HELPER))}

run_one() {{
  local run_id="$1"
  local run_state_dir={shlex.quote(str(runs))}/"$run_id"
  local current_batch_id='batch-10-12'
  local attempt_dir=''
  local attempt_log=''
  mkdir -p "$run_state_dir/batches/$current_batch_id"
  run_logged_attempt attempt_dir attempt_log \
    {shlex.quote(str(compatibility_root))} batch-checks 1 check none none \
    {shlex.quote(str(compatibility_log))} combined -- \
    bash -c 'printf "checks\\n"'
}}

run_one run-a
run_one run-b
"""
    result = subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )

    assert result.returncode == 0, result.stderr
    assert not compatibility_root.exists()

    for run_id in ("run-a", "run-b"):
        attempts_root = runs / run_id / "batches" / "batch-10-12" / "attempts"
        [attempt] = attempt_dirs(attempts_root)
        identity = read_state(attempt / "input.state")
        latest = read_state(attempts_root / "latest" / "batch-checks.state")

        assert identity["run_id"] == run_id
        assert identity["scope"] == "batch"
        assert identity["scope_id"] == "batch-10-12"
        assert latest["attempt_id"] == attempt.name
