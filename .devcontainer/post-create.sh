#!/usr/bin/env bash
set -euo pipefail

python -m pip install --upgrade pip

if [[ -f pyproject.toml ]]; then
  if grep -Fq '[project.optional-dependencies]' pyproject.toml && grep -Fq 'dev =' pyproject.toml; then
    python -m pip install -e ".[dev]"
  else
    python -m pip install -e .
  fi
else
  python -m pip install pytest
fi
