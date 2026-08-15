from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "review_snapshots.sh"


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - invokes Git with trusted test paths
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


@pytest.fixture
def git_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init")
    git(repo, "config", "user.name", "Review Snapshot Test")
    git(repo, "config", "user.email", "snapshot@example.test")
    (repo / "tracked.txt").write_text("tracked baseline\n", encoding="utf-8")
    git(repo, "add", "tracked.txt")
    git(repo, "commit", "-m", "initial")
    (repo / "untracked.txt").write_text("untracked baseline\n", encoding="utf-8")
    return repo


def run_snapshot_helper(
    repo: Path,
    operation: str,
    snapshot_file: Path,
    context_label: str = "during test",
) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
declare -a CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(':(exclude).work')
source {shlex.quote(str(HELPER))}
{operation} "$1" "$2"
"""
    return subprocess.run(  # noqa: S603 - invokes bash with trusted test paths
        ["bash", "-c", script, "snapshot-test", str(snapshot_file), context_label],
        cwd=repo,
        capture_output=True,
        check=False,
        text=True,
    )


def capture(repo: Path, snapshot_file: Path) -> subprocess.CompletedProcess[str]:
    return run_snapshot_helper(repo, "capture_review_snapshot", snapshot_file)


def assert_matches(repo: Path, snapshot_file: Path) -> subprocess.CompletedProcess[str]:
    return run_snapshot_helper(repo, "assert_review_snapshot_matches", snapshot_file)


def test_unchanged_snapshot_matches_with_tracked_and_untracked_files(
    git_repo: Path,
) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"

    captured = capture(git_repo, snapshot_file)
    matched = assert_matches(git_repo, snapshot_file)

    assert captured.returncode == 0, captured.stderr
    assert matched.returncode == 0, matched.stderr
    fields = snapshot_file.read_text(encoding="utf-8").splitlines()
    assert [line.split("\t", 1)[0] for line in fields] == [
        "schema_version",
        "head_commit",
        "worktree_tree",
        "created_at",
    ]


def test_tracked_file_change_causes_snapshot_mismatch(git_repo: Path) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"
    assert capture(git_repo, snapshot_file).returncode == 0
    (git_repo / "tracked.txt").write_text("tracked changed\n", encoding="utf-8")

    matched = assert_matches(git_repo, snapshot_file)

    assert matched.returncode != 0
    assert "Review snapshot mismatch during test: expected tree" in matched.stderr


def test_untracked_file_change_causes_snapshot_mismatch(git_repo: Path) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"
    assert capture(git_repo, snapshot_file).returncode == 0
    (git_repo / "untracked.txt").write_text("untracked changed\n", encoding="utf-8")

    matched = assert_matches(git_repo, snapshot_file)

    assert matched.returncode != 0
    assert "Review snapshot mismatch during test: expected tree" in matched.stderr


def test_head_change_causes_mismatch_when_worktree_content_is_unchanged(
    git_repo: Path,
) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"
    assert capture(git_repo, snapshot_file).returncode == 0
    git(git_repo, "commit", "--allow-empty", "-m", "advance HEAD")

    matched = assert_matches(git_repo, snapshot_file)

    assert matched.returncode != 0
    assert "Review snapshot mismatch during test: expected HEAD" in matched.stderr


def test_excluded_work_path_does_not_change_snapshot(git_repo: Path) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"
    work_file = git_repo / ".work" / "state.txt"
    work_file.parent.mkdir()
    work_file.write_text("before\n", encoding="utf-8")
    assert capture(git_repo, snapshot_file).returncode == 0
    work_file.write_text("after\n", encoding="utf-8")

    matched = assert_matches(git_repo, snapshot_file)

    assert matched.returncode == 0, matched.stderr


def test_capture_does_not_modify_real_git_index(git_repo: Path) -> None:
    snapshot_file = git_repo.parent / "snapshot.state"
    tracked = git_repo / "tracked.txt"
    tracked.write_text("staged content\n", encoding="utf-8")
    git(git_repo, "add", "tracked.txt")
    tracked.write_text("working tree content\n", encoding="utf-8")
    before = git(git_repo, "diff", "--cached", "--binary").stdout

    captured = capture(git_repo, snapshot_file)

    after = git(git_repo, "diff", "--cached", "--binary").stdout
    assert captured.returncode == 0, captured.stderr
    assert after == before
