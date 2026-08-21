from __future__ import annotations

import csv
import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "finding_scheduler.sh"
PENDING_HEADER = "finding_id\tseverity\ttext\n"
PENDING_DETAILS_HEADER = (
    "finding_id\tseverity\ttext\tevidence\timpact\trequired_outcome\tconstraints"
    "\tvalidation\n"
)
FIX_RESOLUTION_HEADER = "finding_id\taction\tnote\n"
ACTIVE_HEADER = PENDING_HEADER
ACTIVE_DETAILS_HEADER = PENDING_DETAILS_HEADER

FindingRow = tuple[str, str, str]
DetailRow = tuple[str, str, str, str, str, str, str, str]
ResolutionRow = tuple[str, str, str]


def run_helper(
    command: str,
    *args: Path | str,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(HELPER))}
{command} "$@"
"""
    return subprocess.run(  # noqa: S603 - invokes a trusted repo-local helper
        ["bash", "-c", script, "finding-scheduler-test", *(str(arg) for arg in args)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        env=env,
        text=True,
    )


def assert_ok(completed: subprocess.CompletedProcess[str]) -> None:
    assert completed.returncode == 0, completed.stderr


def write_tsv(path: Path, header: str, rows: list[tuple[str, ...]]) -> None:
    path.write_text(
        header + "".join("\t".join(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def detail_row(finding: FindingRow, marker: str | None = None) -> DetailRow:
    finding_id, severity, text = finding
    suffix = marker or finding_id
    return (
        finding_id,
        severity,
        text,
        f"evidence {suffix}",
        f"impact {suffix}",
        f"required outcome {suffix}",
        f"constraints {suffix}",
        f"validation {suffix}",
    )


def prepare_inputs(
    tmp_path: Path,
    findings: list[FindingRow],
    *,
    details: list[DetailRow] | None = None,
    resolutions: list[ResolutionRow] | None = None,
) -> tuple[Path, Path, Path, Path, Path]:
    pending = tmp_path / "pending-findings.tsv"
    pending_details = tmp_path / "pending-finding-details.tsv"
    fix_resolution = tmp_path / "fix-resolution.tsv"
    active = tmp_path / "active-finding.tsv"
    active_details = tmp_path / "active-finding-details.tsv"
    write_tsv(pending, PENDING_HEADER, findings)
    write_tsv(
        pending_details,
        PENDING_DETAILS_HEADER,
        details if details is not None else [detail_row(row) for row in findings],
    )
    write_tsv(fix_resolution, FIX_RESOLUTION_HEADER, resolutions or [])
    return pending, pending_details, fix_resolution, active, active_details


def select_next(paths: tuple[Path, Path, Path, Path, Path]) -> subprocess.CompletedProcess[str]:
    return run_helper("write_next_active_finding", *paths)


def test_selects_blocker_before_major_before_minor(tmp_path: Path) -> None:
    findings = [
        ("F0001", "minor", "minor first in pending"),
        ("F0002", "major", "major second in pending"),
        ("F0003", "blocker", "blocker last in pending"),
    ]
    paths = prepare_inputs(tmp_path, findings)

    assert_ok(select_next(paths))
    assert read_tsv(paths[3])[0]["finding_id"] == "F0003"

    write_tsv(paths[2], FIX_RESOLUTION_HEADER, [("F0003", "fixed", "blocker done")])
    assert_ok(select_next(paths))
    assert read_tsv(paths[3])[0]["finding_id"] == "F0002"

    write_tsv(
        paths[2],
        FIX_RESOLUTION_HEADER,
        [
            ("F0003", "fixed", "blocker done"),
            ("F0002", "fixed", "major done"),
        ],
    )
    assert_ok(select_next(paths))
    assert read_tsv(paths[3])[0]["finding_id"] == "F0001"


def test_preserves_pending_order_within_one_severity(tmp_path: Path) -> None:
    findings = [
        ("F0009", "major", "first major"),
        ("F0001", "major", "second major"),
        ("F0002", "minor", "minor"),
    ]
    paths = prepare_inputs(tmp_path, findings)

    assert_ok(select_next(paths))
    assert read_tsv(paths[3])[0]["finding_id"] == "F0009"

    write_tsv(paths[2], FIX_RESOLUTION_HEADER, [("F0009", "fixed", "first done")])
    assert_ok(select_next(paths))
    assert read_tsv(paths[3])[0]["finding_id"] == "F0001"


def test_processed_ids_are_skipped(tmp_path: Path) -> None:
    findings = [
        ("F0001", "blocker", "processed blocker"),
        ("F0002", "blocker", "next blocker"),
        ("F0003", "major", "major"),
    ]
    paths = prepare_inputs(
        tmp_path,
        findings,
        resolutions=[("F0001", "cannot_fix", "attempted first")],
    )

    assert_ok(select_next(paths))

    assert read_tsv(paths[3])[0]["finding_id"] == "F0002"


def test_all_processed_writes_header_only_active_artifacts(tmp_path: Path) -> None:
    findings = [
        ("F0001", "blocker", "blocker"),
        ("F0002", "minor", "minor"),
    ]
    paths = prepare_inputs(
        tmp_path,
        findings,
        resolutions=[
            ("F0001", "fixed", "fixed blocker"),
            ("F0002", "false_positive", "invalid minor"),
        ],
    )

    assert_ok(select_next(paths))

    assert paths[3].read_text(encoding="utf-8") == ACTIVE_HEADER
    assert paths[4].read_text(encoding="utf-8") == ACTIVE_DETAILS_HEADER
    completed = run_helper("active_finding_id", paths[3], paths[4])
    assert completed.returncode != 0
    assert completed.stdout == ""


def test_active_concise_and_details_rows_are_an_exact_mapping(tmp_path: Path) -> None:
    findings = [
        ("F0001", "minor", "minor finding"),
        ("F0002", "blocker", "selected blocker"),
        ("F0003", "major", "major finding"),
    ]
    selected_details = detail_row(findings[1], "selected marker")
    paths = prepare_inputs(
        tmp_path,
        findings,
        details=[detail_row(findings[2]), selected_details, detail_row(findings[0])],
    )

    assert_ok(select_next(paths))

    assert paths[3].read_text(encoding="utf-8") == (
        ACTIVE_HEADER + "F0002\tblocker\tselected blocker\n"
    )
    assert paths[4].read_text(encoding="utf-8") == (
        ACTIVE_DETAILS_HEADER + "\t".join(selected_details) + "\n"
    )


def invalid_mapping_cases() -> list[
    tuple[str, list[FindingRow], list[DetailRow], list[ResolutionRow]]
]:
    first = ("F0001", "major", "first finding")
    second = ("F0002", "minor", "second finding")
    return [
        ("missing-detail", [first, second], [detail_row(first)], []),
        (
            "duplicate-pending-id",
            [first, ("F0001", "minor", "duplicate id")],
            [detail_row(first)],
            [],
        ),
        (
            "unknown-detail",
            [first],
            [detail_row(first), detail_row(("F9999", "minor", "unknown"))],
            [],
        ),
        (
            "duplicate-detail",
            [first],
            [detail_row(first), detail_row(first, "duplicate")],
            [],
        ),
        (
            "severity-mismatch",
            [first],
            [detail_row(("F0001", "minor", "first finding"))],
            [],
        ),
        (
            "text-mismatch",
            [first],
            [detail_row(("F0001", "major", "different text"))],
            [],
        ),
        (
            "unknown-resolution-id",
            [first],
            [detail_row(first)],
            [("F9999", "fixed", "unknown finding")],
        ),
        (
            "duplicate-resolution-id",
            [first],
            [detail_row(first)],
            [
                ("F0001", "fixed", "first claim"),
                ("F0001", "fixed", "duplicate claim"),
            ],
        ),
    ]


@pytest.mark.parametrize(
    ("name", "findings", "details", "resolutions"), invalid_mapping_cases()
)
def test_invalid_mapping_preserves_both_existing_active_artifacts(
    tmp_path: Path,
    name: str,
    findings: list[FindingRow],
    details: list[DetailRow],
    resolutions: list[ResolutionRow],
) -> None:
    case_dir = tmp_path / name
    case_dir.mkdir()
    paths = prepare_inputs(
        case_dir,
        findings,
        details=details,
        resolutions=resolutions,
    )
    active_before = b"existing active artifact\n"
    details_before = b"existing active details artifact\n"
    paths[3].write_bytes(active_before)
    paths[4].write_bytes(details_before)

    completed = select_next(paths)

    assert completed.returncode != 0
    assert paths[3].read_bytes() == active_before
    assert paths[4].read_bytes() == details_before


@pytest.mark.parametrize("input_index", [0, 1, 2])
def test_invalid_input_header_preserves_active_outputs(
    tmp_path: Path, input_index: int
) -> None:
    finding = ("F0001", "major", "finding")
    paths = prepare_inputs(tmp_path, [finding])
    paths[input_index].write_text("wrong\theader\n", encoding="utf-8")
    paths[3].write_bytes(b"active before\n")
    paths[4].write_bytes(b"details before\n")

    completed = select_next(paths)

    assert completed.returncode != 0
    assert paths[3].read_bytes() == b"active before\n"
    assert paths[4].read_bytes() == b"details before\n"


def test_active_destinations_must_be_distinct(tmp_path: Path) -> None:
    paths = prepare_inputs(tmp_path, [("F0001", "major", "finding")])
    shared_output = paths[3]
    shared_output.write_bytes(b"existing active output\n")

    completed = run_helper(
        "write_next_active_finding",
        paths[0],
        paths[1],
        paths[2],
        shared_output,
        shared_output,
    )

    assert completed.returncode != 0
    assert shared_output.read_bytes() == b"existing active output\n"


def test_normalized_active_destinations_must_be_distinct(tmp_path: Path) -> None:
    paths = prepare_inputs(tmp_path, [("F0001", "major", "finding")])
    active = str(paths[3])
    aliased_details = f"{tmp_path}/./{paths[3].name}"

    completed = run_helper(
        "write_next_active_finding",
        paths[0],
        paths[1],
        paths[2],
        active,
        aliased_details,
    )

    assert completed.returncode != 0
    assert not paths[3].exists()


def test_active_destination_must_not_alias_an_input(tmp_path: Path) -> None:
    paths = prepare_inputs(tmp_path, [("F0001", "major", "finding")])
    pending_before = paths[0].read_bytes()

    completed = run_helper(
        "write_next_active_finding",
        paths[0],
        paths[1],
        paths[2],
        paths[0],
        paths[4],
    )

    assert completed.returncode != 0
    assert paths[0].read_bytes() == pending_before
    assert not paths[4].exists()


def test_initialize_fix_resolution_report_atomically_replaces_regular_file(
    tmp_path: Path,
) -> None:
    output = tmp_path / "fix-resolution.tsv"
    output.write_text("old contents\n", encoding="utf-8")

    assert_ok(run_helper("initialize_fix_resolution_report", output))

    assert output.read_text(encoding="utf-8") == FIX_RESOLUTION_HEADER


def test_initialize_fix_resolution_report_rejects_symlink_without_changing_target(
    tmp_path: Path,
) -> None:
    target = tmp_path / "target.tsv"
    target.write_bytes(b"target before\n")
    output = tmp_path / "fix-resolution.tsv"
    output.symlink_to(target)

    completed = run_helper("initialize_fix_resolution_report", output)

    assert completed.returncode != 0
    assert output.is_symlink()
    assert target.read_bytes() == b"target before\n"


def test_initialize_fix_resolution_report_rejects_directory(tmp_path: Path) -> None:
    output = tmp_path / "fix-resolution.tsv"
    output.mkdir()

    completed = run_helper("initialize_fix_resolution_report", output)

    assert completed.returncode != 0
    assert output.is_dir()


def test_cumulative_resolution_append_preserves_processing_order(tmp_path: Path) -> None:
    cumulative = tmp_path / "fix-resolution.tsv"
    first = tmp_path / "first.tsv"
    second = tmp_path / "second.tsv"
    assert_ok(run_helper("initialize_fix_resolution_report", cumulative))
    write_tsv(first, FIX_RESOLUTION_HEADER, [("F0002", "cannot_fix", "first active")])
    write_tsv(second, FIX_RESOLUTION_HEADER, [("F0001", "fixed", "second active")])

    assert_ok(run_helper("append_fix_resolution_report", cumulative, first))
    assert_ok(run_helper("append_fix_resolution_report", cumulative, second))

    assert cumulative.read_text(encoding="utf-8") == (
        FIX_RESOLUTION_HEADER
        + "F0002\tcannot_fix\tfirst active\n"
        + "F0001\tfixed\tsecond active\n"
    )


@pytest.mark.parametrize(
    "incoming_rows",
    [
        [],
        [
            ("F0002", "fixed", "one"),
            ("F0003", "false_positive", "two"),
        ],
        [("F0001", "fixed", "duplicate")],
    ],
    ids=["zero-rows", "multiple-rows", "duplicate-id"],
)
def test_invalid_incoming_resolution_does_not_modify_either_report(
    tmp_path: Path, incoming_rows: list[ResolutionRow]
) -> None:
    cumulative = tmp_path / "fix-resolution.tsv"
    incoming = tmp_path / "incoming.tsv"
    write_tsv(
        cumulative,
        FIX_RESOLUTION_HEADER,
        [("F0001", "fixed", "existing claim")],
    )
    write_tsv(incoming, FIX_RESOLUTION_HEADER, incoming_rows)
    cumulative_before = cumulative.read_bytes()
    incoming_before = incoming.read_bytes()

    completed = run_helper("append_fix_resolution_report", cumulative, incoming)

    assert completed.returncode != 0
    assert cumulative.read_bytes() == cumulative_before
    assert incoming.read_bytes() == incoming_before


@pytest.mark.parametrize("invalid_index", [0, 1])
def test_append_requires_valid_headers_without_modifying_reports(
    tmp_path: Path, invalid_index: int
) -> None:
    cumulative = tmp_path / "fix-resolution.tsv"
    incoming = tmp_path / "incoming.tsv"
    write_tsv(cumulative, FIX_RESOLUTION_HEADER, [])
    write_tsv(incoming, FIX_RESOLUTION_HEADER, [("F0001", "fixed", "claim")])
    reports = [cumulative, incoming]
    reports[invalid_index].write_text("wrong\theader\n", encoding="utf-8")
    before = [report.read_bytes() for report in reports]

    completed = run_helper("append_fix_resolution_report", cumulative, incoming)

    assert completed.returncode != 0
    assert [report.read_bytes() for report in reports] == before


def test_active_finding_id_prints_the_only_valid_id(tmp_path: Path) -> None:
    active = tmp_path / "active-finding.tsv"
    active_details = tmp_path / "active-finding-details.tsv"
    write_tsv(active, ACTIVE_HEADER, [("F0123", "major", "one active finding")])
    write_tsv(
        active_details,
        ACTIVE_DETAILS_HEADER,
        [detail_row(("F0123", "major", "one active finding"))],
    )

    completed = run_helper("active_finding_id", active, active_details)

    assert_ok(completed)
    assert completed.stdout == "F0123\n"


@pytest.mark.parametrize(
    "contents",
    [
        "wrong\theader\nF0001\tmajor\tfinding\n",
        ACTIVE_HEADER
        + "F0001\tmajor\tfirst\n"
        + "F0002\tminor\tsecond\n",
        ACTIVE_HEADER + "not-an-id\tmajor\tfinding\n",
    ],
    ids=["invalid-header", "multiple-rows", "invalid-row"],
)
def test_active_finding_id_rejects_invalid_artifacts(
    tmp_path: Path, contents: str
) -> None:
    active = tmp_path / "active-finding.tsv"
    active_details = tmp_path / "active-finding-details.tsv"
    active.write_text(contents, encoding="utf-8")
    write_tsv(
        active_details,
        ACTIVE_DETAILS_HEADER,
        [detail_row(("F0001", "major", "finding"))],
    )

    completed = run_helper("active_finding_id", active, active_details)

    assert completed.returncode != 0
    assert completed.stdout == ""


@pytest.mark.parametrize(
    "details_finding",
    [
        ("F0002", "major", "finding"),
        ("F0001", "minor", "finding"),
        ("F0001", "major", "different finding"),
    ],
    ids=["id", "severity", "text"],
)
def test_active_finding_id_rejects_inconsistent_pair(
    tmp_path: Path, details_finding: FindingRow
) -> None:
    active = tmp_path / "active-finding.tsv"
    active_details = tmp_path / "active-finding-details.tsv"
    write_tsv(active, ACTIVE_HEADER, [("F0001", "major", "finding")])
    write_tsv(
        active_details,
        ACTIVE_DETAILS_HEADER,
        [detail_row(details_finding)],
    )

    completed = run_helper("active_finding_id", active, active_details)

    assert completed.returncode != 0
    assert completed.stdout == ""
    assert "Active finding artifacts are inconsistent" in completed.stderr


def test_interrupted_active_publication_is_rejected_as_inconsistent(
    tmp_path: Path,
) -> None:
    paths = prepare_inputs(tmp_path, [("F0002", "blocker", "new finding")])
    old_finding = ("F0001", "major", "old finding")
    write_tsv(paths[3], ACTIVE_HEADER, [old_finding])
    write_tsv(paths[4], ACTIVE_DETAILS_HEADER, [detail_row(old_finding)])

    wrapper_dir = tmp_path / "bin"
    wrapper_dir.mkdir()
    counter = tmp_path / "mv-count"
    real_mv = shutil.which("mv")
    assert real_mv is not None
    mv_wrapper = wrapper_dir / "mv"
    mv_wrapper.write_text(
        "#!/usr/bin/env bash\n"
        f"counter={shlex.quote(str(counter))}\n"
        "count=0\n"
        "[[ ! -f \"$counter\" ]] || count=$(<\"$counter\")\n"
        "count=$((count + 1))\n"
        "printf '%s\\n' \"$count\" > \"$counter\"\n"
        "[[ \"$count\" -ne 2 ]] || exit 86\n"
        f"exec {shlex.quote(real_mv)} \"$@\"\n",
        encoding="utf-8",
    )
    mv_wrapper.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{wrapper_dir}{os.pathsep}{env['PATH']}"

    completed = run_helper("write_next_active_finding", *paths, env=env)

    assert completed.returncode != 0
    assert "Failed to publish active finding commit marker" in completed.stderr
    assert read_tsv(paths[3])[0]["finding_id"] == "F0001"
    assert read_tsv(paths[4])[0]["finding_id"] == "F0002"
    rejected = run_helper("active_finding_id", paths[3], paths[4])
    assert rejected.returncode != 0
    assert "Active finding artifacts are inconsistent" in rejected.stderr
