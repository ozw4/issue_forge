from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "agent_attempts.sh"


def write_fake_launcher(engine_dir: Path) -> None:
    launcher = engine_dir / "run_codex.sh"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        """#!/usr/bin/env bash
set -u
printf 'stdout mode=%s prompt=%s\n' "$1" "$(< "$2")"
printf 'stderr status=%s\n' "${FAKE_CODEX_STATUS:-0}" >&2
exit "${FAKE_CODEX_STATUS:-0}"
""",
        encoding="utf-8",
    )
    launcher.chmod(0o755)


def run_helper(
    tmp_path: Path,
    *,
    status: int = 0,
    attempts_enabled: bool = True,
    operation: str = "review",
    round_number: int = 2,
    legacy_stderr_policy: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, Path, Path]:
    engine_dir = tmp_path / "engine" / "tools" / "codex"
    write_fake_launcher(engine_dir)
    prompt = tmp_path / "input.md"
    prompt.write_text("test prompt\n", encoding="utf-8")
    legacy_log = tmp_path / "legacy.log"
    attempts_root = tmp_path / "attempts"
    policy_argument = "" if legacy_stderr_policy is None else f" {shlex.quote(legacy_stderr_policy)}"
    script = f"""
set -uo pipefail
ISSUE_FORGE_ENGINE_CODEX_DIR={shlex.quote(str(engine_dir))}
source {shlex.quote(str(HELPER))}
run_codex_with_attempt {shlex.quote(operation)} {round_number} read {shlex.quote(str(prompt))} {shlex.quote(str(legacy_log))}{policy_argument}
"""
    env = os.environ.copy()
    env["FAKE_CODEX_STATUS"] = str(status)
    if attempts_enabled:
        env["CODEX_FLOW_AGENT_ATTEMPTS_ROOT"] = str(attempts_root)
    else:
        env.pop("CODEX_FLOW_AGENT_ATTEMPTS_ROOT", None)
    completed = subprocess.run(  # noqa: S603 - invokes bash with trusted test paths
        ["bash", "-c", script],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        check=False,
        text=True,
    )
    return completed, attempts_root, prompt, legacy_log


def read_state(path: Path) -> dict[str, str]:
    return dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines())


def test_successful_attempt_is_finalized_and_published(tmp_path: Path) -> None:
    completed, attempts_root, prompt, legacy_log = run_helper(tmp_path)
    attempt = attempts_root / "review" / "attempt-0001"

    assert completed.returncode == 0
    assert attempt.is_dir()
    assert not (attempts_root / "review" / "attempt-0001.running").exists()
    request = read_state(attempt / "request.state")
    assert request["schema_version"] == "1"
    assert request["attempt_id"] == "attempt-0001"
    assert request["operation"] == "review"
    assert request["round"] == "2"
    assert request["mode"] == "read"
    assert request["started_at"].endswith("Z")
    result = read_state(attempt / "result.state")
    assert result["status"] == "completed"
    assert result["exit_status"] == "0"
    assert result["finished_at"].endswith("Z")
    assert (attempt / "prompt.md").read_bytes() == prompt.read_bytes()
    attempt_log = (attempt / "agent.log").read_text(encoding="utf-8")
    assert "stdout mode=read prompt=test prompt" in attempt_log
    assert "stderr status=0" in attempt_log
    assert legacy_log.read_bytes() == (attempt / "agent.log").read_bytes()


def test_failed_attempt_preserves_status_and_log(tmp_path: Path) -> None:
    completed, attempts_root, _prompt, legacy_log = run_helper(tmp_path, status=17)
    attempt = attempts_root / "review" / "attempt-0001"

    assert completed.returncode == 17
    assert read_state(attempt / "result.state")["status"] == "failed"
    assert read_state(attempt / "result.state")["exit_status"] == "17"
    assert "stderr status=17" in legacy_log.read_text(encoding="utf-8")
    assert legacy_log.read_bytes() == (attempt / "agent.log").read_bytes()


@pytest.mark.parametrize("status", [130, 143])
def test_interrupted_attempt_classification(tmp_path: Path, status: int) -> None:
    completed, attempts_root, _prompt, _legacy_log = run_helper(tmp_path, status=status)
    result = read_state(attempts_root / "review" / "attempt-0001" / "result.state")

    assert completed.returncode == status
    assert result["status"] == "interrupted"
    assert result["exit_status"] == str(status)


def test_attempt_ids_advance_without_overwriting(tmp_path: Path) -> None:
    first, attempts_root, _prompt, _legacy_log = run_helper(tmp_path, status=17)
    first_attempt = attempts_root / "review" / "attempt-0001"
    first_snapshot = {path.name: path.read_bytes() for path in first_attempt.iterdir()}

    second, _attempts_root, _prompt, _legacy_log = run_helper(tmp_path, status=0)

    assert first.returncode == 17
    assert second.returncode == 0
    assert (attempts_root / "review" / "attempt-0002").is_dir()
    assert {path.name: path.read_bytes() for path in first_attempt.iterdir()} == first_snapshot


def test_running_attempt_is_preserved_and_skipped(tmp_path: Path) -> None:
    running = tmp_path / "attempts" / "review" / "attempt-0001.running"
    running.mkdir(parents=True)
    marker = running / "marker"
    marker.write_text("unchanged\n", encoding="utf-8")

    completed, attempts_root, _prompt, _legacy_log = run_helper(tmp_path)

    assert completed.returncode == 0
    assert (attempts_root / "review" / "attempt-0002").is_dir()
    assert running.is_dir()
    assert marker.read_text(encoding="utf-8") == "unchanged\n"


def test_unset_attempt_root_keeps_legacy_only_behavior(tmp_path: Path) -> None:
    completed, attempts_root, _prompt, legacy_log = run_helper(
        tmp_path,
        status=23,
        attempts_enabled=False,
    )

    assert completed.returncode == 23
    assert not attempts_root.exists()
    assert "stdout mode=read prompt=test prompt" in legacy_log.read_text(encoding="utf-8")
    assert "stderr status=23" in legacy_log.read_text(encoding="utf-8")


def test_unset_attempt_root_can_preserve_stdout_only_legacy_log(tmp_path: Path) -> None:
    completed, attempts_root, _prompt, legacy_log = run_helper(
        tmp_path,
        attempts_enabled=False,
        legacy_stderr_policy="stdout",
    )

    assert completed.returncode == 0
    assert not attempts_root.exists()
    assert "stdout mode=read prompt=test prompt" in legacy_log.read_text(encoding="utf-8")
    assert "stderr status=0" not in legacy_log.read_text(encoding="utf-8")
    assert "stderr status=0" in completed.stderr


def test_enabled_attempt_preserves_stdout_only_legacy_policy(tmp_path: Path) -> None:
    completed, attempts_root, _prompt, legacy_log = run_helper(
        tmp_path,
        legacy_stderr_policy="stdout",
    )
    attempt = attempts_root / "review" / "attempt-0001"
    attempt_log = (attempt / "agent.log").read_text(encoding="utf-8")
    legacy_text = legacy_log.read_text(encoding="utf-8")

    assert completed.returncode == 0
    assert "stdout mode=read prompt=test prompt" in attempt_log
    assert "stderr status=0" in attempt_log
    assert "stdout mode=read prompt=test prompt" in legacy_text
    assert "stderr status=0" not in legacy_text
    assert read_state(attempt / "result.state")["status"] == "completed"
