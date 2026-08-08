#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

"${SCRIPT_DIR}/smoke_attempt_store.sh"
"${SCRIPT_DIR}/smoke_harness_core.sh" "$@"
