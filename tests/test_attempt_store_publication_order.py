from __future__ import annotations

import os
import shlex
import stat
import subprocess
from pathlib import Path


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


def assert_read_only(path: Path) -> None:
    assert path.stat().st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH) == 0


def test_result_marker_is_not_written_before_artifacts_are_frozen(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    compatibility = tmp_path / "checks.log"

    interrupted = run_bash(
        tmp_path,
        f"""
issue_forge_attempt_store_finalize_original() {{ return 91; }}
attempt_dir=''; attempt_log=''; status=0
run_logged_attempt attempt_dir attempt_log \\
  {shlex.quote(str(attempts))} checks 1 check none none {shlex.quote(str(compatibility))} combined -- \\
  bash -c 'printf "complete check\\n"' || status=$?
printf '%s\\n%s\\n' "$status" "$attempt_dir"
""",
    )

    assert interrupted.returncode == 0, interrupted.stderr
    status, attempt_value = interrupted.stdout.splitlines()
    assert status == "1"
    attempt = Path(attempt_value)
    pending = attempts / "pending" / "checks.state"

    assert pending.is_file()
    assert not (attempt / "result.state").exists()
    assert_read_only(attempt / "output.log")
    assert not compatibility.exists()
    assert not (attempts / "latest" / "checks.state").exists()

    recovered = run_bash(tmp_path, f"attempt_store_reconcile_publications {shlex.quote(str(attempts))}")
    assert recovered.returncode == 0, recovered.stderr
    assert not pending.exists()
    assert not (attempt / "result.state").exists()
    assert not compatibility.exists()


def test_result_and_pending_replay_restore_compatibility_and_latest(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    compatibility = tmp_path / "implementation.log"

    interrupted = run_bash(
        tmp_path,
        f"""
attempt_store_atomic_copy() {{ return 92; }}
attempt_dir=''; attempt_log=''; status=0
run_logged_attempt attempt_dir attempt_log \\
  {shlex.quote(str(attempts))} implementation 0 write high none {shlex.quote(str(compatibility))} combined -- \\
  bash -c 'printf "implementation output\\n"' || status=$?
printf '%s\\n%s\\n' "$status" "$attempt_dir"
""",
    )

    assert interrupted.returncode == 0, interrupted.stderr
    status, attempt_value = interrupted.stdout.splitlines()
    assert status == "1"
    attempt = Path(attempt_value)
    pending = attempts / "pending" / "implementation.state"

    assert pending.is_file()
    assert (attempt / "result.state").is_file()
    assert_read_only(attempt / "result.state")
    assert_read_only(attempt / "output.log")
    assert not compatibility.exists()
    assert not (attempts / "latest" / "implementation.state").exists()

    recovered = run_bash(tmp_path, f"attempt_store_reconcile_publications {shlex.quote(str(attempts))}")
    assert recovered.returncode == 0, recovered.stderr
    assert compatibility.read_text(encoding="utf-8") == "implementation output\n"
    assert read_state(attempts / "latest" / "implementation.state")["attempt_id"] == attempt.name
    assert not pending.exists()


def test_partial_review_pair_is_replayed_from_terminal_attempt(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    raw = tmp_path / "review.raw.txt"
    parsed = tmp_path / "review.txt"

    interrupted = run_bash(
        tmp_path,
        f"""
extract_structured_review_output_file() {{
  case "$(cat "$1")" in
    'raw one') printf 'parsed one\\n' > "$2" ;;
    'raw two') printf 'parsed two\\n' > "$2" ;;
    *) return 1 ;;
  esac
}}
first_dir=''; first_log=''
run_logged_attempt first_dir first_log \\
  {shlex.quote(str(attempts))} review 1 read high none {shlex.quote(str(raw))} combined -- \\
  bash -c 'printf "raw one\\n"'

issue_forge_attempt_store_capture_function attempt_store_atomic_copy test_atomic_copy_original
attempt_store_atomic_copy() {{
  test_atomic_copy_original "$@" || return 1
  [[ "$2" != {shlex.quote(str(parsed))} ]] || return 93
}}
second_dir=''; second_log=''; status=0
run_logged_attempt second_dir second_log \\
  {shlex.quote(str(attempts))} review 2 read high none {shlex.quote(str(raw))} combined -- \\
  bash -c 'printf "raw two\\n"' || status=$?
printf '%s\\n%s\\n%s\\n' "$status" "$first_dir" "$second_dir"
""",
    )

    assert interrupted.returncode == 0, interrupted.stderr
    status, first_value, second_value = interrupted.stdout.splitlines()
    assert status == "1"
    first = Path(first_value)
    second = Path(second_value)
    pending = attempts / "pending" / "review.state"

    assert pending.is_file()
    assert (second / "result.state").is_file()
    assert raw.read_text(encoding="utf-8") == "raw one\n"
    assert parsed.read_text(encoding="utf-8") == "parsed two\n"
    assert read_state(attempts / "latest" / "review.state")["attempt_id"] == first.name

    recovered = run_bash(tmp_path, f"attempt_store_reconcile_publications {shlex.quote(str(attempts))}")
    assert recovered.returncode == 0, recovered.stderr
    assert raw.read_text(encoding="utf-8") == "raw two\n"
    assert parsed.read_text(encoding="utf-8") == "parsed two\n"
    assert read_state(attempts / "latest" / "review.state")["attempt_id"] == second.name
    assert not pending.exists()


def test_completed_publication_replay_is_idempotent(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    compatibility = tmp_path / "checks.log"

    interrupted = run_bash(
        tmp_path,
        f"""
attempt_store_publication_test_hook() {{
  [[ "$1" != after_finalize ]] || return 94
}}
attempt_dir=''; attempt_log=''; status=0
run_logged_attempt attempt_dir attempt_log \\
  {shlex.quote(str(attempts))} checks 4 check none none {shlex.quote(str(compatibility))} combined -- \\
  bash -c 'printf "published output\\n"' || status=$?
printf '%s\\n%s\\n' "$status" "$attempt_dir"
""",
    )

    assert interrupted.returncode == 0, interrupted.stderr
    status, attempt_value = interrupted.stdout.splitlines()
    assert status == "1"
    attempt = Path(attempt_value)
    pending = attempts / "pending" / "checks.state"
    latest = attempts / "latest" / "checks.state"

    assert pending.is_file()
    assert compatibility.read_text(encoding="utf-8") == "published output\n"
    assert read_state(latest)["attempt_id"] == attempt.name

    recovered = run_bash(tmp_path, f"attempt_store_reconcile_publications {shlex.quote(str(attempts))}")
    assert recovered.returncode == 0, recovered.stderr
    assert compatibility.read_text(encoding="utf-8") == "published output\n"
    assert read_state(latest)["attempt_id"] == attempt.name
    assert not pending.exists()
