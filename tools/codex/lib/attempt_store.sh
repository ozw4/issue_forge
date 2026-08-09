#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_ATTEMPT_STORE_LOADED:-}" ]]; then
  return 0
fi

ATTEMPT_STORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/attempt_store"
# shellcheck source=tools/codex/lib/attempt_store/core.sh
source "${ATTEMPT_STORE_LIB_DIR}/core.sh"
# shellcheck source=tools/codex/lib/attempt_store/publication.sh
source "${ATTEMPT_STORE_LIB_DIR}/publication.sh"
# shellcheck source=tools/codex/lib/attempt_store/run.sh
source "${ATTEMPT_STORE_LIB_DIR}/run.sh"
# shellcheck source=tools/codex/lib/attempt_store/publication_recovery.sh
source "${ATTEMPT_STORE_LIB_DIR}/publication_recovery.sh"
# shellcheck source=tools/codex/lib/attempt_store/publication_guard.sh
source "${ATTEMPT_STORE_LIB_DIR}/publication_guard.sh"
unset ATTEMPT_STORE_LIB_DIR

readonly ISSUE_FORGE_ATTEMPT_STORE_LOADED=1
