from __future__ import annotations

import os
import stat
import subprocess
import zipfile
from pathlib import Path


def script_path() -> Path:
    return Path(__file__).resolve().parents[1] / 'tools' / 'issue' / 'create_from_zip.sh'


def make_zip(zip_path: Path, files: dict[str, str]) -> None:
    with zipfile.ZipFile(zip_path, 'w') as archive:
        for name, body in files.items():
            archive.writestr(name, body)


def test_create_from_zip_dry_run_uses_heading_and_basename(tmp_path: Path) -> None:
    zip_path = tmp_path / 'issues.zip'
    make_zip(
        zip_path,
        {
            '001-first.md': '# First issue\n\nBody\n',
            'nested/no_heading.md': 'Body without a title heading\n',
        },
    )

    completed = subprocess.run(  # noqa: S603 - trusted repo-local script path
        [
            str(script_path()),
            '--dry-run',
            '--repo',
            'owner/repo',
            '--create-label',
            'refactor',
            '#1D76DB',
            'Refactoring task',
            '--label',
            'codex',
            str(zip_path),
        ],
        capture_output=True,
        check=False,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr or completed.stdout
    assert 'Target repo: owner/repo' in completed.stdout
    assert 'Markdown issue files: 2' in completed.stdout
    assert 'DRY-RUN label: create/update refactor on owner/repo (#1D76DB)' in completed.stdout
    assert 'DRY-RUN issue: First issue <- 001-first.md' in completed.stdout
    assert 'DRY-RUN issue: no_heading <- nested/no_heading.md' in completed.stdout


def test_create_from_zip_rejects_path_traversal_entries(tmp_path: Path) -> None:
    zip_path = tmp_path / 'unsafe.zip'
    make_zip(zip_path, {'../evil.md': '# Evil\n'})

    completed = subprocess.run(  # noqa: S603 - trusted repo-local script path
        [str(script_path()), '--dry-run', '--repo', 'owner/repo', str(zip_path)],
        capture_output=True,
        check=False,
        text=True,
    )

    assert completed.returncode != 0
    assert "Unsafe zip entry contains '..': ../evil.md" in completed.stderr


def test_create_from_zip_calls_gh_for_labels_and_issues(tmp_path: Path) -> None:
    zip_path = tmp_path / 'issues.zip'
    gh_log = tmp_path / 'gh.log'
    fake_bin = tmp_path / 'bin'
    fake_bin.mkdir()
    fake_gh = fake_bin / 'gh'
    fake_gh.write_text(
        '#!/usr/bin/env bash\n'
        'printf "%s\\n" "$*" >> "$GH_LOG"\n'
        'if [[ "$1 $2" == "auth status" ]]; then exit 0; fi\n'
        'if [[ "$1 $2" == "label create" ]]; then exit 0; fi\n'
        'if [[ "$1 $2" == "issue create" ]]; then echo "https://github.com/owner/repo/issues/1"; exit 0; fi\n'
        'echo "unexpected gh call: $*" >&2\n'
        'exit 1\n'
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IXUSR)
    make_zip(zip_path, {'001.md': '# Created issue\n\nBody\n'})

    env = os.environ.copy()
    env['PATH'] = f'{fake_bin}:{env["PATH"]}'
    env['GH_LOG'] = str(gh_log)

    completed = subprocess.run(  # noqa: S603 - trusted repo-local script path
        [
            str(script_path()),
            '--repo',
            'owner/repo',
            '--create-label',
            'refactor',
            '1D76DB',
            'Refactoring task',
            '--label',
            'codex',
            str(zip_path),
        ],
        capture_output=True,
        check=False,
        env=env,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr or completed.stdout
    assert 'Creating/updating label: refactor' in completed.stdout
    assert 'Creating issue: Created issue' in completed.stdout

    gh_calls = gh_log.read_text()
    assert 'auth status' in gh_calls
    assert 'label create refactor --repo owner/repo --description Refactoring task --color 1D76DB --force' in gh_calls
    assert 'issue create --repo owner/repo --title Created issue --body-file' in gh_calls
    assert '--label refactor --label codex' in gh_calls
