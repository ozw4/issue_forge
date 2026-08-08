from __future__ import annotations

import os
import shlex
import stat
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "attempt_store.sh"


def test_repeated_history_copy_keeps_compatibility_files_writable(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    compatibility = tmp_path / "checks.log"
    history = tmp_path / "history" / "batch-checks.round-01.log"
    history.parent.mkdir()

    script = f"""
set -euo pipefail
source {shlex.quote(str(HELPER))}
first_dir=''; first_log=''; second_dir=''; second_log=''
run_logged_attempt first_dir first_log \
  {shlex.quote(str(attempts))} batch-checks 1 check none none \
  {shlex.quote(str(compatibility))} combined -- \
  bash -c 'printf "first\\n"'
cp {shlex.quote(str(compatibility))} {shlex.quote(str(history))}
run_logged_attempt second_dir second_log \
  {shlex.quote(str(attempts))} batch-checks 1 check none none \
  {shlex.quote(str(compatibility))} combined -- \
  bash -c 'printf "second\\n"'
cp {shlex.quote(str(compatibility))} {shlex.quote(str(history))}
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
    assert compatibility.read_text(encoding="utf-8") == "second\n"
    assert history.read_text(encoding="utf-8") == "second\n"
    assert compatibility.stat().st_mode & stat.S_IWUSR
    assert history.stat().st_mode & stat.S_IWUSR
