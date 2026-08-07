from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "queue_publish_binding.sh"
HEAD = "a" * 40
OTHER_HEAD = "b" * 40


def write_state(path: Path, **fields: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{key}\t{value}\n" for key, value in fields.items()), encoding="utf-8")


def make_fixture(tmp_path: Path) -> tuple[Path, Path, Path, Path, Path]:
    run_dir = tmp_path / "run"
    batch_dir = run_dir / "batches" / "batch-1-1"
    manifest = run_dir / "manifest.state"
    batch = batch_dir / "batch.state"
    publish = batch_dir / "publish.state"
    gh_log = tmp_path / "gh.log"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n"
        "printf 'OPEN\\t\\tbatch/1-1\\tmain\\t%s\\n' \"$EXPECTED_HEAD\"\n",
        encoding="utf-8",
    )
    gh.chmod(0o755)
    write_state(manifest, run_id="run-a", base_branch="main")
    write_state(
        batch,
        run_id="run-a",
        batch_id="batch-1-1",
        branch="batch/1-1",
        state="publishing",
        accepted_head=HEAD,
    )
    write_state(
        publish,
        run_id="run-a",
        batch_id="batch-1-1",
        head_branch="batch/1-1",
        base_branch="main",
        head_sha=HEAD,
    )
    return run_dir, manifest, batch, publish, gh_log


def invoke(
    tmp_path: Path,
    *,
    mutate: str = ":",
    command: str = 'queue_state_validate_file "$batch_state_file" batch; gh pr view 17 >/dev/null',
) -> subprocess.CompletedProcess[str]:
    run_dir, _manifest, batch, publish, gh_log = make_fixture(tmp_path)
    script = f"""\
set -euo pipefail
export PATH={shlex.quote(str(tmp_path / 'bin'))}:$PATH
export GH_LOG={shlex.quote(str(gh_log))}
export EXPECTED_HEAD={HEAD}
readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
run_state_dir={shlex.quote(str(run_dir))}
run_id=run-a
current_batch_id=batch-1-1
batch_id=batch-1-1
batch_branch=batch/1-1
batch_state_file={shlex.quote(str(batch))}
publish_state_file={shlex.quote(str(publish))}
batch_head_commit={HEAD}
queue_state_parse_file() {{
  local file="$1" output_name="$3" key value
  local -n output="$output_name"
  output=()
  while IFS=$'\\t' read -r key value; do output["$key"]="$value"; done < "$file"
}}
queue_state_validate_file() {{ [[ -f "$1" && ! -L "$1" ]]; }}
source {shlex.quote(str(HELPER))}
{mutate}
{command}
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


def invocation_count(path: Path) -> int:
    if not path.exists():
        return 0
    return len(path.read_text(encoding="utf-8").splitlines())


def test_valid_publish_state_is_bound_and_gh_runs_once(tmp_path: Path) -> None:
    result = invoke(tmp_path)
    assert result.returncode == 0, result.stderr
    assert invocation_count(tmp_path / "gh.log") == 1


def test_cross_run_publish_state_is_rejected_before_gh(tmp_path: Path) -> None:
    result = invoke(tmp_path, mutate="sed -i 's/^run_id.*/run_id\\trun-b/' \"$publish_state_file\"")
    assert result.returncode != 0
    assert "publish run run-b does not match current run run-a" in result.stderr
    assert invocation_count(tmp_path / "gh.log") == 0


def test_publish_head_must_equal_accepted_head_before_gh(tmp_path: Path) -> None:
    result = invoke(
        tmp_path,
        mutate=f"sed -i 's/^head_sha.*/head_sha\\t{OTHER_HEAD}/' \"$publish_state_file\"",
    )
    assert result.returncode != 0
    assert f"publish head {OTHER_HEAD} does not match accepted head {HEAD}" in result.stderr
    assert invocation_count(tmp_path / "gh.log") == 0


def test_batch_graph_validation_rejects_cross_batch_publish_state(tmp_path: Path) -> None:
    result = invoke(tmp_path, mutate="sed -i 's/^batch_id.*/batch_id\\tbatch-9-9/' \"$publish_state_file\"")
    assert result.returncode != 0
    assert "publish batch batch-9-9 does not match current batch batch-1-1" in result.stderr
    assert invocation_count(tmp_path / "gh.log") == 0


def test_pr_creation_view_bypasses_binding_until_publish_state_exists(tmp_path: Path) -> None:
    result = invoke(
        tmp_path,
        mutate='rm "$publish_state_file"',
        command="gh pr view https://example.test/pull/17 --json number >/dev/null",
    )
    assert result.returncode == 0, result.stderr
    assert invocation_count(tmp_path / "gh.log") == 1
