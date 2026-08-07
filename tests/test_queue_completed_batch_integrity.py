from __future__ import annotations

import hashlib
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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def initialize_repo(repo: Path) -> tuple[str, str]:
    repo.mkdir()
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.name", "Queue Integrity Test")
    git(repo, "config", "user.email", "queue-integrity@example.test")
    git(repo, "remote", "add", "origin", "https://example.test/owner/repo.git")
    (repo / "target.txt").write_text("base\n", encoding="utf-8")
    git(repo, "add", "target.txt")
    git(repo, "commit", "-m", "base")
    base = git(repo, "rev-parse", "HEAD")
    (repo / "target.txt").write_text("base\nissue-one\n", encoding="utf-8")
    git(repo, "add", "target.txt")
    git(repo, "commit", "-m", "chore: address issue #1")
    commit = git(repo, "rev-parse", "HEAD")
    return base, commit


def create_completed_batch_fixture(repo: Path, *, run_state: str, include_second_batch: bool) -> tuple[Path, Path, Path]:
    base, issue_commit = initialize_repo(repo)
    run_id = "run-integrity"
    run_dir = repo / ".work" / "queue" / "runs" / run_id
    issues = "1,2" if include_second_batch else "1"
    write_state(run_dir / "manifest.state", run_id=run_id, issues=issues, review_every="1")
    write_state(run_dir / "run.state", run_id=run_id, state=run_state)

    context_rel = f".work/queue/runs/{run_id}/contexts/batch-1-1/issues/1.md"
    context = repo / context_rel
    context.parent.mkdir(parents=True, exist_ok=True)
    context.write_text("# Issue #1\n\nTitle: Integrity\nURL: https://example.test/issues/1\n", encoding="utf-8")

    archive_rel = f".work/queue/runs/{run_id}/archives/batch-1-1/issues/1/{issue_commit}"
    archive = repo / archive_rel
    archive.mkdir(parents=True, exist_ok=True)
    archive_manifest = archive / "archive.manifest"
    archive_manifest.write_text("complete archive\n", encoding="utf-8")

    batch_dir = run_dir / "batches" / "batch-1-1"
    write_state(
        batch_dir / "batch.state",
        run_id=run_id,
        batch_id="batch-1-1",
        state="completed",
        base_commit=base,
        accepted_head=issue_commit,
    )
    write_state(
        batch_dir / "issues" / "1.state",
        run_id=run_id,
        batch_id="batch-1-1",
        issue_number="1",
        state="acknowledged",
        base_commit=base,
        commit_sha=issue_commit,
        context_path=context_rel,
        context_sha256=sha256(context),
        artifact_path=archive_rel,
        archive_manifest_sha256=sha256(archive_manifest),
    )

    if include_second_batch:
        second = run_dir / "batches" / "batch-2-2"
        write_state(
            second / "batch.state",
            run_id=run_id,
            batch_id="batch-2-2",
            state="planned",
            base_commit="none",
            accepted_head="none",
        )
        write_state(
            second / "issues" / "2.state",
            run_id=run_id,
            batch_id="batch-2-2",
            issue_number="2",
            state="planned",
            base_commit="none",
            commit_sha="none",
            context_path="none",
            context_sha256="none",
            artifact_path="none",
            archive_manifest_sha256="none",
        )

    return run_dir, context, archive_manifest


def invoke_integrity_boundary(repo: Path, run_dir: Path, command: str) -> subprocess.CompletedProcess[str]:
    script = f"""
set -euo pipefail
readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
CODEX_FLOW_REPO_ROOT={shlex.quote(str(repo))}
ISSUE_FORGE_ENGINE_ROOT=/outside-engine
CODEX_FLOW_WORK_ROOT=.work
CODEX_FLOW_CURRENT_ISSUE_FILE=.work/current_issue
CODEX_FLOW_CURRENT_BRANCH_FILE=.work/current_branch
CODEX_FLOW_BASE_COMMIT_FILE=.work/base_commit
CODEX_FLOW_ISSUES_DIR=.work/issues
source {shlex.quote(str(FLOW_STATE))}
queue_state_parse_file() {{
  local file="$1" output_name="$3" key value
  local -n output="$output_name"
  output=()
  while IFS=$'\t' read -r key value; do output["$key"]="$value"; done < "$file"
}}
queue_state_validate_file() {{ [[ -f "$1" && ! -L "$1" ]]; }}
validate_durable_issue_context() {{
  local path="$1" expected="$3" actual
  [[ -f "$path" && ! -L "$path" ]] || return 1
  actual="$(sha256sum "$path" | awk '{{print $1}}')"
  [[ "$actual" == "$expected" ]]
}}
validate_issue_archive() {{
  local destination="$1" expected="$5" manifest actual
  manifest="${{destination}}/archive.manifest"
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  actual="$(sha256sum "$manifest" | awk '{{print $1}}')"
  [[ "$actual" == "$expected" ]]
}}
run_id=run-integrity
current_batch_id=batch-2-2
run_state_dir={shlex.quote(str(run_dir))}
{command}
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


def test_completed_run_integrity_is_checked_before_finalization_git_boundary(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    run_dir, context, _archive_manifest = create_completed_batch_fixture(
        repo, run_state="completed", include_second_batch=False
    )

    valid = invoke_integrity_boundary(repo, run_dir, "git config --get remote.origin.url")
    assert valid.returncode == 0, valid.stderr

    context.unlink()
    rejected = invoke_integrity_boundary(repo, run_dir, "git config --get remote.origin.url")
    assert rejected.returncode != 0
    assert "Issue 1 durable context is missing or changed" in rejected.stderr


def test_completed_batch_archive_is_checked_before_next_batch_git_boundary(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    run_dir, _context, archive_manifest = create_completed_batch_fixture(
        repo, run_state="running", include_second_batch=True
    )

    valid = invoke_integrity_boundary(repo, run_dir, "git switch --detach HEAD")
    assert valid.returncode == 0, valid.stderr

    archive_manifest.unlink()
    rejected = invoke_integrity_boundary(repo, run_dir, "git switch --detach HEAD")
    assert rejected.returncode != 0
    assert "Issue 1 authoritative archive is missing or changed" in rejected.stderr
