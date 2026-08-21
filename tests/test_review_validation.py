from __future__ import annotations

import csv
import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
REVIEW_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
HISTORY_HELPERS = REPO_ROOT / "tools" / "codex" / "lib" / "history_helpers.sh"
LEDGER_HEADER = "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"
BLOCKER_FINDING = "blocker finding"
MAJOR_FINDING = "major finding"


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


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


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


def write_two_finding_ledger(path: Path) -> None:
    path.write_text(
        LEDGER_HEADER
        + f"F0001\tmajor\t1\t1\tpresent\tunresolved\t{MAJOR_FINDING}\n"
        + f"F0002\tblocker\t1\t1\tpresent\tunresolved\t{BLOCKER_FINDING}\n",
        encoding="utf-8",
    )


def run_active_finding_flow(
    fixtures_dir: Path,
    work_dir: Path,
    *,
    actions: tuple[str, ...],
    max_fix_rounds: int,
) -> subprocess.CompletedProcess[str]:
    actions_file = fixtures_dir / "fix-actions.txt"
    actions_file.write_text("\n".join(actions) + "\n", encoding="utf-8")
    script = f"""
set -euo pipefail
source {shlex.quote(str(HISTORY_HELPERS))}
source {shlex.quote(str(REVIEW_HELPERS))}

fixtures_dir="$1"
work_dir="$2"
actions_file="$3"
history_dir="${{work_dir}}/history"
events="${{work_dir}}/events.log"
active_observations="${{work_dir}}/active-observations.tsv"
mkdir -p "$history_dir"

review_diff="${{work_dir}}/review.diff"
review_untracked="${{work_dir}}/review.untracked.txt"
review_summary="${{work_dir}}/review.summary.txt"
review_snapshot="${{work_dir}}/review.snapshot.state"
fix_review_snapshot="${{work_dir}}/fix-from-review.snapshot.state"
review_prompt="${{work_dir}}/review.prompt.md"
fix_review_prompt="${{work_dir}}/fix-from-review.prompt.md"
review_raw_output="${{work_dir}}/review.raw.txt"
review_output="${{work_dir}}/review.txt"
review_details="${{work_dir}}/review-details.tsv"
review_findings_ledger="${{work_dir}}/findings.tsv"
pending_findings="${{work_dir}}/pending-findings.tsv"
pending_finding_details="${{work_dir}}/pending-finding-details.tsv"
active_finding="${{work_dir}}/active-finding.tsv"
active_finding_details="${{work_dir}}/active-finding-details.tsv"
fix_resolution_report="${{work_dir}}/fix-resolution.tsv"
review_verification="${{work_dir}}/review-verification.tsv"
fix_review_log="${{work_dir}}/fix-from-review.log"
review_run_round=0
fix_review_round=0
snapshot_sequence=0
issue_number=1
CODEX_FLOW_REVIEW_REASONING=medium
CODEX_FLOW_REVIEW_FIX_REASONING=high
CODEX_FLOW_MAX_REVIEW_FIX_ROUNDS="$4"

log_info() {{ :; }}
log_fail_with_path() {{ printf '%s: %s\n' "$1" "$2" >&2; }}
generate_review_material() {{
  : > "$review_diff"
  : > "$review_untracked"
  : > "$review_summary"
}}
capture_review_snapshot() {{
  snapshot_sequence=$((snapshot_sequence + 1))
  printf 'snapshot-%s\n' "$snapshot_sequence" > "$1"
}}
assert_review_snapshot_matches() {{ [[ -f "$1" ]]; }}
ensure_issue_token_usage_tsv() {{ :; }}
ensure_checks_pass() {{ printf 'full-checks\n' >> "$events"; }}
run_codex_phase() {{
  local operation="$1"
  local invocation="$2"
  local output_file="$5"
  local snapshot_file="${{8:-}}"
  local fixture action active_id active_severity active_text
  local detail_id detail_severity detail_text evidence impact required_outcome constraints validation
  local -a active_rows=() detail_rows=()

  if [[ "$operation" == review ]]; then
    fixture="${{fixtures_dir}}/review-${{invocation}}.txt"
    [[ -f "$fixture" ]]
    printf 'review\n' >> "$events"
    cp -- "$fixture" "$output_file"
    return 0
  fi

  [[ "$operation" == fix-from-review ]]
  [[ "$snapshot_file" == "$fix_review_snapshot" && -f "$snapshot_file" ]]
  mapfile -t active_rows < <(tail -n +2 -- "$active_finding")
  mapfile -t detail_rows < <(tail -n +2 -- "$active_finding_details")
  [[ "${{#active_rows[@]}}" -eq 1 && "${{#detail_rows[@]}}" -eq 1 ]]
  IFS=$'\t' read -r active_id active_severity active_text <<< "${{active_rows[0]}}"
  IFS=$'\t' read -r \
    detail_id detail_severity detail_text evidence impact required_outcome constraints validation \
    <<< "${{detail_rows[0]}}"
  [[ "$active_id" == "$detail_id" ]]
  [[ "$active_severity" == "$detail_severity" ]]
  [[ "$active_text" == "$detail_text" ]]
  printf 'fix:%s\n' "$active_id" >> "$events"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$invocation" "$active_id" "$(( ${{#active_rows[@]}} + 1 ))" \
    "$(( ${{#detail_rows[@]}} + 1 ))" "$detail_id" "$active_severity" \
    "$active_text" "$(< "$snapshot_file")" >> "$active_observations"

  action="$(sed -n "${{invocation}}p" "$actions_file")"
  case "$action" in
    fixed|false_positive|cannot_fix)
      printf 'resolution:\n- %s | %s | claim for %s\n' "$active_id" "$action" "$active_id" > "$output_file"
      ;;
    wrong)
      printf 'resolution:\n- F9999 | fixed | inactive claim\n' > "$output_file"
      ;;
    multiple)
      printf 'resolution:\n- %s | fixed | active claim\n- F9999 | fixed | extra claim\n' \
        "$active_id" > "$output_file"
      ;;
    mutate_active)
      printf '%s\n' \
        $'finding_id\tseverity\ttext' \
        $'F9999\tmajor\tmutated active finding' \
        > "$active_finding"
      printf 'resolution:\n- F9999 | fixed | mutated active claim\n' > "$output_file"
      ;;
    *)
      printf 'Missing Fixer action for invocation %s.\n' "$invocation" >&2
      return 1
      ;;
  esac
}}

ensure_review_accepted
"""
    return run_bash(
        script,
        fixtures_dir,
        work_dir,
        actions_file,
        str(max_fix_rounds),
    )


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


def test_issue_review_processes_one_active_finding_at_a_time_before_checks(
    tmp_path: Path,
) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    write_review(
        fixtures / "review-1.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
    )
    write_review(
        fixtures / "review-2.txt",
        accept="yes",
        blocker=("none",),
        major=("none",),
        verification=(
            "F0002 | resolved | blocker verified",
            "F0001 | resolved | major verified",
        ),
    )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=("fixed", "fixed"),
        max_fix_rounds=1,
    )

    assert completed.returncode == 0, completed.stderr
    assert (work_dir / "events.log").read_text(encoding="utf-8").splitlines() == [
        "review",
        "fix:F0002",
        "fix:F0001",
        "full-checks",
        "review",
    ]
    observations = [
        line.split("\t")
        for line in (work_dir / "active-observations.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    assert observations == [
        ["1", "F0002", "2", "2", "F0002", "blocker", BLOCKER_FINDING, "snapshot-2"],
        ["2", "F0001", "2", "2", "F0001", "major", MAJOR_FINDING, "snapshot-3"],
    ]
    assert (work_dir / "fix-resolution.tsv").read_text(encoding="utf-8") == (
        "finding_id\taction\tnote\n"
        "F0002\tfixed\tclaim for F0002\n"
        "F0001\tfixed\tclaim for F0001\n"
    )
    assert (work_dir / "review-verification.tsv").read_text(encoding="utf-8") == (
        "finding_id\tresolution\tnote\n"
        "F0002\tresolved\tblocker verified\n"
        "F0001\tresolved\tmajor verified\n"
    )
    assert (work_dir / "findings.tsv").read_text(encoding="utf-8") == (
        LEDGER_HEADER
        + f"F0001\tmajor\t1\t1\tnot_observed\tresolved\t{MAJOR_FINDING}\n"
        + f"F0002\tblocker\t1\t1\tnot_observed\tresolved\t{BLOCKER_FINDING}\n"
    )


def test_reviewer_can_resolve_finding_incidentally_fixed_by_another_fixer(
    tmp_path: Path,
) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    write_review(
        fixtures / "review-1.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
    )
    write_review(
        fixtures / "review-2.txt",
        accept="yes",
        blocker=("none",),
        major=("none",),
        verification=(
            "F0002 | resolved | primary fix verified",
            "F0001 | resolved | earlier work incidentally resolved this finding",
        ),
    )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=("fixed", "cannot_fix"),
        max_fix_rounds=1,
    )

    assert completed.returncode == 0, completed.stderr
    assert read_tsv(work_dir / "fix-resolution.tsv") == [
        {"finding_id": "F0002", "action": "fixed", "note": "claim for F0002"},
        {
            "finding_id": "F0001",
            "action": "cannot_fix",
            "note": "claim for F0001",
        },
    ]
    assert read_tsv(work_dir / "review-verification.tsv") == [
        {
            "finding_id": "F0002",
            "resolution": "resolved",
            "note": "primary fix verified",
        },
        {
            "finding_id": "F0001",
            "resolution": "resolved",
            "note": "earlier work incidentally resolved this finding",
        },
    ]


@pytest.mark.parametrize("invalid_action", ["wrong", "multiple"])
def test_issue_review_rejects_inactive_or_multi_id_fixer_output(
    tmp_path: Path,
    invalid_action: str,
) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    write_review(
        fixtures / "review-1.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
    )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=(invalid_action,),
        max_fix_rounds=1,
    )

    assert completed.returncode != 0
    assert "Fix resolution report is invalid" in completed.stderr
    assert (work_dir / "events.log").read_text(encoding="utf-8").splitlines() == [
        "review",
        "fix:F0002",
    ]
    assert (work_dir / "fix-resolution.tsv").read_text(encoding="utf-8") == (
        "finding_id\taction\tnote\n"
    )
    assert not (work_dir / "history" / "fix-resolution.round-01.tsv").exists()


def test_issue_review_rejects_active_artifact_mutation_by_fixer(tmp_path: Path) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    write_review(
        fixtures / "review-1.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
    )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=("mutate_active",),
        max_fix_rounds=1,
    )

    assert completed.returncode != 0
    assert "Active finding artifacts changed during the Fixer invocation" in completed.stderr
    assert (work_dir / "fix-resolution.tsv").read_text(encoding="utf-8") == (
        "finding_id\taction\tnote\n"
    )


def test_issue_review_max_fix_rounds_counts_rejected_cycles_not_fixer_invocations(
    tmp_path: Path,
) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    for round_number, verification in (
        (1, ("none",)),
        (
            2,
            (
                "F0002 | unresolved | blocker remains",
                "F0001 | unresolved | major remains",
            ),
        ),
    ):
        write_review(
            fixtures / f"review-{round_number}.txt",
            blocker=(BLOCKER_FINDING,),
            major=(MAJOR_FINDING,),
            verification=verification,
        )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=("cannot_fix", "cannot_fix"),
        max_fix_rounds=1,
    )

    assert completed.returncode != 0
    assert "review did not reach acceptance after 1 fix rounds" in completed.stderr
    assert (work_dir / "events.log").read_text(encoding="utf-8").splitlines() == [
        "review",
        "fix:F0002",
        "fix:F0001",
        "full-checks",
        "review",
    ]
    assert (work_dir / "fix-resolution.tsv").read_text(encoding="utf-8") == (
        "finding_id\taction\tnote\n"
        "F0002\tcannot_fix\tclaim for F0002\n"
        "F0001\tcannot_fix\tclaim for F0001\n"
    )


def test_issue_review_reinitializes_cumulative_report_for_next_rejected_cycle(
    tmp_path: Path,
) -> None:
    fixtures = tmp_path / "fixtures"
    work_dir = tmp_path / "work"
    fixtures.mkdir()
    work_dir.mkdir()
    write_two_finding_ledger(work_dir / "findings.tsv")
    write_review(
        fixtures / "review-1.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
    )
    write_review(
        fixtures / "review-2.txt",
        blocker=(BLOCKER_FINDING,),
        major=(MAJOR_FINDING,),
        verification=(
            "F0002 | unresolved | blocker remains",
            "F0001 | unresolved | major remains",
        ),
    )
    write_review(
        fixtures / "review-3.txt",
        accept="yes",
        blocker=("none",),
        major=("none",),
        verification=(
            "F0002 | resolved | blocker verified",
            "F0001 | resolved | major verified",
        ),
    )

    completed = run_active_finding_flow(
        fixtures,
        work_dir,
        actions=("cannot_fix", "cannot_fix", "fixed", "fixed"),
        max_fix_rounds=2,
    )

    assert completed.returncode == 0, completed.stderr
    assert (work_dir / "events.log").read_text(encoding="utf-8").splitlines() == [
        "review",
        "fix:F0002",
        "fix:F0001",
        "full-checks",
        "review",
        "fix:F0002",
        "fix:F0001",
        "full-checks",
        "review",
    ]
    assert (work_dir / "fix-resolution.tsv").read_text(encoding="utf-8") == (
        "finding_id\taction\tnote\n"
        "F0002\tfixed\tclaim for F0002\n"
        "F0001\tfixed\tclaim for F0001\n"
    )
    assert (work_dir / "history" / "fix-resolution.round-01.tsv").read_text(
        encoding="utf-8"
    ) == (
        "finding_id\taction\tnote\n"
        "F0002\tcannot_fix\tclaim for F0002\n"
        "F0001\tcannot_fix\tclaim for F0001\n"
    )
    assert (work_dir / "history" / "fix-resolution.round-02.tsv").read_bytes() == (
        work_dir / "fix-resolution.tsv"
    ).read_bytes()
