from __future__ import annotations

import subprocess
from pathlib import Path


def test_codex_smoke_harness() -> None:
	repo_root = Path(__file__).resolve().parents[1]
	harness_path = repo_root / 'tools' / 'codex' / 'smoke_harness.sh'

	completed = subprocess.run(  # noqa: S603 - trusted repo-local harness path
		[str(harness_path)],
		cwd=repo_root,
		capture_output=True,
		check=False,
		text=True,
	)

	assert completed.returncode == 0, completed.stderr or completed.stdout
	assert '[smoke] all smoke scenarios passed' in completed.stdout
