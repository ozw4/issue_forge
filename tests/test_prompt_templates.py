from __future__ import annotations

import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_review_prompts_receive_checks_manifest_paths_without_log_expansion(
	tmp_path: Path,
) -> None:
	output_dir = tmp_path / "rendered"
	output_dir.mkdir()
	checks_log = tmp_path / "checks.log"
	checks_log.write_text("RAW_CHECK_LOG_SENTINEL\n", encoding="utf-8")
	issue_manifest = tmp_path / "missing-issue.manifest.tsv"
	batch_manifest = tmp_path / "missing-batch.manifest.tsv"

	script = r"""
set -euo pipefail
CODEX_FLOW_PROMPTS_DIR="$1"
source "$2"
output_dir="$3"
checks_log="$4"
issue_manifest="$5"
batch_manifest="$6"

CODEX_FLOW_LIGHT_ISSUE_REVIEW=0
write_issue_flow_prompt_files \
  17 issue.md \
  "$output_dir/implementation.prompt.md" \
  "$output_dir/fix-from-checks.prompt.md" \
  "$output_dir/review.prompt.md" \
  "$output_dir/fix-from-review.prompt.md" \
  "$checks_log" review.diff review.untracked.txt review.summary.txt review.txt \
  pending-findings.tsv findings.tsv fix-resolution.tsv review.snapshot.state \
  "$issue_manifest"

CODEX_FLOW_LIGHT_ISSUE_REVIEW=1
write_issue_flow_prompt_files \
  17 issue.md \
  "$output_dir/light-implementation.prompt.md" \
  "$output_dir/light-fix-from-checks.prompt.md" \
  "$output_dir/review-light.prompt.md" \
  "$output_dir/light-fix-from-review.prompt.md" \
  "$checks_log" review.diff review.untracked.txt review.summary.txt review.txt \
  pending-findings.tsv findings.tsv fix-resolution.tsv review.snapshot.state \
  "$issue_manifest"

write_batch_review_prompt_file \
  issues.txt batch.diff batch.untracked.txt batch.summary.txt \
  "$output_dir/batch-review.prompt.md" findings.tsv fix-resolution.tsv \
  "$batch_manifest"
"""
	completed = subprocess.run(  # noqa: S603 - exercises trusted repo-local shell renderer
		[
			"bash",
			"-c",
			script,
			"prompt-render-test",
			str(REPO_ROOT / "tools/codex/prompts"),
			str(REPO_ROOT / "tools/codex/lib/prompt_templates.sh"),
			str(output_dir),
			str(checks_log),
			str(issue_manifest),
			str(batch_manifest),
		],
		cwd=REPO_ROOT,
		capture_output=True,
		check=False,
		text=True,
	)
	assert completed.returncode == 0, completed.stderr or completed.stdout
	assert not issue_manifest.exists()
	assert not batch_manifest.exists()

	issue_prompt = (output_dir / "review.prompt.md").read_text(encoding="utf-8")
	light_prompt = (output_dir / "review-light.prompt.md").read_text(encoding="utf-8")
	batch_prompt = (output_dir / "batch-review.prompt.md").read_text(encoding="utf-8")

	assert str(issue_manifest) in issue_prompt
	assert str(issue_manifest) in light_prompt
	assert str(batch_manifest) in batch_prompt
	for prompt in (issue_prompt, light_prompt, batch_prompt):
		assert "{{" not in prompt
		assert "RAW_CHECK_LOG_SENTINEL" not in prompt
		assert "Treat the checks manifest as the source of truth" in prompt
