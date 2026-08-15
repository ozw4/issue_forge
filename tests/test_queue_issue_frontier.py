from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


FLOW_STATE = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "flow_state.sh"


def run(*args: str, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def git(repo: Path, *args: str) -> str:
    return run("git", *args, cwd=repo).stdout.strip()


def write_state(path: Path, **fields: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{key}\t{value}\n" for key, value in fields.items()), encoding="utf-8")


def invoke_frontier_check(repo: Path, run_dir: Path) -> subprocess.CompletedProcess[str]:
    script = f"""
set -euo pipefail
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
ISSUE_FORGE_ENGINE_ROOT=/outside-engine
CODEX_FLOW_WORK_ROOT=.work
CODEX_FLOW_CURRENT_ISSUE_FILE=.work/current_issue
CODEX_FLOW_CURRENT_BRANCH_FILE=.work/current_branch
CODEX_FLOW_BASE_COMMIT_FILE=.work/base_commit
CODEX_FLOW_ISSUES_DIR=.work/issues
source {shlex.quote(str(FLOW_STATE))}
queue_state_read_field() {{
  awk -F '\\t' -v requested="$3" '$1 == requested {{ print $2; exit }}' "$1"
}}
run_state_dir={shlex.quote(str(run_dir))}
current_batch_id=batch-1-2
issue_numbers=(1 2)
ensure_clean_worktree 'working tree must be clean'
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=repo,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )


def initialize_repo(repo: Path) -> tuple[str, str]:
    repo.mkdir()
    git(repo, "init", "-b", "batch/1-2")
    git(repo, "config", "user.name", "Queue Test")
    git(repo, "config", "user.email", "queue@example.test")
    (repo / "target.txt").write_text("base\n", encoding="utf-8")
    git(repo, "add", "target.txt")
    git(repo, "commit", "-m", "base")
    batch_base = git(repo, "rev-parse", "HEAD")
    (repo / "target.txt").write_text("base\nissue-one\n", encoding="utf-8")
    git(repo, "add", "target.txt")
    git(repo, "commit", "-m", "chore: address issue #1")
    issue_one_commit = git(repo, "rev-parse", "HEAD")
    return batch_base, issue_one_commit


def write_two_issue_state(run_dir: Path, batch_base: str, issue_one_commit: str, issue_two_state: str = "planned") -> None:
    batch_dir = run_dir / "batches" / "batch-1-2"
    write_state(
        batch_dir / "batch.state",
        state="issues_running",
        branch="batch/1-2",
        base_commit=batch_base,
    )
    write_state(
        batch_dir / "issues" / "1.state",
        state="acknowledged",
        base_commit=batch_base,
        commit_sha=issue_one_commit,
    )
    write_state(
        batch_dir / "issues" / "2.state",
        state=issue_two_state,
        base_commit=issue_one_commit if issue_two_state == "running" else "none",
        commit_sha="none",
    )


def test_queue_rejects_unrelated_commit_between_issues(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    batch_base, issue_one_commit = initialize_repo(repo)
    run_dir = repo / ".work" / "queue" / "runs" / "run-test"
    write_two_issue_state(run_dir, batch_base, issue_one_commit)

    clean_result = invoke_frontier_check(repo, run_dir)
    assert clean_result.returncode == 0, clean_result.stderr

    (repo / "unrelated.txt").write_text("not part of issue 2\n", encoding="utf-8")
    git(repo, "add", "unrelated.txt")
    git(repo, "commit", "-m", "unrelated queue commit")
    unrelated_commit = git(repo, "rev-parse", "HEAD")

    rejected = invoke_frontier_check(repo, run_dir)
    assert rejected.returncode != 0
    assert "cannot become Issue 2 base" in rejected.stderr
    assert issue_one_commit in rejected.stderr
    assert unrelated_commit in rejected.stderr


def test_queue_accepts_running_commit_kill_window_only_for_direct_child(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    batch_base, issue_one_commit = initialize_repo(repo)
    (repo / "target.txt").write_text("base\nissue-one\nissue-two\n", encoding="utf-8")
    git(repo, "add", "target.txt")
    git(repo, "commit", "-m", "chore: address issue #2")

    run_dir = repo / ".work" / "queue" / "runs" / "run-test"
    write_two_issue_state(run_dir, batch_base, issue_one_commit, issue_two_state="running")

    result = invoke_frontier_check(repo, run_dir)
    assert result.returncode == 0, result.stderr
