#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
readonly REPO_ROOT="${CODEX_FLOW_REPO_ROOT}"
# shellcheck source=tools/codex/lib/codex_profiles.sh
source "${SCRIPT_DIR}/lib/codex_profiles.sh"

readonly DEFAULT_TRANSIENT_MAX_RETRIES=5
readonly DEFAULT_TRANSIENT_INITIAL_DELAY_SEC=5
readonly MAX_TRANSIENT_DELAY_SEC=60

if [[ "$#" -ne 2 ]]; then
  printf 'Usage: %s <write|read> <prompt_file>\n' "$0" >&2
  exit 1
fi

mode="$1"
prompt_file="$2"
profile_name="$(resolve_codex_profile_for_mode "$mode")"

if [[ ! -f "$prompt_file" ]]; then
  printf 'Prompt file not found: %s\n' "$prompt_file" >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  printf 'Missing required command: codex\n' >&2
  exit 1
fi

if ! command -v mktemp >/dev/null 2>&1; then
  printf 'Missing required command: mktemp\n' >&2
  exit 1
fi

parse_non_negative_integer() {
  local value="$1"
  local name="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer: %s\n' "$name" "$value" >&2
    exit 1
  fi
}

is_retryable_codex_failure() {
  local output_file="$1"

  grep -Eqi \
    'Selected model is at capacity\. Please try a different model\.|(model|provider)[^[:cntrl:]]{0,120}at capacity|(model|provider)[^[:cntrl:]]{0,120}temporar(y|ily) unavailable|temporar(y|ily) unavailable[^[:cntrl:]]{0,120}(model|provider)|temporary availability' \
    "$output_file"
}

run_codex_attempt() {
  local output_file="$1"
  local sandbox_mode="$2"
  local reasoning_effort="$3"

  codex exec \
    --sandbox "$sandbox_mode" \
    --config model_reasoning_effort="$reasoning_effort" \
    < "$prompt_file" \
    > "$output_file" 2>&1
}

run_codex_with_retries() {
  local sandbox_mode="$1"
  local reasoning_effort="$2"
  local max_retries="${CODEX_TRANSIENT_MAX_RETRIES:-$DEFAULT_TRANSIENT_MAX_RETRIES}"
  local delay_sec="${CODEX_TRANSIENT_INITIAL_DELAY_SEC:-$DEFAULT_TRANSIENT_INITIAL_DELAY_SEC}"
  local attempt=1
  local temp_output
  local status

  parse_non_negative_integer "$max_retries" 'CODEX_TRANSIENT_MAX_RETRIES'
  parse_non_negative_integer "$delay_sec" 'CODEX_TRANSIENT_INITIAL_DELAY_SEC'

  temp_output="$(mktemp)"
  trap 'rm -f "$temp_output"' RETURN

  while true; do
    printf '[codex] starting attempt %d\n' "$attempt" >&2

    set +e
    run_codex_attempt "$temp_output" "$sandbox_mode" "$reasoning_effort"
    status=$?
    set -e

    cat "$temp_output"

    if (( status == 0 )); then
      return 0
    fi

    if ! is_retryable_codex_failure "$temp_output"; then
      return "$status"
    fi

    if (( attempt > max_retries )); then
      printf '[codex] transient Codex failure persisted after %d attempts; giving up\n' "$attempt" >&2
      return "$status"
    fi

    printf '[codex] transient Codex failure detected; retrying attempt %d/%d after %d seconds\n' \
      "$((attempt + 1))" "$((max_retries + 1))" "$delay_sec" >&2
    sleep "$delay_sec"
    attempt=$((attempt + 1))
    delay_sec=$((delay_sec * 2))
    if (( delay_sec > MAX_TRANSIENT_DELAY_SEC )); then
      delay_sec=$MAX_TRANSIENT_DELAY_SEC
    fi
  done
}

sandbox_mode="$(resolve_codex_profile_sandbox "$profile_name")"
reasoning_effort="$(resolve_codex_profile_reasoning "$profile_name")"

run_codex_with_retries "$sandbox_mode" "$reasoning_effort"
