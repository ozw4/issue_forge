from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools" / "codex" / "lib" / "remote_branch_query.sh"
ISSUE_BOOTSTRAP = ROOT / "tools" / "codex" / "lib" / "issue_bootstrap.sh"
SHA = "a" * 40
BRANCH = "batch/1-1"


def make_git_stub(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    git = bin_dir / "git"
    git.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GIT_LOG"
case "${1:-}" in
  show-ref)
    exit 1
    ;;
  ls-remote)
    case "$REMOTE_MODE" in
      absent)
        exit 0
        ;;
      present)
        printf '%s\trefs/heads/%s\n' "$REMOTE_SHA" "$REMOTE_BRANCH"
        exit 0
        ;;
      error)
        printf 'authentication failed\n' >&2
        exit 128
        ;;
      multiple)
        printf '%s\trefs/heads/%s\n' "$REMOTE_SHA" "$REMOTE_BRANCH"
        printf '%s\trefs/heads/%s\n' "$REMOTE_SHA" "$REMOTE_BRANCH"
        exit 0
        ;;
      malformed)
        printf 'not-a-sha\trefs/heads/%s\n' "$REMOTE_BRANCH"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
""",
        encoding="utf-8",
    )
    git.chmod(0o755)
    return bin_dir


def invoke_issue_check(tmp_path: Path, mode: str) -> subprocess.CompletedProcess[str]:
    bin_dir = make_git_stub(tmp_path)
    script = f"""
set -euo pipefail
source {shlex.quote(str(ISSUE_BOOTSTRAP))}
ensure_issue_branch_available {shlex.quote(BRANCH)}
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GIT_LOG": str(tmp_path / "git.log"),
            "REMOTE_MODE": mode,
            "REMOTE_SHA": SHA,
            "REMOTE_BRANCH": BRANCH,
        },
    )


def invoke_legacy_queue_pattern(
    tmp_path: Path,
    *,
    mode: str,
    accepted_head: bool,
) -> subprocess.CompletedProcess[str]:
    bin_dir = make_git_stub(tmp_path)
    mutation = tmp_path / "mutation"
    if accepted_head:
        body = f"""
remote_line="$(git ls-remote --heads origin refs/heads/{BRANCH} 2>/dev/null || true)"
if [[ -n "$remote_line" ]]; then
  remote_head="${{remote_line%%[[:space:]]*}}"
  [[ "$remote_head" == {SHA} ]] || exit 23
fi
: > {shlex.quote(str(mutation))}
"""
    else:
        body = f"""
remote_line="$(git ls-remote --heads origin refs/heads/{BRANCH} 2>/dev/null || true)"
if [[ -z "$remote_line" ]]; then
  : > {shlex.quote(str(mutation))}
else
  exit 25
fi
exit 24
"""
    script = f"""
set -euo pipefail
readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
git() {{ command git "$@"; }}
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
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GIT_LOG": str(tmp_path / "git.log"),
            "REMOTE_MODE": mode,
            "REMOTE_SHA": SHA,
            "REMOTE_BRANCH": BRANCH,
        },
    )


def test_issue_branch_absence_is_only_exit_zero_empty(tmp_path: Path) -> None:
    result = invoke_issue_check(tmp_path, "absent")
    assert result.returncode == 0, result.stderr


def test_issue_branch_query_error_is_not_absence(tmp_path: Path) -> None:
    result = invoke_issue_check(tmp_path, "error")
    assert result.returncode != 0
    assert "Remote branch query failed" in result.stderr
    assert "exited 128" in result.stderr
    assert "Remote branch already exists" not in result.stderr


def test_issue_branch_presence_is_reported(tmp_path: Path) -> None:
    result = invoke_issue_check(tmp_path, "present")
    assert result.returncode != 0
    assert "Remote branch already exists" in result.stderr
    assert SHA in result.stderr


def test_malformed_remote_response_is_rejected(tmp_path: Path) -> None:
    result = invoke_issue_check(tmp_path, "malformed")
    assert result.returncode != 0
    assert "malformed response" in result.stderr


def test_legacy_branch_creation_pattern_fails_closed_on_query_error(tmp_path: Path) -> None:
    result = invoke_legacy_queue_pattern(tmp_path, mode="error", accepted_head=False)
    assert result.returncode != 0
    assert "Remote branch query failed" in result.stderr
    assert "refusing to treat the remote branch as absent" in result.stderr
    assert not (tmp_path / "mutation").exists()


def test_legacy_accepted_head_pattern_fails_closed_on_query_error(tmp_path: Path) -> None:
    result = invoke_legacy_queue_pattern(tmp_path, mode="error", accepted_head=True)
    assert result.returncode != 0
    assert "Remote branch query failed" in result.stderr
    assert "refusing to treat the remote branch as absent" in result.stderr
    assert not (tmp_path / "mutation").exists()


def test_legacy_absent_remote_branch_still_allows_creation(tmp_path: Path) -> None:
    result = invoke_legacy_queue_pattern(tmp_path, mode="absent", accepted_head=False)
    assert result.returncode != 0  # test body exits after proving the value is empty
    assert (tmp_path / "mutation").exists()
    assert "Remote branch query failed" not in result.stderr
