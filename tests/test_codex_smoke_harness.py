from __future__ import annotations

import subprocess
from pathlib import Path


def run_smoke(repo_root: Path, script_name: str) -> subprocess.CompletedProcess[str]:
	script_path = repo_root / 'tools' / 'codex' / script_name
	return subprocess.run(  # noqa: S603 - trusted repo-local harness path
		[str(script_path)],
		cwd=repo_root,
		capture_output=True,
		check=False,
		text=True,
	)


def test_codex_smoke_harness() -> None:
	repo_root = Path(__file__).resolve().parents[1]

	attempt = run_smoke(repo_root, 'smoke_attempt_store.sh')
	assert attempt.returncode == 0, attempt.stderr or attempt.stdout
	assert '[smoke] attempt store contract passed' in attempt.stdout

	harness = run_smoke(repo_root, 'smoke_harness.sh')
	assert harness.returncode == 0, harness.stderr or harness.stdout
	assert '[smoke] all smoke scenarios passed' in harness.stdout
