from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PACKAGE_ROOT / "tools" / "codex" / "summarize_queue_run.sh"

FINDING_HEADER = (
    "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"
)
FIX_HEADER = "finding_id\taction\tnote\n"
CHECK_HEADER = (
    "check_id\tscope\tscope_id\toperation\tround\tattempt_id\tkind"
    "\trequirement_id\tbase_commit\tsnapshot_head\tsnapshot_tree\tstatus"
    "\texit_status\tsignal\tstarted_at\tfinished_at\tduration_ms\tlog_path"
    "\tlog_sha256\n"
)
SHA = "a" * 40
LOG_SHA = "b" * 64


def write_state(path: Path, rows: list[tuple[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(f"{key}\t{value}\n" for key, value in rows), encoding="utf-8"
    )


def write_tsv(path: Path, header: str, rows: list[tuple[str, ...]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        header + "".join("\t".join(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def add_attempt(
    run_dir: Path,
    *,
    batch: str,
    actor: str,
    operation: str,
    status: str,
    tokens: int,
) -> None:
    attempt = run_dir / "batches" / batch / "attempts" / actor / operation / "attempt-0001"
    write_state(
        attempt / "request.state",
        [
            ("schema_version", "1"),
            ("attempt_id", "attempt-0001"),
            ("operation", operation),
            ("round", "1"),
            ("mode", "write"),
            ("started_at", "2026-08-24T00:00:00Z"),
        ],
    )
    write_state(
        attempt / "result.state",
        [
            ("status", status),
            ("exit_status", "0" if status == "completed" else "1"),
            ("finished_at", "2026-08-24T00:01:00Z"),
        ],
    )
    (attempt / "agent.log").write_text(
        f"output\ntokens used\n{tokens:,}\n", encoding="utf-8"
    )


def build_run(tmp_path: Path) -> Path:
    run_dir = tmp_path / ".work" / "queue" / "runs" / "run-a"
    batch_id = "batch-40-41"
    batch_dir = run_dir / "batches" / batch_id

    write_state(
        run_dir / "manifest.state",
        [
            ("schema_version", "3"),
            ("run_id", "run-a"),
            ("created_at", "2026-08-24T00:00:00Z"),
            ("issues", "40,41"),
        ],
    )
    write_state(
        run_dir / "run.state",
        [
            ("schema_version", "3"),
            ("run_id", "run-a"),
            ("state", "completed"),
        ],
    )
    write_state(batch_dir / "batch.state", [("batch_id", batch_id)])

    write_tsv(
        batch_dir / "findings.tsv",
        FINDING_HEADER,
        [
            (
                "F0001",
                "blocker",
                "1",
                "1",
                "not_observed",
                "resolved",
                "Guard missing.",
            ),
            (
                "F0002",
                "minor",
                "1",
                "2",
                "present",
                "unresolved",
                "Note incomplete.",
            ),
        ],
    )
    write_tsv(
        batch_dir / "history" / "fix-resolution.round-01.tsv",
        FIX_HEADER,
        [
            ("F0001", "fixed", "Guard restored."),
            ("F0002", "cannot_fix", "Needs guidance."),
        ],
    )

    issue_codex = (
        run_dir
        / "archives"
        / batch_id
        / "issues"
        / "40"
        / ("c" * 40)
        / "codex"
    )
    write_tsv(
        issue_codex / "findings.tsv",
        FINDING_HEADER,
        [
            (
                "F0001",
                "major",
                "1",
                "1",
                "not_observed",
                "resolved",
                "Validation skipped.",
            )
        ],
    )
    write_tsv(
        issue_codex / "history" / "fix-resolution.round-01.tsv",
        FIX_HEADER,
        [("F0001", "fixed", "Validation added.")],
    )

    add_attempt(
        run_dir,
        batch=batch_id,
        actor="issue-40",
        operation="review",
        status="completed",
        tokens=1_200,
    )
    add_attempt(
        run_dir,
        batch=batch_id,
        actor="batch",
        operation="batch-fix-from-review",
        status="failed",
        tokens=800,
    )

    write_tsv(
        batch_dir / "checks" / "batch.manifest.tsv",
        CHECK_HEADER,
        [
            (
                "id-1",
                "batch",
                batch_id,
                "batch-checks",
                "1",
                "attempt-0001",
                "consumer-hook",
                "consumer-check-hook",
                SHA,
                SHA,
                SHA,
                "failed",
                "1",
                "none",
                "2026-08-24T00:10:00Z",
                "2026-08-24T00:10:02Z",
                "2000",
                "log",
                LOG_SHA,
            ),
            (
                "id-2",
                "batch",
                batch_id,
                "batch-checks",
                "2",
                "attempt-0002",
                "consumer-hook",
                "consumer-check-hook",
                SHA,
                SHA,
                SHA,
                "passed",
                "0",
                "none",
                "2026-08-24T00:11:00Z",
                "2026-08-24T00:11:03Z",
                "3000",
                "log",
                LOG_SHA,
            ),
        ],
    )
    return run_dir


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        digest.update(str(path.relative_to(root)).encode())
        if path.is_file() and not path.is_symlink():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def run_summary(run_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(SCRIPT), *args, str(run_dir)],
        cwd=PACKAGE_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def parse_output(output: str) -> tuple[list[str], list[str]]:
    lines = output.splitlines()
    return lines[0].split("\t"), lines[1].split("\t")


def test_summarizes_one_run_as_one_tsv_row_without_modifying_artifacts(
    tmp_path: Path,
) -> None:
    run_dir = build_run(tmp_path)
    before = tree_digest(run_dir)

    completed = run_summary(run_dir)

    assert completed.returncode == 0, completed.stderr
    assert tree_digest(run_dir) == before
    header, values = parse_output(completed.stdout)
    row = dict(zip(header, values, strict=True))
    assert row == {
        "run_id": "run-a",
        "state": "completed",
        "created_at": "2026-08-24T00:00:00Z",
        "issues": "40,41",
        "batches": "1",
        "findings": "3",
        "blocker": "1",
        "major": "1",
        "minor": "1",
        "resolved": "2",
        "invalid": "0",
        "unresolved": "1",
        "fixer_claims": "3",
        "fixed_claims": "2",
        "false_positive_claims": "0",
        "cannot_fix_claims": "1",
        "latest_fixed": "2",
        "latest_fixed_resolved": "2",
        "latest_fixed_resolved_rate": "100.0%",
        "review_attempts": "1",
        "fixer_attempts": "1",
        "agent_attempts": "2",
        "agent_failures": "1",
        "tokens": "2000",
        "full_checks": "2",
        "check_failures": "1",
        "check_duration_ms": "5000",
    }


def test_no_header_is_append_friendly(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)

    completed = run_summary(run_dir, "--no-header")

    assert completed.returncode == 0, completed.stderr
    assert len(completed.stdout.splitlines()) == 1
    assert completed.stdout.startswith("run-a\tcompleted\t")


def test_uses_unarchived_current_claim_when_history_is_missing(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)
    batch_dir = run_dir / "batches" / "batch-40-41"
    (batch_dir / "history" / "fix-resolution.round-01.tsv").unlink()
    write_tsv(
        batch_dir / "fix-resolution.tsv",
        FIX_HEADER,
        [("F0002", "false_positive", "Already satisfied.")],
    )

    completed = run_summary(run_dir)

    assert completed.returncode == 0, completed.stderr
    header, values = parse_output(completed.stdout)
    row = dict(zip(header, values, strict=True))
    assert row["fixer_claims"] == "2"
    assert row["fixed_claims"] == "1"
    assert row["false_positive_claims"] == "1"
    assert row["cannot_fix_claims"] == "0"


def test_rejects_malformed_finding_header(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)
    (run_dir / "batches" / "batch-40-41" / "findings.tsv").write_text(
        "wrong\theader\n", encoding="utf-8"
    )

    completed = run_summary(run_dir)

    assert completed.returncode != 0
    assert "Finding ledger header is invalid" in completed.stderr


def test_rejects_malformed_current_fix_resolution_header(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)
    report = run_dir / "batches" / "batch-40-41" / "fix-resolution.tsv"
    report.write_text("wrong\theader\n", encoding="utf-8")

    completed = run_summary(run_dir)

    assert completed.returncode != 0
    assert "Fix resolution report header is invalid" in completed.stderr


def test_rejects_malformed_check_row(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)
    manifest = (
        run_dir / "batches" / "batch-40-41" / "checks" / "batch.manifest.tsv"
    )
    manifest.write_text(
        CHECK_HEADER + "too\tfew\tcolumns\n",
        encoding="utf-8",
    )

    completed = run_summary(run_dir)

    assert completed.returncode != 0
    assert "Check manifest rows are invalid" in completed.stderr


def test_missing_result_counts_as_agent_failure(tmp_path: Path) -> None:
    run_dir = build_run(tmp_path)
    result = next(run_dir.glob("batches/*/attempts/issue-40/*/*/result.state"))
    result.unlink()

    completed = run_summary(run_dir)

    assert completed.returncode == 0, completed.stderr
    header, values = parse_output(completed.stdout)
    row = dict(zip(header, values, strict=True))
    assert row["agent_attempts"] == "2"
    assert row["agent_failures"] == "2"
