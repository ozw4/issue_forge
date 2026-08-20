from __future__ import annotations

import csv
import shlex
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
DETAILS_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "review_details.sh"
REVIEW_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "checks_review_helpers.sh"
LEDGER_HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "finding_ledger.sh"
DETAILS_HEADER = (
    "severity\tfinding\tevidence\timpact\trequired_outcome\tconstraints\tvalidation\n"
)
PENDING_DETAILS_HEADER = (
    "finding_id\tseverity\ttext\tevidence\timpact\trequired_outcome\tconstraints\tvalidation\n"
)
LEDGER_HEADER = (
    "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"
)
PENDING_HEADER = "finding_id\tseverity\ttext\n"


def detail_lines(severity: str, finding: str, marker: str = "") -> list[str]:
    suffix = f" {marker}" if marker else ""
    return [
        f"- finding: {finding}",
        f"  severity: {severity}",
        f"  evidence: Evidence for {finding}{suffix}",
        f"  impact: Impact of {finding}{suffix}",
        f"  required_outcome: Required outcome for {finding}{suffix}",
        "  constraints: none",
        f"  validation: Validation for {finding}{suffix}",
    ]


def review_text(
    findings: tuple[tuple[str, str], ...] = (),
    *,
    accept: str | None = None,
    details: list[str] | None = None,
    verification: tuple[str, ...] = ("none",),
) -> str:
    sections: dict[str, list[str]] = {"blocker": [], "major": [], "minor": []}
    for severity, finding in findings:
        sections[severity].append(finding)
    if accept is None:
        accept = "no" if findings else "yes"
    if details is None:
        details = ["- none"]
        if findings:
            details = [
                line
                for severity, finding in findings
                for line in detail_lines(severity, finding)
            ]
    lines = [f"accept: {accept}", ""]
    for severity in ("blocker", "major", "minor"):
        lines.append(f"{severity}:")
        lines.extend(f"- {finding}" for finding in sections[severity])
        if not sections[severity]:
            lines.append("- none")
        lines.append("")
    lines.extend(["details:", *details, "", "verification:"])
    lines.extend(f"- {item}" for item in verification)
    return "\n".join(lines) + "\n"


def run_shell(script: str, *args: Path | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helpers
        ["bash", "-c", script, "review-details-test", *(str(arg) for arg in args)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def validate(review: Path) -> subprocess.CompletedProcess[str]:
    return run_shell(
        f"source {shlex.quote(str(REVIEW_HELPER))}; validate_review_output \"$1\"",
        review,
    )


def publish_details(review: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return run_shell(
        f"source {shlex.quote(str(DETAILS_HELPER))}; "
        'write_review_details_artifact "$1" "$2"',
        review,
        output,
    )


def extract_review(raw: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return run_shell(
        f"source {shlex.quote(str(REVIEW_HELPER))}; "
        'extract_structured_review_output_file "$1" "$2"',
        raw,
        output,
    )


def join_pending(
    ledger: Path, pending: Path, details: Path, output: Path
) -> subprocess.CompletedProcess[str]:
    return run_shell(
        f"source {shlex.quote(str(DETAILS_HELPER))}; "
        'write_pending_finding_details "$1" "$2" "$3" "$4"',
        ledger,
        pending,
        details,
        output,
    )


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


@pytest.mark.parametrize(
    "findings",
    [
        (("major", "One focused finding."),),
        (
            ("blocker", "A blocker."),
            ("major", "A major finding."),
            ("minor", "A minor finding."),
        ),
        (),
    ],
)
def test_valid_review_details_publish_exact_tsv(
    tmp_path: Path, findings: tuple[tuple[str, str], ...]
) -> None:
    review = tmp_path / "review.txt"
    artifact = tmp_path / "review-details.tsv"
    review.write_text(review_text(findings), encoding="utf-8")

    completed = publish_details(review, artifact)

    assert completed.returncode == 0, completed.stderr
    assert artifact.read_text(encoding="utf-8").startswith(DETAILS_HEADER)
    rows = read_tsv(artifact)
    assert [(row["severity"], row["finding"]) for row in rows] == list(findings)
    assert all(row["constraints"] == "none" for row in rows)


def test_existing_placeholder_aliases_are_not_current_findings(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    artifact = tmp_path / "review-details.tsv"
    review.write_text(
        review_text(
            (
                ("blocker", "  NONE  "),
                ("major", "No Issues"),
                ("minor", "  n/a"),
                ("minor", "nothing"),
            ),
            accept="yes",
            details=["- none"],
        ),
        encoding="utf-8",
    )

    assert validate(review).returncode == 0
    assert publish_details(review, artifact).returncode == 0
    assert artifact.read_text(encoding="utf-8") == DETAILS_HEADER


def invalid_variants() -> list[tuple[str, tuple[tuple[str, str], ...], list[str] | None]]:
    finding = "Focused finding."
    valid = detail_lines("major", finding)
    return [
        ("details-none-with-finding", (("major", finding),), ["- none"]),
        ("unknown-finding", (("major", finding),), detail_lines("major", "Unknown finding.")),
        (
            "duplicate-detail",
            (("major", finding),),
            valid + detail_lines("major", finding, "duplicate"),
        ),
        ("severity-mismatch", (("major", finding),), detail_lines("minor", finding)),
        ("missing-field", (("major", finding),), [line for line in valid if "evidence:" not in line]),
        (
            "empty-field",
            (("major", finding),),
            ["  impact: " if line.startswith("  impact:") else line for line in valid],
        ),
        (
            "field-order",
            (("major", finding),),
            valid[:2] + [valid[3], valid[2]] + valid[4:],
        ),
        (
            "literal-tab",
            (("major", finding),),
            [line + "\ttab" if line.startswith("  evidence:") else line for line in valid],
        ),
        ("real-detail-without-finding", (), detail_lines("major", finding)),
    ]


@pytest.mark.parametrize(("name", "findings", "details"), invalid_variants())
def test_invalid_review_details_are_rejected_without_overwriting_artifact(
    tmp_path: Path,
    name: str,
    findings: tuple[tuple[str, str], ...],
    details: list[str] | None,
) -> None:
    review = tmp_path / f"{name}.txt"
    artifact = tmp_path / "review-details.tsv"
    artifact.write_bytes(b"existing artifact\n")
    review.write_text(review_text(findings, details=details), encoding="utf-8")

    format_result = validate(review)
    publish_result = publish_details(review, artifact)

    assert format_result.returncode != 0, name
    assert publish_result.returncode != 0, name
    assert artifact.read_bytes() == b"existing artifact\n"


def test_missing_details_section_is_rejected(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    text = review_text().replace("details:\n- none\n\n", "")
    review.write_text(text, encoding="utf-8")

    assert validate(review).returncode != 0


@pytest.mark.parametrize("resolution", ["resolved", "invalid"])
def test_verification_only_and_unresolved_current_detail_rules(
    tmp_path: Path, resolution: str
) -> None:
    verified = tmp_path / f"{resolution}.txt"
    unresolved = tmp_path / "unresolved.txt"
    verified.write_text(
        review_text(
            accept="yes",
            verification=(
                f"F0001 | {resolution} | Verified against the snapshot.",
            ),
        ),
        encoding="utf-8",
    )
    unresolved.write_text(
        review_text(
            (("major", "The finding remains."),),
            verification=("F0001 | unresolved | The evidence still applies.",),
        ),
        encoding="utf-8",
    )

    assert validate(verified).returncode == 0
    assert validate(unresolved).returncode == 0


def test_transcript_does_not_fall_back_when_final_review_has_invalid_details(
    tmp_path: Path,
) -> None:
    raw = tmp_path / "review.raw.txt"
    output = tmp_path / "review.txt"
    earlier = review_text()
    final_invalid = review_text(
        (("major", "The final finding."),),
        details=["- none"],
    )
    raw.write_text(
        "OpenAI Codex\ncodex\n" + earlier + "codex\n" + final_invalid,
        encoding="utf-8",
    )
    output.write_bytes(b"existing structured review\n")

    completed = extract_review(raw, output)

    assert completed.returncode != 0
    assert output.read_bytes() == b"existing structured review\n"


def test_transcript_rejects_arbitrary_prose_after_final_review(tmp_path: Path) -> None:
    raw = tmp_path / "review.raw.txt"
    output = tmp_path / "review.txt"
    raw.write_text(
        "OpenAI Codex\ncodex\n" + review_text() + "unexpected trailing prose\n",
        encoding="utf-8",
    )
    output.write_bytes(b"existing structured review\n")

    completed = extract_review(raw, output)

    assert completed.returncode != 0
    assert output.read_bytes() == b"existing structured review\n"


def test_transcript_keeps_supported_token_usage_tail(tmp_path: Path) -> None:
    raw = tmp_path / "review.raw.txt"
    output = tmp_path / "review.txt"
    expected = review_text()
    raw.write_text(
        "OpenAI Codex\ncodex\n" + expected + "tokens used\n133,813\n",
        encoding="utf-8",
    )

    completed = extract_review(raw, output)

    assert completed.returncode == 0, completed.stderr
    assert output.read_text(encoding="utf-8") == expected


def test_details_do_not_change_acceptance_counts_or_ledger_identity(tmp_path: Path) -> None:
    first = tmp_path / "round-1.txt"
    second = tmp_path / "round-2.txt"
    ledger = tmp_path / "findings.tsv"
    finding = "A stable concise finding."
    first.write_text(
        review_text(
            (("minor", finding),),
            accept="yes",
            details=detail_lines("minor", finding, "round one"),
        ),
        encoding="utf-8",
    )
    second.write_text(
        review_text(
            (("minor", finding),),
            accept="yes",
            details=detail_lines("minor", finding, "round two changed details"),
        ),
        encoding="utf-8",
    )
    script = f"""
source {shlex.quote(str(REVIEW_HELPER))}
source {shlex.quote(str(LEDGER_HELPER))}
validate_review_output "$1"
validate_review_output_semantics "$1"
update_finding_ledger "$1" "$3" 1
validate_review_output "$2"
validate_review_output_semantics "$2"
update_finding_ledger "$2" "$3" 2
review_finding_count_numbers "$2"
"""

    completed = run_shell(script, first, second, ledger)

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == "0 0 1"
    rows = read_tsv(ledger)
    assert len(rows) == 1
    assert rows[0]["finding_id"] == "F0001"
    assert rows[0]["text"] == finding
    assert rows[0]["last_seen_round"] == "2"


def write_join_inputs(tmp_path: Path) -> tuple[Path, Path, Path]:
    ledger = tmp_path / "findings.tsv"
    pending = tmp_path / "pending-findings.tsv"
    details = tmp_path / "review-details.tsv"
    ledger.write_text(
        LEDGER_HEADER
        + "F0001\tmajor\t1\t2\tpresent\tunresolved\tFirst finding.\n"
        + "F0002\tminor\t2\t2\tpresent\tunresolved\tSecond finding.\n",
        encoding="utf-8",
    )
    pending.write_text(
        PENDING_HEADER
        + "F0002\tminor\tSecond finding.\n"
        + "F0001\tmajor\tFirst finding.\n",
        encoding="utf-8",
    )
    details.write_text(
        DETAILS_HEADER
        + "major\tFirst finding.\tfirst evidence\tfirst impact\tfirst outcome\tnone\tfirst validation\n"
        + "minor\tSecond finding.\tsecond evidence\tsecond impact\tsecond outcome\tnone\tsecond validation\n",
        encoding="utf-8",
    )
    return ledger, pending, details


def test_pending_details_join_uses_stable_ids_and_pending_order(tmp_path: Path) -> None:
    ledger, pending, details = write_join_inputs(tmp_path)
    output = tmp_path / "pending-finding-details.tsv"

    completed = join_pending(ledger, pending, details, output)

    assert completed.returncode == 0, completed.stderr
    assert output.read_text(encoding="utf-8").startswith(PENDING_DETAILS_HEADER)
    rows = read_tsv(output)
    assert [row["finding_id"] for row in rows] == ["F0002", "F0001"]
    assert rows[0]["text"] == "Second finding."
    assert rows[1]["evidence"] == "first evidence"


@pytest.mark.parametrize("case", ["missing", "duplicate", "unknown", "unknown-id"])
def test_pending_details_join_rejects_invalid_mapping_atomically(
    tmp_path: Path, case: str
) -> None:
    ledger, pending, details = write_join_inputs(tmp_path)
    if case == "missing":
        details.write_text(
            DETAILS_HEADER
            + "major\tFirst finding.\tfirst evidence\tfirst impact\tfirst outcome\tnone\tfirst validation\n",
            encoding="utf-8",
        )
    elif case == "duplicate":
        pending.write_text(
            pending.read_text(encoding="utf-8")
            + "F0001\tmajor\tFirst finding.\n",
            encoding="utf-8",
        )
    elif case == "unknown":
        details.write_text(
            details.read_text(encoding="utf-8")
            + "major\tUnknown finding.\tevidence\timpact\toutcome\tnone\tvalidation\n",
            encoding="utf-8",
        )
    else:
        pending.write_text(
            PENDING_HEADER + "F9999\tmajor\tFirst finding.\n",
            encoding="utf-8",
        )
    output = tmp_path / "pending-finding-details.tsv"
    output.write_bytes(b"existing pending details\n")

    completed = join_pending(ledger, pending, details, output)

    assert completed.returncode != 0
    assert output.read_bytes() == b"existing pending details\n"
