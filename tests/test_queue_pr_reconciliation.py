from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "queue_publish_binding.sh"
HEAD = "a" * 40
OTHER_HEAD = "b" * 40


def invoke(tmp_path: Path, *, mode: str, existing_state: str | None = None) -> subprocess.CompletedProcess[str]:
    run_dir = tmp_path / "run"
    batch_dir = run_dir / "batches" / "batch-1-1"
    bin_dir = tmp_path / "bin"
    batch_dir.mkdir(parents=True)
    bin_dir.mkdir()

    (run_dir / "manifest.state").write_text("run_id\trun-a\nbase_branch\tmain\n", encoding="utf-8")
    (batch_dir / "batch.state").write_text(
        f"run_id\trun-a\nbatch_id\tbatch-1-1\nbranch\tbatch/1-1\nstate\tpublishing\naccepted_head\t{HEAD}\n",
        encoding="utf-8",
    )
    publish = batch_dir / "publish.state"
    if existing_state is not None:
        publish.write_text(
            "run_id\trun-a\nbatch_id\tbatch-1-1\npr_number\t17\n"
            "pr_url\thttps://example.test/pull/17\nhead_branch\tbatch/1-1\n"
            f"base_branch\tmain\nhead_sha\t{HEAD}\nstate\t{existing_state}\n",
            encoding="utf-8",
        )

    gh = bin_dir / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"$1\" == pr && \"$2\" == view ]]; then\n"
        "  case \"$GH_MODE\" in\n"
        f"    open) printf 'OPEN\\t\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"    merged) printf 'MERGED\\t2026-08-08T00:00:00Z\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"    closed) printf 'CLOSED\\t\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"    wrong) printf 'OPEN\\t\\tbatch/1-1\\tmain\\t{OTHER_HEAD}\\n' ;;\n"
        "    none) exit 0 ;;\n"
        "  esac\n"
        "  exit 0\n"
        "fi\n"
        "case \"$GH_MODE\" in\n"
        "  none) exit 0 ;;\n"
        f"  open) printf '17\\thttps://example.test/pull/17\\tOPEN\\tnone\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"  merged) printf '17\\thttps://example.test/pull/17\\tMERGED\\t2026-08-08T00:00:00Z\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"  historical) printf '16\\thttps://example.test/pull/16\\tMERGED\\t2026-08-07T00:00:00Z\\tbatch/1-1\\tmain\\t{OTHER_HEAD}\\n' ;;\n"
        f"  closed) printf '17\\thttps://example.test/pull/17\\tCLOSED\\tnone\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        f"  wrong) printf '17\\thttps://example.test/pull/17\\tOPEN\\tnone\\tbatch/1-1\\tmain\\t{OTHER_HEAD}\\n' ;;\n"
        f"  ambiguous) printf '17\\thttps://example.test/pull/17\\tOPEN\\tnone\\tbatch/1-1\\tmain\\t{HEAD}\\n18\\thttps://example.test/pull/18\\tOPEN\\tnone\\tbatch/1-1\\tmain\\t{HEAD}\\n' ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    gh.chmod(0o755)

    script = f"""
set -euo pipefail
export PATH={shlex.quote(str(bin_dir))}:$PATH
export GH_MODE={shlex.quote(mode)}
readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
CODEX_FLOW_BASE_BRANCH=main
run_state_dir={shlex.quote(str(run_dir))}
run_id=run-a
queue_state_parse_file() {{
  local file="$1" output_name="$3" key value
  local -n output="$output_name"
  output=()
  while IFS=$'\\t' read -r key value; do output["$key"]="$value"; done < "$file"
}}
queue_state_validate_file() {{ [[ -f "$1" && ! -L "$1" ]]; }}
queue_state_read_field() {{ awk -F '\\t' -v requested="$3" '$1 == requested {{ print $2; exit }}' "$1"; }}
queue_state_record_publish() {{
  printf 'run_id\\t%s\\nbatch_id\\t%s\\npr_number\\t%s\\npr_url\\t%s\\nhead_branch\\t%s\\nbase_branch\\t%s\\nhead_sha\\t%s\\nstate\\t%s\\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "$1"
}}
source {shlex.quote(str(HELPER))}
state=unknown number=unknown url=unknown
queue_reconcile_batch_pr_state \
  {shlex.quote(str(publish))} \
  {shlex.quote(str(batch_dir / 'batch.state'))} \
  run-a batch-1-1 batch/1-1 {HEAD} state number url
printf '%s\\t%s\\t%s\\n' "$state" "$number" "$url"
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )


def test_missing_publish_state_discovers_open_pr(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="open")
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("open\t17\t")


def test_missing_publish_state_discovers_merged_pr(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="merged")
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("merged\t17\t")


def test_recorded_open_pr_is_promoted_to_merged(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="merged", existing_state="open")
    assert result.returncode == 0, result.stderr
    publish = tmp_path / "run" / "batches" / "batch-1-1" / "publish.state"
    assert "state\tmerged" in publish.read_text(encoding="utf-8")


def test_historical_merged_wrong_head_is_ignored(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="historical")
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("none\t\t")


def test_closed_unmerged_pr_is_rejected(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="closed")
    assert result.returncode != 0
    assert "closed without merging" in result.stderr


def test_wrong_head_pr_is_rejected(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="wrong")
    assert result.returncode != 0
    assert "does not match accepted head" in result.stderr


def test_ambiguous_prs_are_rejected(tmp_path: Path) -> None:
    result = invoke(tmp_path, mode="ambiguous")
    assert result.returncode != 0
    assert "ambiguous PR lookup" in result.stderr
