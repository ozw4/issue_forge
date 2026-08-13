from __future__ import annotations

import csv
import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "finding_ledger.sh"
BATCH_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "batch_review_helpers.sh"
REVIEW_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
HISTORY_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "history_helpers.sh"
SNAPSHOT_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "review_snapshots.sh"


def run_helper(command: str, *args: Path | int | str) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(HELPER))}
{command} "$@"
"""
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helper
        ["bash", "-c", script, "finding-resolution-test", *(str(arg) for arg in args)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def run_review_format_validation(review: Path) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(REVIEW_HELPER))}
validate_review_output "$1"
"""
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helper
        ["bash", "-c", script, "review-format-test", str(review)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def write_review(
    path: Path,
    *,
    major: tuple[str, ...] = ("none",),
    verification: tuple[str, ...] = ("none",),
) -> None:
    path.write_text(
        "\n".join(
            [
                "accept: no",
                "",
                "blocker:",
                "- none",
                "",
                "major:",
                *(f"- {item}" for item in major),
                "",
                "minor:",
                "- none",
                "",
                "verification:",
                *(f"- {item}" for item in verification),
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def assert_ok(completed: subprocess.CompletedProcess[str]) -> None:
    assert completed.returncode == 0, completed.stderr


def initialize_finding(tmp_path: Path) -> tuple[Path, Path]:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A",))
    assert_ok(run_helper("update_finding_ledger", review, ledger, 1))
    return review, ledger


def make_fix_report(
    tmp_path: Path,
    ledger: Path,
    line: str,
) -> tuple[Path, Path]:
    pending = tmp_path / "pending-findings.tsv"
    fix_log = tmp_path / "fix.log"
    report = tmp_path / "fix-resolution.tsv"
    assert_ok(run_helper("write_pending_findings", ledger, pending))
    fix_log.write_text(f"resolution:\n- {line}\n", encoding="utf-8")
    assert_ok(run_helper("extract_fix_resolution_report", fix_log, pending, report))
    return pending, report


def apply_verification(
    review: Path,
    ledger: Path,
    fix_report: Path,
    verification_tsv: Path,
    round_number: int,
) -> None:
    assert_ok(run_helper("extract_review_verification", review, ledger, fix_report, verification_tsv))
    assert_ok(run_helper("update_finding_ledger", review, ledger, round_number, verification_tsv))


def test_pending_findings_include_only_present_unresolved_records(tmp_path: Path) -> None:
    ledger = tmp_path / "findings.tsv"
    pending = tmp_path / "pending.tsv"
    ledger.write_text(
        "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"
        "F0001\tmajor\t1\t1\tpresent\tunresolved\tinclude me\n"
        "F0002\tmajor\t1\t1\tnot_observed\tunresolved\tabsent\n"
        "F0003\tminor\t1\t1\tpresent\tresolved\tclosed\n"
        "F0004\tminor\t1\t1\tpresent\tinvalid\tinvalid\n",
        encoding="utf-8",
    )

    assert_ok(run_helper("write_pending_findings", ledger, pending))

    assert pending.read_text(encoding="utf-8") == (
        "finding_id\tseverity\ttext\nF0001\tmajor\tinclude me\n"
    )


@pytest.mark.parametrize(
    ("fix_action", "review_resolution", "expected_resolution"),
    [
        ("fixed", "resolved", "resolved"),
        ("false_positive", "invalid", "invalid"),
    ],
)
def test_reviewer_closes_finding_after_fixer_claim(
    tmp_path: Path,
    fix_action: str,
    review_resolution: str,
    expected_resolution: str,
) -> None:
    review, ledger = initialize_finding(tmp_path)
    _, report = make_fix_report(tmp_path, ledger, f"F0001 | {fix_action} | fixer claim")
    write_review(review, verification=(f"F0001 | {review_resolution} | reviewer evidence",))

    apply_verification(review, ledger, report, tmp_path / "verification.tsv", 2)

    assert read_tsv(ledger) == [
        {
            "finding_id": "F0001",
            "severity": "major",
            "first_round": "1",
            "last_seen_round": "1",
            "status": "not_observed",
            "resolution": expected_resolution,
            "text": "finding A",
        }
    ]


def test_unresolved_verification_keeps_finding_present(tmp_path: Path) -> None:
    review, ledger = initialize_finding(tmp_path)
    _, report = make_fix_report(tmp_path, ledger, "F0001 | cannot_fix | contract conflict")
    write_review(
        review,
        major=("finding A",),
        verification=("F0001 | unresolved | conflict remains",),
    )

    apply_verification(review, ledger, report, tmp_path / "verification.tsv", 2)

    row = read_tsv(ledger)[0]
    assert row["resolution"] == "unresolved"
    assert row["status"] == "present"
    assert row["last_seen_round"] == "2"


@pytest.mark.parametrize("closed_resolution", ["resolved", "invalid"])
def test_closed_finding_reappears_as_unresolved_with_same_id(
    tmp_path: Path, closed_resolution: str
) -> None:
    review, ledger = initialize_finding(tmp_path)
    action = "fixed" if closed_resolution == "resolved" else "false_positive"
    _, report = make_fix_report(tmp_path, ledger, f"F0001 | {action} | claim")
    write_review(review, verification=(f"F0001 | {closed_resolution} | evidence",))
    apply_verification(review, ledger, report, tmp_path / "verification.tsv", 2)
    write_review(review, major=("finding A",))

    assert_ok(run_helper("update_finding_ledger", review, ledger, 3))

    row = read_tsv(ledger)[0]
    assert row["finding_id"] == "F0001"
    assert row["resolution"] == "unresolved"
    assert row["status"] == "present"
    assert row["last_seen_round"] == "3"


@pytest.mark.parametrize(
    "lines",
    [
        ("F0001 | fixed | done",),
        ("F0001 | fixed | done", "F9999 | fixed | unknown"),
        ("F0001 | fixed | done", "F0001 | fixed | duplicate"),
        ("F0001 | waived | invalid action", "F0002 | fixed | done"),
    ],
)
def test_invalid_fixer_reports_are_rejected_atomically(
    tmp_path: Path, lines: tuple[str, ...]
) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A", "finding B"))
    assert_ok(run_helper("update_finding_ledger", review, ledger, 1))
    pending = tmp_path / "pending.tsv"
    assert_ok(run_helper("write_pending_findings", ledger, pending))
    fix_log = tmp_path / "fix.log"
    fix_log.write_text("resolution:\n" + "".join(f"- {line}\n" for line in lines), encoding="utf-8")
    output = tmp_path / "fix-resolution.tsv"
    original = b"existing report\n"
    output.write_bytes(original)

    completed = run_helper("extract_fix_resolution_report", fix_log, pending, output)

    assert completed.returncode != 0
    assert output.read_bytes() == original


@pytest.mark.parametrize(
    ("note", "expected_valid"),
    [
        ("Replaced the pipeline with one awk command.", True),
        ("Replaced grep | awk with one command.", False),
        ("Replaced grep\tawk with one command.", False),
    ],
)
def test_fix_resolution_note_contract_is_atomic(
    tmp_path: Path, note: str, expected_valid: bool
) -> None:
    _, ledger = initialize_finding(tmp_path)
    pending = tmp_path / "pending.tsv"
    assert_ok(run_helper("write_pending_findings", ledger, pending))
    fix_log = tmp_path / "fix.log"
    fix_log.write_text(f"resolution:\n- F0001 | fixed | {note}\n", encoding="utf-8")
    output = tmp_path / "fix-resolution.tsv"
    original = b"existing report\n"
    output.write_bytes(original)

    completed = run_helper("extract_fix_resolution_report", fix_log, pending, output)

    assert (completed.returncode == 0) is expected_valid
    if expected_valid:
        assert read_tsv(output) == [
            {"finding_id": "F0001", "action": "fixed", "note": note}
        ]
    else:
        assert "Fix resolution report is invalid" in completed.stderr
        assert output.read_bytes() == original


@pytest.mark.parametrize(
    ("note", "expected_valid"),
    [
        ("Replaced the pipeline with one awk command.", True),
        ("Replaced grep | awk with one command.", False),
        ("Replaced grep\tawk with one command.", False),
    ],
)
def test_review_verification_note_contract_matches_format_validation(
    tmp_path: Path, note: str, expected_valid: bool
) -> None:
    review, ledger = initialize_finding(tmp_path)
    _, report = make_fix_report(tmp_path, ledger, "F0001 | fixed | fixer claim")
    write_review(review, verification=(f"F0001 | resolved | {note}",))
    original_ledger = ledger.read_bytes()
    output = tmp_path / "verification.tsv"
    original_output = b"existing verification\n"
    output.write_bytes(original_output)

    format_result = run_review_format_validation(review)
    extraction_result = run_helper(
        "extract_review_verification", review, ledger, report, output
    )

    assert (format_result.returncode == 0) is expected_valid
    assert (extraction_result.returncode == 0) is expected_valid
    assert ledger.read_bytes() == original_ledger
    if expected_valid:
        assert read_tsv(output) == [
            {"finding_id": "F0001", "resolution": "resolved", "note": note}
        ]
    else:
        assert "Review verification is invalid" in extraction_result.stderr
        assert output.read_bytes() == original_output


@pytest.mark.parametrize(
    "verification",
    [
        ("F0001 | resolved | done",),
        ("F0001 | resolved | done", "F9999 | invalid | unknown"),
        ("F0001 | resolved | done", "F0001 | resolved | duplicate"),
    ],
)
def test_missing_unknown_and_duplicate_reviewer_verification_are_rejected(
    tmp_path: Path, verification: tuple[str, ...]
) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A", "finding B"))
    assert_ok(run_helper("update_finding_ledger", review, ledger, 1))
    pending = tmp_path / "pending.tsv"
    report = tmp_path / "fix.tsv"
    fix_log = tmp_path / "fix.log"
    assert_ok(run_helper("write_pending_findings", ledger, pending))
    fix_log.write_text(
        "resolution:\n- F0001 | fixed | first\n- F0002 | fixed | second\n",
        encoding="utf-8",
    )
    assert_ok(run_helper("extract_fix_resolution_report", fix_log, pending, report))
    write_review(review, verification=verification)
    original_ledger = ledger.read_bytes()

    completed = run_helper(
        "extract_review_verification", review, ledger, report, tmp_path / "verification.tsv"
    )

    assert completed.returncode != 0
    assert ledger.read_bytes() == original_ledger


@pytest.mark.parametrize(
    ("resolution", "current_findings"),
    [
        ("resolved", ("finding A",)),
        ("invalid", ("finding A",)),
        ("unresolved", ("none",)),
    ],
)
def test_reviewer_verification_must_match_current_findings(
    tmp_path: Path, resolution: str, current_findings: tuple[str, ...]
) -> None:
    review, ledger = initialize_finding(tmp_path)
    _, report = make_fix_report(tmp_path, ledger, "F0001 | fixed | claim")
    write_review(
        review,
        major=current_findings,
        verification=(f"F0001 | {resolution} | evidence",),
    )
    original_ledger = ledger.read_bytes()

    completed = run_helper(
        "extract_review_verification", review, ledger, report, tmp_path / "verification.tsv"
    )

    assert completed.returncode != 0
    assert ledger.read_bytes() == original_ledger


def test_initial_review_requires_none_verification(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    output = tmp_path / "verification.tsv"
    write_review(review)
    assert_ok(run_helper("extract_review_verification", review, tmp_path / "missing-ledger.tsv", "", output))
    assert output.read_text(encoding="utf-8") == "finding_id\tresolution\tnote\n"

    write_review(review, verification=("F0001 | resolved | unexpected",))
    completed = run_helper(
        "extract_review_verification", review, tmp_path / "missing-ledger.tsv", "", output
    )
    assert completed.returncode != 0


def run_no_change_batch_fix(tmp_path: Path, action: str) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(REVIEW_HELPER))}
source {shlex.quote(str(BATCH_HELPER))}

batch_dir="$1"
batch_state_dir="$2"
action="$3"
mkdir -p "$batch_dir/history" "$batch_state_dir/history"
printf '%s\n' \
  $'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext' \
  $'F0001\tmajor\t1\t1\tpresent\tunresolved\tfinding A' \
  > "$batch_state_dir/findings.tsv"
: > "$batch_dir/batch-review.snapshot.state"
review_calls=0
CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS=1

run_batch_review_once() {{
  review_calls=$((review_calls + 1))
  if [[ "$review_calls" -eq 1 ]]; then
    printf '%s\n' 'accept: no' > "$batch_dir/batch-review.txt"
  else
    printf '%s\n' 'accept: yes' > "$batch_dir/batch-review.txt"
    printf 'review-2\n' >> "$batch_dir/events"
  fi
}}
write_fix_from_batch_review_prompt_file() {{ : > "$3"; }}
assert_review_snapshot_matches() {{ :; }}
ensure_clean_worktree() {{ :; }}
log_info() {{ printf '%s\n' "$1" >> "$batch_dir/events"; }}
run_codex_batch_write() {{
  printf 'resolution:\n- F0001 | %s | claim\n' "$action" > "$4"
}}
ensure_batch_token_usage_tsv() {{ :; }}
status_outside_work() {{ :; }}
commit_issue_changes() {{ printf 'commit\n' >> "$batch_dir/events"; }}
ensure_batch_checks_pass() {{ printf 'checks\n' >> "$batch_dir/events"; }}

ensure_batch_review_accepted \
  "$batch_dir" "$batch_dir/issues.txt" base 1 1 '#1' medium high high "$batch_state_dir"
"""
    return subprocess.run(  # noqa: S603 - exercises trusted repo-local shell flow
        ["bash", "-c", script, "batch-no-change-test", str(tmp_path / "batch"), str(tmp_path / "state"), action],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


@pytest.mark.parametrize("action", ["false_positive", "cannot_fix"])
def test_batch_no_change_non_fixed_report_reaches_next_review(tmp_path: Path, action: str) -> None:
    completed = run_no_change_batch_fix(tmp_path, action)

    assert completed.returncode == 0, completed.stderr
    events = (tmp_path / "batch" / "events").read_text(encoding="utf-8").splitlines()
    assert "review-2" in events
    assert "commit" not in events
    assert "checks" not in events


def test_batch_no_change_fixed_report_is_hard_error(tmp_path: Path) -> None:
    completed = run_no_change_batch_fix(tmp_path, "fixed")

    assert completed.returncode != 0
    assert "reported fixed findings but produced no repository changes" in completed.stderr
    events = (tmp_path / "batch" / "events").read_text(encoding="utf-8").splitlines()
    assert "review-2" not in events


def run_batch_lifecycle(
    batch_dir: Path,
    batch_state_dir: Path,
    *,
    stop_after: str = "",
    accepted_round: int = 2,
    max_fix_rounds: int = 3,
) -> subprocess.CompletedProcess[str]:
    script = f"""
set -euo pipefail
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(REVIEW_HELPER))}
source {shlex.quote(str(BATCH_HELPER))}

batch_dir="$1"
batch_state_dir="$2"
stop_after="$3"
accepted_round="$4"
CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS="$5"
mkdir -p "$batch_dir/history" "$batch_state_dir/history"
if [[ ! -f "$batch_state_dir/findings.tsv" ]]; then
  printf '%s\n' \
    $'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext' \
    $'F0001\tmajor\t1\t1\tpresent\tunresolved\tfinding A' \
    > "$batch_state_dir/findings.tsv"
fi
: > "$batch_dir/batch-review.snapshot.state"

run_batch_review_once() {{
  local round="$6"
  printf 'review:%s\n' "$round" >> "$batch_dir/events"
  if [[ "$round" -ge "$accepted_round" ]]; then
    printf '%s\n' 'accept: yes' > "$batch_dir/batch-review.txt"
  else
    printf '%s\n' 'accept: no' > "$batch_dir/batch-review.txt"
  fi
}}
write_fix_from_batch_review_prompt_file() {{ : > "$3"; }}
assert_review_snapshot_matches() {{ :; }}
ensure_clean_worktree() {{ :; }}
log_info() {{ :; }}
run_codex_batch_write() {{
  printf 'fix:%s\n' "$2" >> "$batch_dir/events"
  printf 'resolution:\n- F0001 | false_positive | reviewed claim\n' > "$4"
}}
ensure_batch_token_usage_tsv() {{ :; }}
status_outside_work() {{ :; }}
commit_issue_changes() {{ :; }}
ensure_batch_checks_pass() {{ :; }}
queue_failpoint() {{
  if [[ -n "$stop_after" && "$stop_after" == "$1" ]]; then
    printf 'stop:%s\n' "$1" >> "$batch_dir/events"
    exit 86
  fi
}}

ensure_batch_review_accepted \
  "$batch_dir" "$batch_dir/issues.txt" base 1 1 '#1' medium high high "$batch_state_dir"
"""
    return subprocess.run(  # noqa: S603 - exercises trusted repo-local shell flow
        [
            "bash",
            "-c",
            script,
            "batch-lifecycle-test",
            str(batch_dir),
            str(batch_state_dir),
            stop_after,
            str(accepted_round),
            str(max_fix_rounds),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def read_lifecycle_state(batch_state_dir: Path) -> dict[str, str]:
    state_file = batch_state_dir / "review-lifecycle.state"
    return dict(
        line.split("\t", maxsplit=1)
        for line in state_file.read_text(encoding="utf-8").splitlines()
    )


def run_batch_commit_boundary(
    repo: Path,
    *,
    stop_after: str = "",
) -> subprocess.CompletedProcess[str]:
    script = f"""
set -euo pipefail
source {shlex.quote(str(HISTORY_HELPER))}
source {shlex.quote(str(REVIEW_HELPER))}
source {shlex.quote(str(SNAPSHOT_HELPER))}
source {shlex.quote(str(BATCH_HELPER))}

stop_after="$1"
batch_dir="$PWD/.work/queue/batches/batch-1"
batch_state_dir="$PWD/.work/queue/runs/run-a/batches/batch-1"
lifecycle_state="$batch_state_dir/review-lifecycle.state"
snapshot="$batch_dir/batch-review.snapshot.state"
CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS=1
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(':(exclude).work')
mkdir -p "$batch_dir/history" "$batch_state_dir/history"

if [[ ! -f "$batch_state_dir/findings.tsv" ]]; then
  printf '%s\n' \
    $'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext' \
    $'F0001\tmajor\t1\t1\tpresent\tunresolved\tfinding A' \
    > "$batch_state_dir/findings.tsv"
  printf '%s\n' 'accept: no' > "$batch_dir/batch-review.txt"
  capture_review_snapshot "$snapshot"
  initialize_batch_review_lifecycle "$lifecycle_state"
  write_batch_review_lifecycle "$lifecycle_state" 1 1 fix
fi

run_batch_review_once() {{
  printf 'review:%s\n' "$6" >> "$batch_dir/events"
  printf '%s\n' 'accept: yes' > "$batch_dir/batch-review.txt"
}}
write_fix_from_batch_review_prompt_file() {{ : > "$3"; }}
ensure_clean_worktree() {{
  [[ -z "$(status_outside_work)" ]] || exit 1
}}
status_outside_work() {{
  git status --porcelain --untracked-files=all -- . ':(exclude).work'
}}
log_info() {{ printf 'log:%s\n' "$1" >> "$batch_dir/events"; }}
run_codex_batch_write() {{
  printf 'fix-agent:%s\n' "$2" >> "$batch_dir/events"
  printf '%s\n' fixed-by-review > target.txt
  printf 'resolution:\n- F0001 | fixed | applied fix\n' > "$4"
}}
ensure_batch_token_usage_tsv() {{ :; }}
commit_issue_changes() {{
  git add target.txt
  git commit -m "$1" >/dev/null
  printf 'commit:%s\n' "$(git rev-parse HEAD)" >> "$batch_dir/events"
}}
ensure_batch_checks_pass() {{ printf 'checks\n' >> "$batch_dir/events"; }}
queue_failpoint() {{
  if [[ -n "$stop_after" && "$stop_after" == "$1" ]]; then
    printf 'stop:%s\n' "$1" >> "$batch_dir/events"
    exit 86
  fi
}}

ensure_batch_review_accepted \
  "$batch_dir" "$batch_dir/issues.txt" base 1 1 '#1' medium high high "$batch_state_dir"
"""
    return subprocess.run(  # noqa: S603 - exercises trusted repo-local shell flow
        ["bash", "-c", script, "batch-commit-boundary-test", stop_after],
        cwd=repo,
        capture_output=True,
        check=False,
        text=True,
    )


def initialize_batch_commit_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    (repo / "target.txt").write_text("before\n", encoding="utf-8")
    subprocess.run(["git", "add", "target.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", "initial"], cwd=repo, check=True)
    return repo


@pytest.mark.parametrize(
    ("stop_after", "checks_before_resume", "checks_after_resume"),
    [
        ("after_batch_review_fix_commit", 0, 1),
        ("after_batch_review_fix_checks", 1, 2),
    ],
)
def test_batch_resume_reconciles_committed_fix_before_lifecycle_update(
    tmp_path: Path,
    stop_after: str,
    checks_before_resume: int,
    checks_after_resume: int,
) -> None:
    repo = initialize_batch_commit_repo(tmp_path)
    batch_dir = repo / ".work" / "queue" / "batches" / "batch-1"
    state_dir = repo / ".work" / "queue" / "runs" / "run-a" / "batches" / "batch-1"

    stopped = run_batch_commit_boundary(repo, stop_after=stop_after)
    assert stopped.returncode == 86, stopped.stderr
    assert read_lifecycle_state(state_dir)["next_action"] == "fix"
    commits_after_stop = subprocess.run(
        ["git", "rev-list", "--count", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    events_before_resume = (batch_dir / "events").read_text(encoding="utf-8").splitlines()
    assert events_before_resume.count("fix-agent:1") == 1
    assert events_before_resume.count("checks") == checks_before_resume
    assert commits_after_stop == "2"

    resumed = run_batch_commit_boundary(repo)
    assert resumed.returncode == 0, resumed.stderr
    events = (batch_dir / "events").read_text(encoding="utf-8").splitlines()
    commits_after_resume = subprocess.run(
        ["git", "rev-list", "--count", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    state = read_lifecycle_state(state_dir)

    assert events.count("fix-agent:1") == 1
    assert len([event for event in events if event.startswith("commit:")]) == 1
    assert events.count("checks") == checks_after_resume
    assert events.count("review:2") == 1
    assert commits_after_resume == "2"
    assert (state["review_round"], state["fix_round"], state["next_action"]) == (
        "2",
        "1",
        "complete",
    )


def test_batch_resume_after_rejected_review_starts_with_fix(tmp_path: Path) -> None:
    batch_dir = tmp_path / "compat" / "batch-1"
    state_dir = tmp_path / "run-a" / "batches" / "batch-1"

    stopped = run_batch_lifecycle(
        batch_dir,
        state_dir,
        stop_after="after_batch_review_lifecycle_fix",
    )
    assert stopped.returncode == 86
    assert read_lifecycle_state(state_dir) | {"updated_at": "ignored"} == {
        "schema_version": "1",
        "review_round": "1",
        "fix_round": "1",
        "next_action": "fix",
        "updated_at": "ignored",
    }

    resumed = run_batch_lifecycle(batch_dir, state_dir)
    assert resumed.returncode == 0, resumed.stderr
    events = (batch_dir / "events").read_text(encoding="utf-8").splitlines()
    assert events.count("review:1") == 1
    assert events.count("fix:1") == 1
    assert events.count("review:2") == 1


def test_batch_resume_after_fix_starts_with_next_review(tmp_path: Path) -> None:
    batch_dir = tmp_path / "compat" / "batch-1"
    state_dir = tmp_path / "run-a" / "batches" / "batch-1"

    stopped = run_batch_lifecycle(
        batch_dir,
        state_dir,
        stop_after="after_batch_review_lifecycle_review",
    )
    assert stopped.returncode == 86
    state = read_lifecycle_state(state_dir)
    assert (state["review_round"], state["fix_round"], state["next_action"]) == (
        "2",
        "1",
        "review",
    )

    resumed = run_batch_lifecycle(batch_dir, state_dir)
    assert resumed.returncode == 0, resumed.stderr
    events = (batch_dir / "events").read_text(encoding="utf-8").splitlines()
    assert events.count("review:1") == 1
    assert events.count("fix:1") == 1
    assert events.count("review:2") == 1


def test_batch_resume_after_complete_runs_no_agents(tmp_path: Path) -> None:
    batch_dir = tmp_path / "compat" / "batch-1"
    state_dir = tmp_path / "run-a" / "batches" / "batch-1"

    stopped = run_batch_lifecycle(
        batch_dir,
        state_dir,
        stop_after="after_batch_review_lifecycle_complete",
        accepted_round=1,
    )
    assert stopped.returncode == 86
    before_resume = (batch_dir / "events").read_bytes()
    assert read_lifecycle_state(state_dir)["next_action"] == "complete"

    resumed = run_batch_lifecycle(batch_dir, state_dir, accepted_round=1)
    assert resumed.returncode == 0, resumed.stderr
    assert (batch_dir / "events").read_bytes() == before_resume


def test_batch_fix_limit_survives_resume(tmp_path: Path) -> None:
    batch_dir = tmp_path / "compat" / "batch-1"
    state_dir = tmp_path / "run-a" / "batches" / "batch-1"

    stopped = run_batch_lifecycle(
        batch_dir,
        state_dir,
        stop_after="after_batch_review_lifecycle_review",
        accepted_round=99,
        max_fix_rounds=1,
    )
    assert stopped.returncode == 86

    limited = run_batch_lifecycle(
        batch_dir,
        state_dir,
        accepted_round=99,
        max_fix_rounds=1,
    )
    assert limited.returncode != 0
    assert "did not reach acceptance after 1 fix rounds" in limited.stderr
    events_before_retry = (batch_dir / "events").read_bytes()
    state = read_lifecycle_state(state_dir)
    assert (state["review_round"], state["fix_round"], state["next_action"]) == (
        "2",
        "2",
        "fix",
    )

    limited_again = run_batch_lifecycle(
        batch_dir,
        state_dir,
        accepted_round=99,
        max_fix_rounds=1,
    )
    assert limited_again.returncode != 0
    assert (batch_dir / "events").read_bytes() == events_before_retry


def test_batch_lifecycle_state_is_run_owned(tmp_path: Path) -> None:
    run_a = tmp_path / "runs" / "run-a" / "batches" / "batch-1"
    run_b = tmp_path / "runs" / "run-b" / "batches" / "batch-1"
    script = f"""
set -euo pipefail
source {shlex.quote(str(BATCH_HELPER))}
initialize_batch_review_lifecycle "$1/review-lifecycle.state"
write_batch_review_lifecycle "$1/review-lifecycle.state" 3 2 complete
initialize_batch_review_lifecycle "$2/review-lifecycle.state"
"""
    completed = subprocess.run(  # noqa: S603 - exercises trusted repo-local shell helper
        ["bash", "-c", script, "batch-lifecycle-scope-test", str(run_a), str(run_b)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    assert read_lifecycle_state(run_a)["review_round"] == "3"
    assert read_lifecycle_state(run_a)["next_action"] == "complete"
    assert read_lifecycle_state(run_b)["review_round"] == "1"
    assert read_lifecycle_state(run_b)["next_action"] == "review"
