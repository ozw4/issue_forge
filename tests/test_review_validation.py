from __future__ import annotations

import shlex
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REVIEW_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
HISTORY_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "history_helpers.sh"
LEDGER_HEADER = "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"


def write_review(path: Path, *, valid: bool = True) -> None:
    if not valid:
        path.write_text("invalid review output\n", encoding="utf-8")
        return

    path.write_text(
        "accept: no\n\n"
        "blocker:\n- none\n\n"
        "major:\n- focused finding\n\n"
        "minor:\n- none\n\n"
        "verification:\n- none\n",
        encoding="utf-8",
    )


def run_bash(script: str, *args: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helpers
        ["bash", "-c", script, "review-validation-test", *(str(arg) for arg in args)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def run_review_round(review_fixture: Path, work_dir: Path) -> subprocess.CompletedProcess[str]:
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
review_findings_ledger="${{work_dir}}/findings.tsv"
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
run_codex_phase() {{ printf 'reviewer\n' >> "$events"; : > "$5"; }}
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

run_review_round
"""
    return run_bash(script, review_fixture, work_dir)


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
    assert not (tmp_path / "history").exists()


def test_validator_rejects_review_without_verification_section(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    raw = tmp_path / "review.raw.txt"
    review.write_text(
        "accept: yes\n\nblocker:\n- none\n\nmajor:\n- none\n\nminor:\n- none\n",
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

    events = (work_dir / "events.log").read_text(encoding="utf-8").splitlines()
    assert events.count("validate-format") == 1
    assert events.count("validate-semantics") == 1
    assert events.count("update") == 1
    assert events.count("archive:findings") == 1
    assert events.index("snapshot-match") < events.index("extract")
    assert events.index("extract") < events.index("validate-format")
    assert events.index("validate-semantics") < events.index("update")
    assert events.index("update") < events.index("archive:findings")
