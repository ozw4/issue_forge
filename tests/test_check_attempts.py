from __future__ import annotations

import hashlib
import os
import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECK_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "check_attempts.sh"
CHECKS_REVIEW_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
BATCH_REVIEW_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "batch_review_helpers.sh"
HISTORY_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "history_helpers.sh"

MANIFEST_HEADER = (
    "check_id\tscope\tscope_id\toperation\tround\tattempt_id\tkind\t"
    "requirement_id\tbase_commit\tsnapshot_head\tsnapshot_tree\tstatus\t"
    "exit_status\tsignal\tstarted_at\tfinished_at\tduration_ms\tlog_path\t"
    "log_sha256"
)


def run(*args: str, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def git(repo: Path, *args: str) -> str:
    completed = run("git", *args, cwd=repo)
    assert completed.returncode == 0, completed.stderr
    return completed.stdout.strip()


def initialize_repo(path: Path) -> tuple[Path, str]:
    path.mkdir()
    git(path, "init", "-b", "main")
    git(path, "config", "user.name", "Check Attempt Test")
    git(path, "config", "user.email", "checks@example.test")
    (path / ".gitignore").write_text(".work/\n", encoding="utf-8")
    (path / "tracked.txt").write_text("base\n", encoding="utf-8")
    checks = path / "check.sh"
    checks.write_text(
        """#!/usr/bin/env bash
set -u
printf 'check-label=%s base=%s\n' "${CHECK_LABEL:-default}" "$1"
case "${CHECK_ACTION:-none}" in
  tracked) printf 'changed by check\n' >> tracked.txt ;;
  stage) git add tracked.txt ;;
  untracked) printf 'created by check\n' > created-by-check.txt ;;
  work) mkdir -p .work/check-side-effect; printf 'allowed\n' > .work/check-side-effect/value ;;
esac
exit "${CHECK_STATUS:-0}"
""",
        encoding="utf-8",
    )
    checks.chmod(0o755)
    git(path, "add", ".gitignore", "tracked.txt", "check.sh")
    git(path, "commit", "-m", "base")
    return checks, git(path, "rev-parse", "HEAD")


def read_state(path: Path) -> dict[str, str]:
    return dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines())


def invoke_common(
    repo: Path,
    base: str,
    *,
    scope: str = "issue",
    scope_id: str = "7",
    operation: str = "issue-checks",
    status: int = 0,
    action: str = "none",
    label: str = "default",
    fault_before_legacy: bool = False,
    attempts_root: Path | None = None,
    manifest: Path | None = None,
    legacy: Path | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, Path, Path]:
    attempts_root = attempts_root or repo / ".work" / "codex" / "check-attempts"
    manifest = manifest or repo / ".work" / "codex" / "checks.manifest.tsv"
    legacy = legacy or repo / ".work" / "codex" / "checks.log"
    legacy.parent.mkdir(parents=True, exist_ok=True)
    fault = "check_attempt_before_legacy_publish() { return 1; }" if fault_before_legacy else ""
    script = f"""
set -uo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
source {shlex.quote(str(CHECK_HELPER))}
{fault}
run_check_attempt \\
  {shlex.quote(str(attempts_root))} \\
  {shlex.quote(str(manifest))} \\
  {shlex.quote(str(legacy))} \\
  {shlex.quote(scope)} {shlex.quote(scope_id)} {shlex.quote(operation)} 1 \\
  {shlex.quote(base)} ./check.sh {shlex.quote(base)}
"""
    env = {
        **os.environ,
        "CHECK_STATUS": str(status),
        "CHECK_ACTION": action,
        "CHECK_LABEL": label,
        "LC_ALL": "C",
    }
    completed = run("bash", "-c", script, cwd=repo, env=env)
    return completed, attempts_root, manifest, legacy


def invoke_validator(repo: Path, root: Path, manifest: Path, mirror: bool = False) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
source {shlex.quote(str(CHECK_HELPER))}
check_attempt_validate_store {shlex.quote(str(root))} {shlex.quote(str(manifest))} {1 if mirror else 0}
"""
    return run("bash", "-c", script, cwd=repo, env={**os.environ, "LC_ALL": "C"})


def manifest_rows(manifest: Path) -> list[list[str]]:
    lines = manifest.read_text(encoding="utf-8").splitlines()
    assert lines[0] == MANIFEST_HEADER
    return [line.split("\t") for line in lines[1:]]


def test_issue_checks_round_publishes_attempt_manifest_history_and_legacy_log(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    script = f"""
set -euo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
CODEX_FLOW_BASE_COMMIT_FILE=.work/base_commit
CODEX_FLOW_CHECKS_COMMAND=./check.sh
CODEX_FLOW_CHECK_ATTEMPTS_ROOT=.work/codex/check-attempts
CODEX_FLOW_CHECKS_MANIFEST=.work/codex/checks.manifest.tsv
checks_log=.work/codex/checks.log
history_dir=.work/codex/history
issue_number=7
checks_run_round=0
mkdir -p "$history_dir"
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(CHECKS_REVIEW_HELPER))}
resolve_fixed_base_commit_from_state() {{ printf '%s\n' {shlex.quote(base)}; }}
run_checks_round
"""
    completed = run("bash", "-c", script, cwd=repo, env={**os.environ, "LC_ALL": "C"})

    attempt = repo / ".work/codex/check-attempts/issue-checks/attempt-0001"
    manifest = repo / ".work/codex/checks.manifest.tsv"
    legacy = repo / ".work/codex/checks.log"
    history = repo / ".work/codex/history/checks.round-01.log"
    assert completed.returncode == 0, completed.stderr
    assert attempt.is_dir()
    assert manifest_rows(manifest)[0][11:14] == ["passed", "0", "none"]
    assert legacy.read_bytes() == (attempt / "combined.log").read_bytes()
    assert history.read_bytes() == (attempt / "combined.log").read_bytes()


def test_batch_checks_once_uses_same_attempt_helper_and_legacy_log(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    script = f"""
set -euo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
CODEX_FLOW_CHECKS_COMMAND=./check.sh
source {shlex.quote(str(BATCH_REVIEW_HELPER))}
run_batch_checks_once \\
  {shlex.quote(base)} .work/queue/batches/batch-7-8/checks.log 1 batch-7-8 \\
  .work/queue/runs/run-a/batches/batch-7-8/check-attempts/batch \\
  .work/queue/runs/run-a/batches/batch-7-8/checks/batch.manifest.tsv
"""
    (repo / ".work/queue/batches/batch-7-8").mkdir(parents=True)
    completed = run("bash", "-c", script, cwd=repo, env={**os.environ, "LC_ALL": "C"})

    attempt = repo / ".work/queue/runs/run-a/batches/batch-7-8/check-attempts/batch/batch-checks/attempt-0001"
    manifest = repo / ".work/queue/runs/run-a/batches/batch-7-8/checks/batch.manifest.tsv"
    legacy = repo / ".work/queue/batches/batch-7-8/checks.log"
    assert completed.returncode == 0, completed.stderr
    assert manifest_rows(manifest)[0][1:4] == ["batch", "batch-7-8", "batch-checks"]
    assert legacy.read_bytes() == (attempt / "combined.log").read_bytes()


@pytest.mark.parametrize(
    ("status", "expected_status", "signal"),
    [(17, "failed", "none"), (130, "interrupted", "INT"), (143, "interrupted", "TERM")],
)
def test_nonzero_and_interrupted_classification(
    tmp_path: Path, status: int, expected_status: str, signal: str
) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    completed, root, manifest, legacy = invoke_common(repo, base, status=status)
    attempt = root / "issue-checks/attempt-0001"

    assert completed.returncode == status
    result = read_state(attempt / "result.state")
    assert result["status"] == expected_status
    assert result["exit_status"] == str(status)
    assert result["signal"] == signal
    assert legacy.read_bytes() == (attempt / "combined.log").read_bytes()
    assert manifest_rows(manifest)[0][11:14] == [expected_status, str(status), signal]


@pytest.mark.parametrize("action", ["tracked", "untracked"])
def test_repository_changes_make_exit_zero_attempt_invalid(tmp_path: Path, action: str) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    completed, root, manifest, legacy = invoke_common(repo, base, action=action)
    attempt = root / "issue-checks/attempt-0001"
    result = read_state(attempt / "result.state")

    assert completed.returncode != 0
    assert result["status"] == "invalid"
    assert result["exit_status"] == "0"
    assert result["snapshot_match"] == "no"
    assert manifest_rows(manifest)[0][11] == "invalid"
    assert "Review snapshot mismatch" in legacy.read_text(encoding="utf-8")
    assert str(attempt) in completed.stderr
    if action == "tracked":
        assert "changed by check" in (repo / "tracked.txt").read_text(encoding="utf-8")
    else:
        assert (repo / "created-by-check.txt").is_file()


def test_staging_only_change_makes_attempt_invalid(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    (repo / "tracked.txt").write_text("base\nimplementation change\n", encoding="utf-8")

    completed, root, manifest, legacy = invoke_common(repo, base, action="stage")
    result = read_state(root / "issue-checks/attempt-0001/result.state")

    assert completed.returncode != 0
    assert result["status"] == "invalid"
    assert result["snapshot_match"] == "no"
    assert manifest_rows(manifest)[0][11] == "invalid"
    assert "Check repository status mismatch" in legacy.read_text(encoding="utf-8")
    assert git(repo, "diff", "--cached", "--name-only") == "tracked.txt"


def test_work_directory_only_change_follows_snapshot_exclusion(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    completed, root, manifest, _legacy = invoke_common(repo, base, action="work")

    assert completed.returncode == 0, completed.stderr
    assert read_state(root / "issue-checks/attempt-0001/result.state")["status"] == "passed"
    assert manifest_rows(manifest)[0][11] == "passed"
    assert (repo / ".work/check-side-effect/value").is_file()


def test_invalid_issue_check_fails_closed_without_starting_fixer(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    marker = repo / ".work/fixer-started"
    script = f"""
set -uo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
CODEX_FLOW_BASE_COMMIT_FILE=.work/base_commit
CODEX_FLOW_CHECKS_COMMAND=./check.sh
CODEX_FLOW_CHECK_ATTEMPTS_ROOT=.work/codex/check-attempts
CODEX_FLOW_CHECKS_MANIFEST=.work/codex/checks.manifest.tsv
CODEX_FLOW_MAX_CHECK_FIX_ROUNDS=3
checks_log=.work/codex/checks.log
history_dir=.work/codex/history
issue_number=7
checks_run_round=0
fix_checks_round=0
mkdir -p "$history_dir"
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(CHECKS_REVIEW_HELPER))}
resolve_fixed_base_commit_from_state() {{ printf '%s\n' {shlex.quote(base)}; }}
log_info() {{ :; }}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
run_fix_from_checks_round() {{ : > {shlex.quote(str(marker))}; }}
ensure_checks_pass
"""
    completed = run(
        "bash",
        "-c",
        script,
        cwd=repo,
        env={**os.environ, "CHECK_ACTION": "tracked", "CHECK_STATUS": "0", "LC_ALL": "C"},
    )

    assert completed.returncode != 0
    assert not marker.exists()
    assert "recorded as invalid" in completed.stderr


def test_running_attempt_is_preserved_and_next_id_is_used(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    running = repo / ".work/codex/check-attempts/issue-checks/attempt-0001.running"
    running.mkdir(parents=True)
    marker = running / "marker"
    marker.write_text("preserve\n", encoding="utf-8")

    completed, root, manifest, _legacy = invoke_common(repo, base)

    assert completed.returncode == 0, completed.stderr
    assert (root / "issue-checks/attempt-0002").is_dir()
    assert marker.read_text(encoding="utf-8") == "preserve\n"
    assert manifest_rows(manifest)[0][5] == "attempt-0002"


def test_exact_argv_is_ordered_and_not_reparsed(tmp_path: Path) -> None:
    repo = tmp_path / "repo with spaces"
    _checks, base = initialize_repo(repo)
    completed, root, _manifest, _legacy = invoke_common(repo, base)

    assert completed.returncode == 0, completed.stderr
    assert (root / "issue-checks/attempt-0001/argv.tsv").read_text(encoding="utf-8") == (
        f"0\t./check.sh\n1\t{base}\n"
    )


@pytest.mark.parametrize("corruption", ["header", "enum", "columns", "path", "hash", "timestamp", "duplicate"])
def test_manifest_reader_rejects_corruption(tmp_path: Path, corruption: str) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    completed, root, manifest, _legacy = invoke_common(repo, base)
    assert completed.returncode == 0, completed.stderr
    lines = manifest.read_text(encoding="utf-8").splitlines()
    fields = lines[1].split("\t")

    if corruption == "header":
        lines[0] = "bad\t" + lines[0]
    elif corruption == "enum":
        fields[11] = "complete"
        lines[1] = "\t".join(fields)
    elif corruption == "columns":
        lines[1] = "\t".join(fields[:-1])
    elif corruption == "path":
        fields[17] = "../outside.log"
        lines[1] = "\t".join(fields)
    elif corruption == "hash":
        fields[18] = "0" * 40
        lines[1] = "\t".join(fields)
    elif corruption == "timestamp":
        fields[14] = "not-a-timestamp"
        lines[1] = "\t".join(fields)
    elif corruption == "duplicate":
        lines.append(lines[1])
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")

    rejected = invoke_validator(repo, root, manifest)
    assert rejected.returncode != 0


def test_fault_before_legacy_publish_keeps_old_log_and_terminal_attempt_immutable(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    first, root, manifest, legacy = invoke_common(repo, base, label="first")
    first_attempt = root / "issue-checks/attempt-0001"
    first_files = {path.name: path.read_bytes() for path in first_attempt.iterdir()}
    old_legacy = legacy.read_bytes()
    assert first.returncode == 0, first.stderr

    second, _root, _manifest, _legacy = invoke_common(
        repo,
        base,
        label="second",
        fault_before_legacy=True,
        attempts_root=root,
        manifest=manifest,
        legacy=legacy,
    )

    assert second.returncode != 0
    assert legacy.read_bytes() == old_legacy
    assert {path.name: path.read_bytes() for path in first_attempt.iterdir()} == first_files
    assert (root / "issue-checks/attempt-0002").is_dir()
    assert len(manifest_rows(manifest)) == 2


def test_legacy_publish_failure_does_not_start_issue_fixer(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    legacy = repo / ".work/codex/checks.log"
    marker = repo / ".work/fixer-started"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("previous complete log\n", encoding="utf-8")
    script = f"""
set -uo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
CODEX_FLOW_BASE_COMMIT_FILE=.work/base_commit
CODEX_FLOW_CHECKS_COMMAND=./check.sh
CODEX_FLOW_CHECK_ATTEMPTS_ROOT=.work/codex/check-attempts
CODEX_FLOW_CHECKS_MANIFEST=.work/codex/checks.manifest.tsv
CODEX_FLOW_MAX_CHECK_FIX_ROUNDS=3
checks_log=.work/codex/checks.log
history_dir=.work/codex/history
issue_number=7
checks_run_round=0
fix_checks_round=0
mkdir -p "$history_dir"
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(CHECKS_REVIEW_HELPER))}
resolve_fixed_base_commit_from_state() {{ printf '%s\n' {shlex.quote(base)}; }}
log_info() {{ :; }}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
run_fix_from_checks_round() {{ : > {shlex.quote(str(marker))}; }}
check_attempt_before_legacy_publish() {{ return 1; }}
ensure_checks_pass
"""
    completed = run("bash", "-c", script, cwd=repo, env={**os.environ, "LC_ALL": "C"})

    assert completed.returncode != 0
    assert not marker.exists()
    assert legacy.read_text(encoding="utf-8") == "previous complete log\n"
    assert "legacy log publication failed" in completed.stderr
    assert manifest_rows(repo / ".work/codex/checks.manifest.tsv")[0][11] == "passed"


def test_run_owned_provenance_copy_remains_self_validating_for_issue_archive(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _checks, base = initialize_repo(repo)
    source_root = repo / ".work/queue/runs/run-a/batches/batch-7-7/check-attempts/issue-7"
    source_manifest = repo / ".work/queue/runs/run-a/batches/batch-7-7/checks/issue-7.manifest.tsv"
    legacy = repo / ".work/codex/checks.log"
    completed, _root, _manifest, _legacy = invoke_common(
        repo,
        base,
        attempts_root=source_root,
        manifest=source_manifest,
        legacy=legacy,
    )
    assert completed.returncode == 0, completed.stderr
    archive_codex = repo / ".work/queue/runs/run-a/archives/batch-7-7/issues/7/deadbeef/codex"
    destination_root = archive_codex / "check-attempts"
    destination_manifest = archive_codex / "checks.manifest.tsv"
    script = f"""
set -euo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude).work")
source {shlex.quote(str(CHECK_HELPER))}
publish_check_attempt_provenance_copy \\
  {shlex.quote(str(source_root))} {shlex.quote(str(source_manifest))} \\
  {shlex.quote(str(destination_root))} {shlex.quote(str(destination_manifest))}
"""
    published = run("bash", "-c", script, cwd=repo, env={**os.environ, "LC_ALL": "C"})
    assert published.returncode == 0, published.stderr

    legacy.parent.mkdir(parents=True, exist_ok=True)
    if legacy.exists():
        legacy.unlink()
    valid = invoke_validator(repo, destination_root, destination_manifest, mirror=True)
    assert valid.returncode == 0, valid.stderr
    hashes = {
        path.relative_to(archive_codex).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in archive_codex.rglob("*")
        if path.is_file()
    }
    assert "checks.manifest.tsv" in hashes
    assert "check-attempts/issue-checks/attempt-0001/combined.log" in hashes
