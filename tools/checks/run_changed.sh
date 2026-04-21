#!/usr/bin/env bash
set -euo pipefail

readonly WORK_EXCLUDE_PATHSPEC=':(exclude).work'

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required check command: $1"
  fi
}

record_smoke_args() {
  local args_file="${SMOKE_RUN_CHANGED_ARGS_FILE:-}"

  if [[ -n "$args_file" ]]; then
    printf '%s\n' "$*" > "$args_file"
  fi
}

run_smoke_checks() {
  local base_ref="$1"
  local count_file="${SMOKE_CHECKS_COUNT_FILE:?}"
  local count=0

  record_smoke_args "$base_ref"

  if [[ -f "$count_file" ]]; then
    count="$(< "$count_file")"
  fi

  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"

  if [[ "$count" -eq 1 ]]; then
    printf 'simulated check failure\n' >&2
    exit 1
  fi

  printf 'simulated checks pass on round %s\n' "$count"
}

collect_changed_files() {
  local base_ref="$1"

  {
    git diff --name-only "$base_ref" -- . "$WORK_EXCLUDE_PATHSPEC"
    git diff --name-only --cached -- . "$WORK_EXCLUDE_PATHSPEC"
    git diff --name-only -- . "$WORK_EXCLUDE_PATHSPEC"
    git ls-files --others --exclude-standard
  } | awk 'NF' | LC_ALL=C sort -u
}

run_shellcheck_if_needed() {
  local -a shell_targets=("$@")

  if [[ "${#shell_targets[@]}" -eq 0 ]]; then
    printf 'shellcheck: skipped (no shell targets changed)\n'
    return
  fi

  require_command shellcheck
  printf 'shellcheck: %s target(s)\n' "${#shell_targets[@]}"
  shellcheck -x "${shell_targets[@]}"
}

run_smoke_harness_if_needed() {
  local should_run="$1"

  if [[ "$should_run" -ne 1 ]]; then
    printf 'smoke_harness: skipped (change set does not affect flow contract)\n'
    return
  fi

  printf 'smoke_harness: ./tools/codex/smoke_harness.sh\n'
  ./tools/codex/smoke_harness.sh
}

main() {
  local base_ref
  local path
  local run_smoke_harness=0
  local -a changed_files=()
  local -a shell_targets=()

  if [[ "$#" -ne 1 ]]; then
    fail "Usage: $0 <base_ref>"
  fi

  base_ref="$1"

  if [[ -n "${SMOKE_CHECKS_COUNT_FILE:-}" ]]; then
    run_smoke_checks "$base_ref"
    return 0
  fi

  if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    fail "Missing base ref for checks: $base_ref"
  fi

  mapfile -t changed_files < <(collect_changed_files "$base_ref")

  if [[ "${#changed_files[@]}" -eq 0 ]]; then
    printf 'No changes detected relative to %s\n' "$base_ref"
    return 0
  fi

  printf 'Changed files relative to %s:\n' "$base_ref"
  printf ' - %s\n' "${changed_files[@]}"

  for path in "${changed_files[@]}"; do
    case "$path" in
      *.sh)
        shell_targets+=("$path")
        ;;
    esac

    case "$path" in
      AGENTS.md|README.md|docs/*|tests/*|tools/checks/*|tools/codex/*|tools/issue/*|.issue_forge/*)
        run_smoke_harness=1
        ;;
    esac
  done

  run_shellcheck_if_needed "${shell_targets[@]}"
  run_smoke_harness_if_needed "$run_smoke_harness"
}

main "$@"
