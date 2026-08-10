#!/usr/bin/env bash

agent_attempt_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

agent_attempt_next_id() {
  local operation_dir="$1"
  local path name number max_number=0

  for path in "${operation_dir}"/attempt-*; do
    [[ -d "$path" ]] || continue
    name="${path##*/}"
    if [[ "$name" =~ ^attempt-([0-9]+)(\.running)?$ ]]; then
      number=$((10#${BASH_REMATCH[1]}))
      if ((number > max_number)); then
        max_number="$number"
      fi
    fi
  done

  printf 'attempt-%04d\n' "$((max_number + 1))"
}

publish_agent_attempt_legacy_log() {
  local source_file="$1"
  local legacy_log_file="$2"
  local legacy_dir temporary_file

  legacy_dir="$(dirname "$legacy_log_file")"
  temporary_file="$(mktemp "${legacy_dir}/.agent-log.tmp.XXXXXX")" || return 1
  if ! cp -- "$source_file" "$temporary_file"; then
    rm -f -- "$temporary_file" || true
    return 1
  fi
  if ! mv -T -f -- "$temporary_file" "$legacy_log_file"; then
    rm -f -- "$temporary_file" || true
    return 1
  fi
}

run_codex_with_attempt() {
  local operation="$1"
  local round="$2"
  local mode="$3"
  local prompt_file="$4"
  local legacy_log_file="$5"
  local legacy_stderr_policy="${6:-combined}"
  local attempts_root="${CODEX_FLOW_AGENT_ATTEMPTS_ROOT:-}"
  local operation_dir attempt_id running_dir terminal_dir result_tmp
  local codex_status terminal_status

  case "$legacy_stderr_policy" in
    combined|stdout) ;;
    *)
      printf 'Invalid Agent attempt legacy stderr policy: %s\n' "$legacy_stderr_policy" >&2
      return 1
      ;;
  esac

  if [[ -z "$attempts_root" ]]; then
    if [[ "$legacy_stderr_policy" == stdout ]]; then
      "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$legacy_log_file"
    else
      "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$legacy_log_file" 2>&1
    fi
    return $?
  fi

  operation_dir="${attempts_root}/${operation}"
  if ! mkdir -p "$operation_dir"; then
    printf 'Failed to create Agent attempt operation directory: %s\n' "$operation_dir" >&2
    return 1
  fi
  attempt_id="$(agent_attempt_next_id "$operation_dir")" || return 1
  running_dir="${operation_dir}/${attempt_id}.running"
  terminal_dir="${operation_dir}/${attempt_id}"
  if ! mkdir "$running_dir"; then
    printf 'Failed to create Agent attempt directory: %s\n' "$running_dir" >&2
    return 1
  fi

  if ! printf '%s\t%s\n' \
    schema_version 1 \
    attempt_id "$attempt_id" \
    operation "$operation" \
    round "$round" \
    mode "$mode" \
    started_at "$(agent_attempt_now)" > "${running_dir}/request.state"; then
    printf 'Failed to write Agent attempt request state: %s\n' "$running_dir" >&2
    return 1
  fi
  if ! cp -- "$prompt_file" "${running_dir}/prompt.md"; then
    printf 'Failed to copy Agent attempt prompt: %s\n' "$running_dir" >&2
    return 1
  fi

  if "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "${running_dir}/prompt.md" \
    > "${running_dir}/agent.log" 2>&1; then
    codex_status=0
  else
    codex_status=$?
  fi

  case "$codex_status" in
    0) terminal_status=completed ;;
    130|143) terminal_status=interrupted ;;
    *) terminal_status=failed ;;
  esac

  result_tmp="$(mktemp "${running_dir}/.result.state.tmp.XXXXXX")" || {
    printf 'Failed to create Agent attempt result state: %s\n' "$running_dir" >&2
    return 1
  }
  if ! printf '%s\t%s\n' \
    status "$terminal_status" \
    exit_status "$codex_status" \
    finished_at "$(agent_attempt_now)" > "$result_tmp"; then
    rm -f -- "$result_tmp" || true
    printf 'Failed to write Agent attempt result state: %s\n' "$running_dir" >&2
    return 1
  fi
  if ! mv -T -- "$result_tmp" "${running_dir}/result.state"; then
    rm -f -- "$result_tmp" || true
    printf 'Failed to publish Agent attempt result state: %s\n' "$running_dir" >&2
    return 1
  fi
  if ! mv -T -- "$running_dir" "$terminal_dir"; then
    printf 'Failed to finalize Agent attempt directory: %s\n' "$running_dir" >&2
    return 1
  fi
  if ! publish_agent_attempt_legacy_log "${terminal_dir}/agent.log" "$legacy_log_file"; then
    printf 'Failed to publish Agent attempt legacy log: %s\n' "$legacy_log_file" >&2
    return 1
  fi

  return "$codex_status"
}
