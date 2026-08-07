from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "queue_manual_review_guard.sh"


def write_run_state(path: Path, state: str = "manual_review_required") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "schema_version\t3\n"
        "run_id\trun-a\n"
        f"state\t{state}\n"
        "updated_at\t2026-08-08T00:00:00Z\n",
        encoding="utf-8",
    )


def write_report(path: Path, *, run_id: str = "run-a", phase: str = "issue_flow") -> None:
    path.write_text(
        "schema_version\t3\n"
        f"run_id\t{run_id}\n"
        f"phase\t{phase}\n"
        "dirty_paths_begin\n"
        " M target.txt\n"
        "dirty_paths_end\n",
        encoding="utf-8",
    )


def write_checkpoint(path: Path, phase: str = "issue_flow") -> None:
    path.write_text(
        "schema_version\t3\n"
        "run_id\trun-a\n"
        "entity\trun\n"
        f"phase\t{phase}\n"
        "status\tfailed\n"
        "updated_at\t2026-08-08T00:00:00Z\n",
        encoding="utf-8",
    )


def invoke(
    tmp_path: Path,
    *,
    dirty: str,
    body: str,
) -> subprocess.CompletedProcess[str]:
    run_dir = tmp_path / "run"
    state_file = run_dir / "run.state"
    checkpoint_file = run_dir / "checkpoint.state"
    transition_log = tmp_path / "transition.log"
    script = f"""
set -euo pipefail
readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION=3
STATE_FILE={shlex.quote(str(state_file))}
CHECKPOINT_FILE={shlex.quote(str(checkpoint_file))}
TRANSITION_LOG={shlex.quote(str(transition_log))}
queue_state_require_singleton_path() {{
  local path="$1" requirement="${{2:-optional}}"
  [[ ! -L "$path" ]] || return 1
  if [[ ! -e "$path" ]]; then
    [[ "$requirement" == optional ]]
    return
  fi
  [[ -f "$path" ]]
}}
queue_state_validate_file() {{ [[ -f "$1" && ! -L "$1" ]]; }}
queue_state_read_field() {{
  awk -F '\\t' -v requested="$3" '$1 == requested {{ print $2; exit }}' "$1"
}}
queue_state_transition() {{
  printf '%s\\n' "$*" >> "$TRANSITION_LOG"
  sed -i "s/^state.*/state\\t$5/" "$1"
}}
queue_state_checkpoint() {{
  printf 'schema_version\\t3\\nrun_id\\t%s\\nentity\\t%s\\nphase\\t%s\\nstatus\\t%s\\nupdated_at\\t2026-08-08T00:00:01Z\\n' \
    "$2" "$3" "$4" "$5" > "$1"
}}
status_outside_work() {{ printf '%s' "$DIRTY_OUTPUT"; }}
source {shlex.quote(str(HELPER))}
{body}
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "DIRTY_OUTPUT": dirty, "LC_ALL": "C"},
    )


def test_dirty_manual_review_is_sticky_across_repeated_resume_attempts(tmp_path: Path) -> None:
    run_dir = tmp_path / "run"
    state_file = run_dir / "run.state"
    report = run_dir / "manual-review.txt"
    checkpoint = run_dir / "checkpoint.state"
    write_run_state(state_file)
    write_report(report)
    write_checkpoint(checkpoint)
    report_before = report.read_bytes()
    checkpoint_before = checkpoint.read_bytes()

    result = invoke(
        tmp_path,
        dirty=" M target.txt",
        body="""
first=0
second=0
queue_state_transition "$STATE_FILE" run 'run run-a' manual_review_required running || first=$?
queue_state_checkpoint "$CHECKPOINT_FILE" run-a run startup failed
queue_state_transition "$STATE_FILE" run 'run run-a' manual_review_required running || second=$?
printf '%s %s\n' "$first" "$second"
""",
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "1 1"
    assert "state\tmanual_review_required" in state_file.read_text(encoding="utf-8")
    assert not (tmp_path / "transition.log").exists()
    assert report.read_bytes() == report_before
    assert checkpoint.read_bytes() == checkpoint_before
    assert result.stderr.count("phase=issue_flow") == 2
    assert "Original manual-review report is preserved" in result.stderr


def test_clean_worktree_allows_explicit_manual_review_resolution(tmp_path: Path) -> None:
    run_dir = tmp_path / "run"
    state_file = run_dir / "run.state"
    report = run_dir / "manual-review.txt"
    checkpoint = run_dir / "checkpoint.state"
    write_run_state(state_file)
    write_report(report, phase="batch_review")
    write_checkpoint(checkpoint, phase="batch_review")

    result = invoke(
        tmp_path,
        dirty="",
        body="""
queue_state_transition "$STATE_FILE" run 'run run-a' manual_review_required running
queue_state_checkpoint "$CHECKPOINT_FILE" run-a run startup before
""",
    )

    assert result.returncode == 0, result.stderr
    assert "state\trunning" in state_file.read_text(encoding="utf-8")
    assert (tmp_path / "transition.log").read_text(encoding="utf-8").count("manual_review_required running") == 1
    assert "phase\tstartup" in checkpoint.read_text(encoding="utf-8")
    assert report.exists()


def test_manual_review_state_without_report_fails_closed(tmp_path: Path) -> None:
    state_file = tmp_path / "run" / "run.state"
    write_run_state(state_file)

    result = invoke(
        tmp_path,
        dirty=" M target.txt",
        body="""
status=0
queue_state_transition "$STATE_FILE" run 'run run-a' manual_review_required running || status=$?
printf '%s\n' "$status"
""",
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "1"
    assert "missing or invalid manual-review report" in result.stderr
    assert "state\tmanual_review_required" in state_file.read_text(encoding="utf-8")
    assert not (tmp_path / "transition.log").exists()


def test_manual_review_report_identity_mismatch_fails_closed(tmp_path: Path) -> None:
    run_dir = tmp_path / "run"
    state_file = run_dir / "run.state"
    write_run_state(state_file)
    write_report(run_dir / "manual-review.txt", run_id="run-b")

    result = invoke(
        tmp_path,
        dirty=" M target.txt",
        body="""
status=0
queue_state_transition "$STATE_FILE" run 'run run-a' manual_review_required running || status=$?
printf '%s\n' "$status"
""",
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "1"
    assert "belongs to run run-b, not run-a" in result.stderr
    assert "state\tmanual_review_required" in state_file.read_text(encoding="utf-8")
    assert not (tmp_path / "transition.log").exists()
