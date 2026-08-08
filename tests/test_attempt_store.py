from __future__ import annotations

import os
import shlex
import stat
import subprocess
import time
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
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, value = line.split("\t", 1)
        fields[key] = value
    return fields


def attempt_dirs(root: Path) -> list[Path]:
    return sorted(path for path in root.iterdir() if path.is_dir() and path.name != "latest")


def assert_read_only(path: Path) -> None:
    assert path.stat().st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH) == 0


def test_successful_attempt_is_immutable_and_updates_compatibility_view(tmp_path: Path) -> None:
    prompt = tmp_path / "prompt.md"
    prompt.write_text("do the work\n", encoding="utf-8")
    attempts = tmp_path / "attempts"
    legacy = tmp_path / "review.raw.txt"

    result = run_bash(
        tmp_path,
        f"""
attempt_dir=''
attempt_log=''
run_logged_attempt attempt_dir attempt_log \
  {shlex.quote(str(attempts))} review 1 read high {shlex.quote(str(prompt))} \
  {shlex.quote(str(legacy))} stdout -- \
  bash -c 'printf "accept: yes\\n"; printf "runtime note\\n" >&2'
printf '%s\\n%s\\n' "$attempt_dir" "$attempt_log"
""",
    )

    assert result.returncode == 0, result.stderr
    assert "runtime note" in result.stderr
    [attempt] = attempt_dirs(attempts)
    assert legacy.read_text(encoding="utf-8") == "accept: yes\n"
    assert (attempt / "output.log").read_text(encoding="utf-8") == "accept: yes\n"
    assert (attempt / "stderr.log").read_text(encoding="utf-8") == "runtime note\n"

    input_state = read_state(attempt / "input.state")
    result_state = read_state(attempt / "result.state")
    latest_state = read_state(attempts / "latest" / "review.state")
    assert input_state["phase"] == "review"
    assert input_state["round"] == "1"
    assert input_state["stderr_policy"] == "stdout"
    assert input_state["prompt_sha256"] != "none"
    assert input_state["prompt_copy"] == "prompt.md"
    assert (attempt / "prompt.md").read_text(encoding="utf-8") == "do the work\n"
    assert result_state["status"] == "succeeded"
    assert result_state["exit_status"] == "0"
    assert latest_state["attempt_id"] == attempt.name
    assert latest_state["output_path"] == f"{attempt.name}/output.log"

    assert_read_only(attempt / "input.state")
    assert_read_only(attempt / "output.log")
    assert_read_only(attempt / "stderr.log")
    assert_read_only(attempt / "result.state")
    assert_read_only(attempt / "prompt.md")


def test_failed_attempt_is_terminal_and_does_not_modify_previous_attempt(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    legacy = tmp_path / "implementation.log"

    result = run_bash(
        tmp_path,
        f"""
first_dir=''; first_log=''; second_dir=''; second_log=''; status=0
run_logged_attempt first_dir first_log \
  {shlex.quote(str(attempts))} implementation 0 write high none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "first\\n"'
first_hash="$(sha256sum "$first_log" | awk '{{ print $1 }}')"
run_logged_attempt second_dir second_log \
  {shlex.quote(str(attempts))} implementation 0 write high none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "second\\n"; exit 7' || status=$?
printf '%s\\n%s\\n%s\\n%s\\n' "$status" "$first_dir" "$second_dir" "$first_hash"
""",
    )

    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "7"
    attempts_found = attempt_dirs(attempts)
    assert len(attempts_found) == 2
    first = Path(lines[1])
    second = Path(lines[2])
    first_hash = lines[3]
    assert first != second
    assert subprocess.check_output(["sha256sum", first / "output.log"], text=True).split()[0] == first_hash
    assert read_state(first / "result.state")["status"] == "succeeded"
    assert read_state(second / "result.state")["status"] == "failed"
    assert read_state(second / "result.state")["exit_status"] == "7"
    assert legacy.read_text(encoding="utf-8") == "second\n"
    assert read_state(attempts / "latest" / "implementation.state")["attempt_id"] == second.name


def test_derived_artifact_is_write_once_and_bound_to_terminal_attempt(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    legacy = tmp_path / "review.raw.txt"
    parsed = tmp_path / "review.txt"
    parsed.write_text("accept: yes\n", encoding="utf-8")

    result = run_bash(
        tmp_path,
        f"""
attempt_dir=''; attempt_log=''; duplicate=0
run_logged_attempt attempt_dir attempt_log \
  {shlex.quote(str(attempts))} review 1 read high none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "raw\\n"'
attempt_store_publish_derived "$attempt_dir" parsed-review.txt {shlex.quote(str(parsed))}
attempt_store_publish_derived "$attempt_dir" parsed-review.txt {shlex.quote(str(parsed))} || duplicate=$?
printf '%s\\n%s\\n' "$duplicate" "$attempt_dir"
""",
    )

    assert result.returncode == 0, result.stderr
    duplicate, attempt_dir = result.stdout.splitlines()
    assert duplicate == "1"
    derived = Path(attempt_dir) / "parsed-review.txt"
    assert derived.read_text(encoding="utf-8") == "accept: yes\n"
    assert_read_only(derived)
    assert "already exists" in result.stderr


def test_killed_parent_leaves_incomplete_attempt_without_publishing_it(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    legacy = tmp_path / "checks.log"
    script = f"""
set -euo pipefail
source {shlex.quote(str(HELPER))}
attempt_dir=''; attempt_log=''
run_logged_attempt attempt_dir attempt_log \
  {shlex.quote(str(attempts))} checks 1 check none none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "partial\\n"; kill -KILL "$PPID"'
"""
    killed = subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )
    assert killed.returncode in {-9, 137}
    time.sleep(0.05)

    [incomplete] = attempt_dirs(attempts)
    assert (incomplete / "input.state").is_file()
    assert (incomplete / "output.log").read_text(encoding="utf-8") == "partial\n"
    assert not (incomplete / "result.state").exists()
    assert not legacy.exists()
    assert not (attempts / "latest" / "checks.state").exists()

    completed = run_bash(
        tmp_path,
        f"""
attempt_dir=''; attempt_log=''
run_logged_attempt attempt_dir attempt_log \
  {shlex.quote(str(attempts))} checks 1 check none none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "complete\\n"'
""",
    )
    assert completed.returncode == 0, completed.stderr
    assert len(attempt_dirs(attempts)) == 2
    assert not (incomplete / "result.state").exists()
    assert legacy.read_text(encoding="utf-8") == "complete\n"


def test_token_usage_can_reference_the_immutable_attempt_log(tmp_path: Path) -> None:
    token_helper = HELPER.parent / "token_usage_helpers.sh"
    attempts = tmp_path / "attempts"
    legacy = tmp_path / "review.raw.txt"
    usage = tmp_path / "token-usage.tsv"

    result = run_bash(
        tmp_path,
        f"""
source {shlex.quote(str(token_helper))}
attempt_dir=''; attempt_log=''
run_logged_attempt attempt_dir attempt_log \
  {shlex.quote(str(attempts))} review 2 read high none {shlex.quote(str(legacy))} combined -- \
  bash -c 'printf "tokens used\\n1,234\\n"'
append_codex_token_usage {shlex.quote(str(usage))} $'phase\\tissue\\tround\\treasoning\\ttokens\\tlog' \
  review 42 2 high "$attempt_log"
""",
    )
    assert result.returncode == 0, result.stderr
    row = usage.read_text(encoding="utf-8").splitlines()[1].split("\t")
    assert row[4] == "1234"
    assert "/attempts/" in row[5]
    assert row[5].endswith("/output.log")
