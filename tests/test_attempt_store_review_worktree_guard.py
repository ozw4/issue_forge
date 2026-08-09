from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


ATTEMPT_STORE = Path(__file__).resolve().parents[1] / "tools" / "codex" / "lib" / "attempt_store.sh"


def run_bash(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail\nsource {shlex.quote(str(ATTEMPT_STORE))}\n{body}"],
        cwd=tmp_path,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
    )


def init_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "test"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=path, check=True)
    (path / "code.txt").write_text("base\n", encoding="utf-8")
    subprocess.run(["git", "add", "code.txt"], cwd=path, check=True)
    subprocess.run(["git", "commit", "-qm", "base"], cwd=path, check=True)


def test_review_retries_after_repository_change(tmp_path: Path) -> None:
    init_repo(tmp_path)
    (tmp_path / "code.txt").write_text("implementation\n", encoding="utf-8")
    work = tmp_path / ".work"
    work.mkdir()
    reviewer = work / "reviewer.sh"
    reviewer.write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        "n=0; [[ ! -f $1 ]] || n=$(cat $1); n=$((n + 1)); printf '%s\\n' $n > $1\n"
        "[[ $n != 1 ]] || printf 'reviewer change\\n' >> code.txt\n"
        "printf 'valid review\\n'\n",
        encoding="utf-8",
    )
    reviewer.chmod(0o755)

    result = run_bash(
        tmp_path,
        f"""
CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(':(exclude).work')
CODEX_FLOW_REVIEW_RETRY_LIMIT=3
CODEX_FLOW_ATTEMPT_SCOPE=issue
CODEX_FLOW_ATTEMPT_SCOPE_ID=test
extract_structured_review_output_file() {{ grep -Fxq 'valid review' "$1"; printf 'parsed review\\n' > "$2"; }}
archive_round_file() {{ :; }}
status_outside_work() {{ git status --porcelain --untracked-files=all -- . "${{CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}}"; }}
generate_review_material() {{ git diff --binary > .work/review.diff; : > .work/review.untracked; : > .work/review.summary; }}
generate_batch_review_material() {{ git diff --binary > "$2"; : > "$3"; : > "$4"; }}
write_batch_review_prompt_file() {{ printf 'review\\n' > "$5"; }}
reviewer={shlex.quote(str(reviewer))}
run_case() {{
  local phase=$1 root=.work/$1 counter=.work/$1.count before_status attempt='' log=''
  local base_commit batch_diff=$root/batch.diff batch_untracked=$root/batch.untracked batch_summary=$root/batch.summary
  local batch_review_prompt=$root/prompt issues_file=$root/issues history_dir=$root/history
  local review_diff=.work/review.diff review_untracked=.work/review.untracked review_summary=.work/review.summary
  mkdir -p "$root" "$history_dir"; printf 'review\\n' > "$root/prompt"; printf issue > "$issues_file"
  base_commit=$(git rev-parse HEAD)
  if [[ $phase == review ]]; then generate_review_material; else generate_batch_review_material "$base_commit" "$batch_diff" "$batch_untracked" "$batch_summary"; fi
  before_status=$(status_outside_work)
  run_logged_attempt attempt log "$root/attempts" "$phase" 1 read high "$root/prompt" "$root/$phase.raw.txt" combined -- "$reviewer" "$counter"
  [[ $before_status == "$(status_outside_work)" ]]
  [[ $(cat "$counter") == 2 ]]
  [[ $(find "$root/attempts" -maxdepth 1 -type d -name "$phase.*" | wc -l) == 2 ]]
  grep -R -l $'status\\tinvalid' "$root/attempts"/$phase.*/result.state >/dev/null
  grep -Fxq 'valid review' "$root/$phase.raw.txt"
  grep -Fxq 'parsed review' "$root/$phase.txt"
}}
run_case review
run_case batch-review
before=$(review_repository_fingerprint)
printf 'another change\\n' >> code.txt
after=$(review_repository_fingerprint)
[[ $before != $after ]]
[[ $(git status --porcelain -- code.txt) == ' M code.txt' ]]
""",
    )

    assert result.returncode == 0, result.stderr
    assert result.stderr.count("rerunning review (1/3)") == 2
