from __future__ import annotations

import shlex
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REVIEW_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
HISTORY_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "history_helpers.sh"
LEDGER_HEADER = "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"


def write_review(
    path: Path,
    *,
    valid: bool = True,
    accept: str = "no",
    blocker: tuple[str, ...] = ("none",),
    major: tuple[str, ...] = ("focused finding",),
    minor: tuple[str, ...] = ("none",),
    verification: tuple[str, ...] = ("none",),
) -> None:
    if not valid:
        path.write_text("invalid review output\n", encoding="utf-8")
        return

    findings = [
        (severity, item)
        for severity, items in (("blocker", blocker), ("major", major), ("minor", minor))
        for item in items
        if item != "none"
    ]
    detail_lines = ["- none"]
    if findings:
        detail_lines = []
        for severity, finding in findings:
            detail_lines.extend(
                [
                    f"- finding: {finding}",
                    f"  severity: {severity}",
                    f"  evidence: Evidence for {finding}",
                    f"  impact: Impact of {finding}",
                    f"  required_outcome: Required outcome for {finding}",
                    "  constraints: none",
                    f"  validation: Validation for {finding}",
                ]
            )

    path.write_text(
        "\n".join(
            [
                f"accept: {accept}",
                "",
                "blocker:",
                *(f"- {item}" for item in blocker),
                "",
                "major:",
                *(f"- {item}" for item in major),
                "",
                "minor:",
                *(f"- {item}" for item in minor),
                "",
                "details:",
                *detail_lines,
                "",
                "verification:",
                *(f"- {item}" for item in verification),
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def run_bash(script: str, *args: Path | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helpers
        ["bash", "-c", script, "review-validation-test", *(str(arg) for arg in args)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def run_review_round(
    review_fixture: Path,
    work_dir: Path,
    *,
    full_flow: bool = False,
) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(HISTORY_HELPERS))}
source {shlex.quote(str(REVIEW_HELPERS))}

eval "$(declare -f update_finding_ledger | sed '1s/^update_finding_ledger/update_finding_ledger_impl/')"
eval "$(declare -f validate_review_output | sed '1s/^validate_review_output/validate_review_output_impl/')"
eval "$(declare -f validate_review_output_semantics | sed '1s/^validate_review_output_semantics/validate_review_output_semantics_impl/')"

review_fixture="$1"
work_dir="$2"
history_dir="${{work_dir}}/history"
events="${{work_dir}}/events.log"
mkdir -p "$history_dir"

review_diff="${{work_dir}}/review.diff"
review_untracked="${{work_dir}}/review.untracked.txt"
review_summary="${{work_dir}}/review.summary.txt"
review_snapshot="${{work_dir}}/review.snapshot.state"
review_prompt="${{work_dir}}/review.prompt.md"
review_raw_output="${{work_dir}}/review.raw.txt"
review_output="${{work_dir}}/review.txt"
review_details="${{work_dir}}/review-details.tsv"
review_findings_ledger="${{work_dir}}/findings.tsv"
pending_findings="${{work_dir}}/pending-findings.tsv"
pending_finding_details="${{work_dir}}/pending-finding-details.tsv"
fix_resolution_report="${{work_dir}}/fix-resolution.tsv"
review_verification="${{work_dir}}/review-verification.tsv"
review_run_round=0
issue_number=1
CODEX_FLOW_REVIEW_REASONING=medium

log_info() {{ :; }}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
generate_review_material() {{
  : > "$review_diff"
  : > "$review_untracked"
  : > "$review_summary"
  printf 'generate\n' >> "$events"
}}
capture_review_snapshot() {{ : > "$1"; }}
run_codex_phase() {{
  if [[ "$1" == fix-from-review ]]; then
    printf 'fixer\n' >> "$events"
  else
    printf 'reviewer\n' >> "$events"
  fi
  : > "$5"
}}
assert_review_snapshot_matches() {{ printf 'snapshot-match\n' >> "$events"; }}
ensure_issue_token_usage_tsv() {{ :; }}
extract_review_output() {{
  printf 'extract\n' >> "$events"
  cp "$review_fixture" "$review_output"
  archive_round_file "$review_output" review "$review_run_round" .txt
}}
archive_round_file() {{
  printf 'archive:%s\n' "$2" >> "$events"
  cp "$1" "$(history_round_path "$2" "$3" "$4")"
}}
validate_review_output() {{
  printf 'validate-format\n' >> "$events"
  validate_review_output_impl "$@"
}}
validate_review_output_semantics() {{
  printf 'validate-semantics\n' >> "$events"
  validate_review_output_semantics_impl "$@"
}}
update_finding_ledger() {{
  printf 'update\n' >> "$events"
  update_finding_ledger_impl "$@"
}}

if [[ "$3" == flow ]]; then
  ensure_review_accepted
else
  run_review_round
fi
"""
    return run_bash(script, review_fixture, work_dir, "flow" if full_flow else "round")


def run_review_validator(review: Path, validator: str) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(REVIEW_HELPERS))}
source {shlex.quote(str(REPO_ROOT / 'tools/codex/lib/batch_review_helpers.sh'))}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
review_output="$1"
review_raw_output="$1"
if [[ "$2" == issue ]]; then
  ensure_valid_review_output
else
  ensure_valid_batch_review_output "$1" "$1"
fi
"""
    return run_bash(script, review, validator)


def test_validator_has_no_ledger_or_history_side_effects(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    raw = tmp_path / "review.raw.txt"
    write_review(review)
    raw.write_text(review.read_text(encoding="utf-8"), encoding="utf-8")
    script = f"""
set -uo pipefail
source {shlex.quote(str(REVIEW_HELPERS))}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
review_output="$1"
review_raw_output="$2"
ensure_valid_review_output
"""

    completed = run_bash(script, review, raw)

    assert completed.returncode == 0, completed.stderr
    assert not (tmp_path / "findings.tsv").exists()
    assert not (tmp_path / "review-details.tsv").exists()
    assert not (tmp_path / "history").exists()


def test_validator_rejects_review_without_verification_section(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    raw = tmp_path / "review.raw.txt"
    review.write_text(
        "accept: yes\n\nblocker:\n- none\n\nmajor:\n- none\n\nminor:\n- none\n\ndetails:\n- none\n",
        encoding="utf-8",
    )
    raw.write_bytes(review.read_bytes())
    script = f"""
set -uo pipefail
source {shlex.quote(str(REVIEW_HELPERS))}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
review_output="$1"
review_raw_output="$2"
ensure_valid_review_output
"""

    completed = run_bash(script, review, raw)

    assert completed.returncode != 0
    assert "review output format is invalid" in completed.stderr


def test_reject_without_current_findings_stops_before_ledger_or_fixer(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    work_dir = tmp_path / "work"
    work_dir.mkdir()
    write_review(review, major=("none",))
    ledger = work_dir / "findings.tsv"
    original = LEDGER_HEADER + "F0001\tmajor\t1\t1\tpresent\tunresolved\texisting finding\n"
    ledger.write_text(original, encoding="utf-8")

    completed = run_review_round(review, work_dir, full_flow=True)

    assert completed.returncode != 0
    assert "review output is inconsistent with acceptance" in completed.stderr
    assert ledger.read_text(encoding="utf-8") == original
    assert not (work_dir / "history" / "findings.round-01.tsv").exists()
    assert not (work_dir / "history" / "review-details.round-01.tsv").exists()
    assert not (work_dir / "pending-findings.tsv").exists()
    assert not (work_dir / "fix-resolution.tsv").exists()
    assert not (work_dir / "review-verification.tsv").exists()
    events = (work_dir / "events.log").read_text(encoding="utf-8").splitlines()
    assert "validate-semantics" in events
    assert "update" not in events
    assert "fixer" not in events


def test_review_semantics_acceptance_finding_matrix(tmp_path: Path) -> None:
    cases = [
        ("reject-empty", "no", ("none",), ("none",), ("none",), ("none",), False),
        ("reject-minor", "no", ("none",), ("none",), ("minor finding",), ("none",), True),
        ("reject-major", "no", ("none",), ("major finding",), ("none",), ("none",), True),
        (
            "reject-verification-only",
            "no",
            ("none",),
            ("none",),
            ("none",),
            ("F0001 | resolved | Fixed.",),
            False,
        ),
        ("accept-major", "yes", ("none",), ("major finding",), ("none",), ("none",), False),
        ("accept-minor", "yes", ("none",), ("none",), ("minor finding",), ("none",), True),
    ]
    script = f"""
set -uo pipefail
source {shlex.quote(str(REVIEW_HELPERS))}
validate_review_output "$1" && validate_review_output_semantics "$1"
"""

    for name, accept, blocker, major, minor, verification, expected_valid in cases:
        review = tmp_path / f"{name}.txt"
        write_review(
            review,
            accept=accept,
            blocker=blocker,
            major=major,
            minor=minor,
            verification=verification,
        )
        completed = run_bash(script, review)
        assert (completed.returncode == 0) is expected_valid, name


def test_issue_and_batch_validators_share_empty_reject_rule(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    write_review(review, major=("none",))

    issue = run_review_validator(review, "issue")
    batch = run_review_validator(review, "batch")

    assert issue.returncode != 0
    assert "review output is inconsistent with acceptance" in issue.stderr
    assert batch.returncode != 0
    assert "batch review output is inconsistent with acceptance" in batch.stderr


def test_invalid_issue_round_does_not_change_ledger(tmp_path: Path) -> None:
    review = tmp_path / "invalid-review.txt"
    work_dir = tmp_path / "work"
    work_dir.mkdir()
    write_review(review, valid=False)
    ledger = work_dir / "findings.tsv"
    original = LEDGER_HEADER + "F0001\tmajor\t1\t1\tpresent\tunresolved\texisting finding\n"
    ledger.write_text(original, encoding="utf-8")

    completed = run_review_round(review, work_dir)

    assert completed.returncode != 0
    assert "review output format is invalid" in completed.stderr
    assert ledger.read_text(encoding="utf-8") == original
    assert not (work_dir / "history" / "findings.round-01.tsv").exists()
    events = (work_dir / "events.log").read_text(encoding="utf-8").splitlines()
    assert "validate-format" in events
    assert "update" not in events
    assert "archive:findings" not in events


def test_valid_issue_round_records_findings_once_after_validation(tmp_path: Path) -> None:
    review = tmp_path / "valid-review.txt"
    work_dir = tmp_path / "work"
    work_dir.mkdir()
    write_review(review)

    completed = run_review_round(review, work_dir)

    assert completed.returncode == 0, completed.stderr
    ledger = work_dir / "findings.tsv"
    assert ledger.read_text(encoding="utf-8") == (
        LEDGER_HEADER + "F0001\tmajor\t1\t1\tpresent\tunresolved\tfocused finding\n"
    )
    finding_histories = list((work_dir / "history").glob("findings.round-*.tsv"))
    assert [path.name for path in finding_histories] == ["findings.round-01.tsv"]
    assert finding_histories[0].read_bytes() == ledger.read_bytes()
    details = work_dir / "review-details.tsv"
    details_history = work_dir / "history" / "review-details.round-01.tsv"
    assert details.read_text(encoding="utf-8") == (
        "severity\tfinding\tevidence\timpact\trequired_outcome\tconstraints\tvalidation\n"
        "major\tfocused finding\tEvidence for focused finding\tImpact of focused finding\t"
        "Required outcome for focused finding\tnone\tValidation for focused finding\n"
    )
    assert details_history.read_bytes() == details.read_bytes()

    events = (work_dir / "events.log").read_text(encoding="utf-8").splitlines()
    assert events.count("validate-format") == 1
    assert events.count("validate-semantics") == 1
    assert events.count("update") == 1
    assert events.count("archive:findings") == 1
    assert events.count("archive:review-details") == 1
    assert events.index("snapshot-match") < events.index("extract")
    assert events.index("extract") < events.index("validate-format")
    assert events.index("validate-semantics") < events.index("update")
    assert events.index("update") < events.index("archive:findings")
