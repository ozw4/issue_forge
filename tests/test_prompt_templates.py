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
  "$checks_log" review.diff review.untracked.txt review.summary.txt \
  findings.tsv fix-resolution.tsv \
  issue-active-finding.tsv issue-active-finding-details.tsv issue-fix-from-review.snapshot.state \
  "$issue_manifest"

CODEX_FLOW_LIGHT_ISSUE_REVIEW=1
write_issue_flow_prompt_files \
  17 issue.md \
  "$output_dir/light-implementation.prompt.md" \
  "$output_dir/light-fix-from-checks.prompt.md" \
  "$output_dir/review-light.prompt.md" \
  "$output_dir/light-fix-from-review.prompt.md" \
  "$checks_log" review.diff review.untracked.txt review.summary.txt \
  light-findings.tsv light-fix-resolution.tsv \
  light-active-finding.tsv light-active-finding-details.tsv light-fix-from-review.snapshot.state \
  "$issue_manifest"

write_batch_review_prompt_file \
  issues.txt batch.diff batch.untracked.txt batch.summary.txt \
  "$output_dir/batch-review.prompt.md" findings.tsv fix-resolution.tsv \
  "$batch_manifest"

write_fix_from_batch_review_prompt_file \
  issues.txt "$output_dir/fix-from-batch-review.prompt.md" \
  batch-active-finding.tsv batch-fix-from-review.snapshot.state \
  batch-active-finding-details.tsv
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
	issue_fixer_prompt = (output_dir / "fix-from-review.prompt.md").read_text(encoding="utf-8")
	light_fixer_prompt = (output_dir / "light-fix-from-review.prompt.md").read_text(encoding="utf-8")
	batch_fixer_prompt = (output_dir / "fix-from-batch-review.prompt.md").read_text(encoding="utf-8")

	assert str(issue_manifest) in issue_prompt
	assert str(issue_manifest) in light_prompt
	assert str(batch_manifest) in batch_prompt
	for prompt in (issue_prompt, light_prompt, batch_prompt):
		assert "{{" not in prompt
		assert "RAW_CHECK_LOG_SENTINEL" not in prompt
		assert "Treat the checks manifest as the source of truth" in prompt
		assert "Use the last relevant manifest row as the current check result" in prompt
		assert "read `argv.tsv` in the same attempt directory" in prompt
		assert "its exact argv completed successfully" not in prompt

	for prompt in (issue_prompt, light_prompt, batch_prompt):
		assert "details:" in prompt
		assert "required_outcome:" in prompt
		assert "Add exactly one `details` record for every current concise finding" in prompt
		assert "without prescribing a function-specific patch" in prompt
		assert "does not exist or is header-only" in prompt

	assert "issue-active-finding.tsv" in issue_fixer_prompt
	assert "issue-active-finding-details.tsv" in issue_fixer_prompt
	assert "issue-fix-from-review.snapshot.state" in issue_fixer_prompt
	assert "light-active-finding.tsv" in light_fixer_prompt
	assert "light-active-finding-details.tsv" in light_fixer_prompt
	assert "light-fix-from-review.snapshot.state" in light_fixer_prompt
	assert "batch-active-finding.tsv" in batch_fixer_prompt
	assert "batch-active-finding-details.tsv" in batch_fixer_prompt
	assert "batch-fix-from-review.snapshot.state" in batch_fixer_prompt
	for prompt in (issue_fixer_prompt, light_fixer_prompt, batch_fixer_prompt):
		assert "Exactly one ledger-assigned finding ID is active" in prompt
		assert "Address only the one ID" in prompt
		assert "Do not intentionally address any other pending finding" in prompt
		assert "is supplemental context" in prompt
		assert "Do not execute details blindly as concrete patch instructions" in prompt
		assert "Never execute the `validation` text as a shell command" in prompt
		assert "Do not start multi-agent or parallel work" in prompt
		assert "run only the smallest test or check directly relevant" in prompt
		assert "The orchestrator runs full" in prompt
		assert "Return exactly one resolution line for the active ID" in prompt
		assert "Replace `F0001` in the schema example with the exact ID" in prompt
		assert "resolution:\n- F0001 | fixed | One-line explanation." in prompt
		assert "{{" not in prompt
