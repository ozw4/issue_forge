from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "token_usage_helpers.sh"


def test_token_usage_log_path_survives_archive_move(tmp_path: Path) -> None:
    source = tmp_path / "codex"
    log = source / "attempts" / "review.round-0001.attempt-test" / "output.log"
    usage = source / "token-usage.tsv"
    log.parent.mkdir(parents=True)
    log.write_text("tokens used\n1,234\n", encoding="utf-8")

    script = f"""
set -euo pipefail
source {shlex.quote(str(HELPER))}
append_codex_token_usage \
  {shlex.quote(str(usage))} \
  $'phase\\tissue\\tround\\treasoning\\ttokens\\tlog' \
  review 42 1 high {shlex.quote(str(log))}
"""
    result = subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )

    assert result.returncode == 0, result.stderr
    row = usage.read_text(encoding="utf-8").splitlines()[1].split("\t")
    assert row[4] == "1234"
    assert row[5] == "./attempts/review.round-0001.attempt-test/output.log"

    archive = tmp_path / "archive"
    shutil.copytree(source, archive)
    shutil.rmtree(source)

    archived_row = (archive / "token-usage.tsv").read_text(encoding="utf-8").splitlines()[1].split("\t")
    archived_log = archive / archived_row[5]
    assert archived_log.read_text(encoding="utf-8") == "tokens used\n1,234\n"
