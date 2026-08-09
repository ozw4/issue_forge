from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

import pytest


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "attempt_store.sh"


def run_bash(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail\nsource {shlex.quote(str(HELPER))}\n{body}"],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )


def read_state(path: Path) -> dict[str, str]:
    return dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines())


@pytest.mark.parametrize(
    ("phase", "raw_name", "parsed_name"),
    [
        ("review", "review.raw.txt", "review.txt"),
        ("batch-review", "batch-review.raw.txt", "batch-review.txt"),
    ],
)
def test_worktree_change_does_not_publish_review_attempt(
    tmp_path: Path,
    phase: str,
    raw_name: str,
    parsed_name: str,
) -> None:
    attempts = tmp_path / "attempts"
    raw_compatibility = tmp_path / raw_name
    parsed_compatibility = tmp_path / parsed_name
    tracked = tmp_path / "tracked.txt"
    tracked.write_text("baseline\n", encoding="utf-8")

    result = run_bash(
        tmp_path,
        f"""
status_outside_work() {{
  cat {shlex.quote(str(tracked))}
}}
extract_structured_review_output_file() {{
  local raw="$1" parsed="$2"
  grep -Fxq 'valid review' "$raw" || return 1
  printf 'parsed review\\n' > "$parsed"
}}

first_dir=''; first_log=''
run_logged_attempt first_dir first_log \\
  {shlex.quote(str(attempts))} {phase} 1 read high none {shlex.quote(str(raw_compatibility))} combined -- \\
  bash -c 'printf "valid review\\n"'

second_dir=''; second_log=''; second_status=0
run_logged_attempt second_dir second_log \\
  {shlex.quote(str(attempts))} {phase} 2 read high none {shlex.quote(str(raw_compatibility))} combined -- \\
  bash -c 'printf "changed\\n" > {shlex.quote(str(tracked))}; printf "valid review\\n"' || second_status=$?
printf '%s\\n%s\\n%s\\n' "$second_status" "$first_dir" "$second_dir"
""",
    )

    assert result.returncode == 0, result.stderr
    second_status, first_dir_value, second_dir_value = result.stdout.splitlines()
    assert second_status == "1"

    first_dir = Path(first_dir_value)
    second_dir = Path(second_dir_value)
    latest = attempts / "latest" / f"{phase}.state"

    assert raw_compatibility.read_text(encoding="utf-8") == "valid review\n"
    assert parsed_compatibility.read_text(encoding="utf-8") == "parsed review\n"
    assert read_state(latest)["attempt_id"] == first_dir.name

    invalid_state = read_state(second_dir / "result.state")
    assert invalid_state["status"] == "invalid"
    assert invalid_state["exit_status"] == "0"
    assert invalid_state["parser_status"] == "not_applicable"
    assert invalid_state["parsed_path"] == "none"
    assert (second_dir / "output.log").read_text(encoding="utf-8") == "valid review\n"
    assert not (second_dir / "parsed-review.txt").exists()
    assert not (attempts / "pending" / f"{phase}.state").exists()
    assert "modified repository files" in result.stderr
