from __future__ import annotations

import csv
import shlex
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "tools" / "codex" / "lib" / "finding_ledger.sh"
HEADER = "finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext\n"


def write_review(
    path: Path,
    *,
    blocker: tuple[str, ...] = ("none",),
    major: tuple[str, ...] = ("none",),
    minor: tuple[str, ...] = ("none",),
) -> None:
    lines = ["accept: no", "", "blocker:"]
    lines.extend(f"- {text}" for text in blocker)
    lines.extend(["", "major:"])
    lines.extend(f"- {text}" for text in major)
    lines.extend(["", "minor:"])
    lines.extend(f"- {text}" for text in minor)
    lines.extend(["", "verification:", "- none"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def update(review: Path, ledger: Path, round_number: int) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
source {shlex.quote(str(HELPER))}
update_finding_ledger "$1" "$2" "$3"
"""
    return subprocess.run(  # noqa: S603 - invokes trusted repo-local shell helper
        ["bash", "-c", script, "finding-ledger-test", str(review), str(ledger), str(round_number)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def read_ledger(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def assert_update(review: Path, ledger: Path, round_number: int) -> None:
    completed = update(review, ledger, round_number)
    assert completed.returncode == 0, completed.stderr


def test_initial_ledger_creation(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, blocker=("blocker A",), major=("major B",), minor=("minor C",))

    assert_update(review, ledger, 1)

    assert read_ledger(ledger) == [
        {"finding_id": "F0001", "severity": "blocker", "first_round": "1", "last_seen_round": "1", "status": "present", "resolution": "unresolved", "text": "blocker A"},
        {"finding_id": "F0002", "severity": "major", "first_round": "1", "last_seen_round": "1", "status": "present", "resolution": "unresolved", "text": "major B"},
        {"finding_id": "F0003", "severity": "minor", "first_round": "1", "last_seen_round": "1", "status": "present", "resolution": "unresolved", "text": "minor C"},
    ]


def test_same_finding_keeps_id_and_first_round(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A",))
    assert_update(review, ledger, 1)
    write_review(review, major=("finding A",))

    assert_update(review, ledger, 2)

    assert read_ledger(ledger) == [
        {"finding_id": "F0001", "severity": "major", "first_round": "1", "last_seen_round": "2", "status": "present", "resolution": "unresolved", "text": "finding A"}
    ]


def test_severity_change_keeps_id(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A",))
    assert_update(review, ledger, 1)
    write_review(review, blocker=("finding A",))

    assert_update(review, ledger, 2)

    assert read_ledger(ledger)[0] == {
        "finding_id": "F0001", "severity": "blocker", "first_round": "1", "last_seen_round": "2", "status": "present", "resolution": "unresolved", "text": "finding A"
    }


def test_disappeared_finding_is_not_observed_and_not_deleted(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A",))
    assert_update(review, ledger, 1)
    write_review(review)

    assert_update(review, ledger, 2)

    assert read_ledger(ledger)[0] == {
        "finding_id": "F0001", "severity": "major", "first_round": "1", "last_seen_round": "1", "status": "not_observed", "resolution": "unresolved", "text": "finding A"
    }


def test_new_finding_uses_next_id_after_existing_maximum(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    ledger.write_text(
        HEADER
        + "F0001\tminor\t1\t1\tpresent\tunresolved\told A\n"
        + "F0004\tmajor\t1\t1\tpresent\tunresolved\told B\n",
        encoding="utf-8",
    )
    write_review(review, minor=("new C",))

    assert_update(review, ledger, 2)

    rows = read_ledger(ledger)
    assert [row["finding_id"] for row in rows] == ["F0001", "F0004", "F0005"]
    assert rows[-1]["text"] == "new C"


def test_changed_wording_creates_new_id(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("Undefined variable is used.",))
    assert_update(review, ledger, 1)
    write_review(review, major=("The variable may be undefined.",))

    assert_update(review, ledger, 2)

    rows = read_ledger(ledger)
    assert [(row["finding_id"], row["status"], row["text"]) for row in rows] == [
        ("F0001", "not_observed", "Undefined variable is used."),
        ("F0002", "present", "The variable may be undefined."),
    ]


def test_none_is_not_a_finding_and_marks_existing_not_observed(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, blocker=("finding A",))
    assert_update(review, ledger, 1)
    write_review(review)

    assert_update(review, ledger, 2)

    rows = read_ledger(ledger)
    assert len(rows) == 1
    assert rows[0]["status"] == "not_observed"


def test_same_round_duplicate_uses_highest_severity(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, major=("finding A",), minor=("finding A",))

    assert_update(review, ledger, 1)

    rows = read_ledger(ledger)
    assert len(rows) == 1
    assert rows[0]["severity"] == "major"


def test_malformed_header_fails_without_overwriting_ledger(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, blocker=("finding A",))
    original = b"wrong\theader\nexisting data\n"
    ledger.write_bytes(original)

    completed = update(review, ledger, 2)

    assert completed.returncode != 0
    assert "Finding ledger header is invalid" in completed.stderr
    assert ledger.read_bytes() == original


def test_literal_tab_is_normalized_to_one_space(tmp_path: Path) -> None:
    review = tmp_path / "review.txt"
    ledger = tmp_path / "findings.tsv"
    write_review(review, minor=("path\tmessage",))

    assert_update(review, ledger, 1)

    rows = read_ledger(ledger)
    assert len(rows) == 1
    assert rows[0]["text"] == "path message"
    assert len(ledger.read_text(encoding="utf-8").splitlines()[1].split("\t")) == 7
