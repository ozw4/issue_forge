#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_ATTEMPT_STORE_LOADED:-}" ]]; then
  return 0
fi

readonly CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION='1'

attempt_store_error() {
  printf '[attempt-store] %s\n' "$1" >&2
  return 1
}

attempt_store_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

attempt_store_require_scalar() {
  local label="$1"
  local value="$2"

  if [[ -z "$value" || "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    attempt_store_error "Invalid ${label}"
    return 1
  fi
}

attempt_store_require_phase() {
  local value="$1"

  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    attempt_store_error "Invalid attempt phase: ${value}"
    return 1
  fi
}

attempt_store_require_round() {
  local value="$1"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    attempt_store_error "Invalid attempt round: ${value}"
    return 1
  fi
}

attempt_store_sha256_file() {
  local path="$1"

  sha256sum -- "$path" | awk '{ print $1 }'
}

attempt_store_sha256_argv() {
  printf '%s\0' "$@" | sha256sum | awk '{ print $1 }'
}

attempt_store_atomic_copy() {
  local source_path="$1"
  local target_path="$2"
  local target_dir
  local temporary_path
  local status=1

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  temporary_path="$(mktemp "${target_dir}/.attempt-store.tmp.XXXXXX")" || return 1

  if cp -- "$source_path" "$temporary_path" \
    && chmod --reference="$source_path" "$temporary_path" \
    && mv -T -f -- "$temporary_path" "$target_path"; then
    status=0
  fi

  rm -f -- "$temporary_path" 2>/dev/null || true
  return "$status"
}

attempt_store_atomic_write() {
  local target_path="$1"
  local target_dir
  local temporary_path
  local status=1
  shift

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  temporary_path="$(mktemp "${target_dir}/.attempt-store.tmp.XXXXXX")" || return 1

  if printf '%s\n' "$@" > "$temporary_path" && mv -T -f -- "$temporary_path" "$target_path"; then
    status=0
  fi

  rm -f -- "$temporary_path" 2>/dev/null || true
  return "$status"
}

attempt_store_create() {
  local -n output_ref="$1"
  local attempts_root="$2"
  local phase="$3"
  local round="$4"
  local mode="$5"
  local reasoning="$6"
  local prompt_file="$7"
  local compatibility_output="$8"
  local stderr_policy="$9"
  shift 9

  local created_dir
  local attempt_id
  local input_file
  local prompt_sha='none'
  local prompt_copy='none'
  local command_sha
  local formatted_round

  attempt_store_require_phase "$phase" || return 1
  attempt_store_require_round "$round" || return 1
  attempt_store_require_scalar 'attempt mode' "$mode" || return 1
  attempt_store_require_scalar 'attempt reasoning' "$reasoning" || return 1
  attempt_store_require_scalar 'prompt path' "$prompt_file" || return 1
  attempt_store_require_scalar 'compatibility output path' "$compatibility_output" || return 1
  case "$stderr_policy" in
    combined|stdout) ;;
    *) attempt_store_error "Invalid stderr policy: ${stderr_policy}"; return 1 ;;
  esac
  [[ "$#" -gt 0 ]] || { attempt_store_error 'Attempt command is empty'; return 1; }

  if [[ "$prompt_file" != none ]]; then
    [[ -f "$prompt_file" ]] || { attempt_store_error "Attempt prompt not found: ${prompt_file}"; return 1; }
    prompt_sha="$(attempt_store_sha256_file "$prompt_file")" || return 1
    prompt_copy='prompt.md'
  fi
  command_sha="$(attempt_store_sha256_argv "$@")" || return 1

  if [[ -e "$attempts_root" && ( ! -d "$attempts_root" || -L "$attempts_root" ) ]]; then
    attempt_store_error "Attempt root is not a regular directory: ${attempts_root}"
    return 1
  fi
  mkdir -p "$attempts_root" || return 1
  formatted_round="$(printf '%04d' "$round")"
  created_dir="$(mktemp -d "${attempts_root}/${phase}.round-${formatted_round}.attempt-XXXXXX")" || return 1
  attempt_id="${created_dir##*/}"
  input_file="${created_dir}/input.state"

  if ! attempt_store_atomic_write "$input_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'phase\t'"${phase}" \
    $'round\t'"${round}" \
    $'mode\t'"${mode}" \
    $'reasoning\t'"${reasoning}" \
    $'stderr_policy\t'"${stderr_policy}" \
    $'prompt_path\t'"${prompt_file}" \
    $'prompt_sha256\t'"${prompt_sha}" \
    $'prompt_copy\t'"${prompt_copy}" \
    $'compatibility_output\t'"${compatibility_output}" \
    $'command_argv_sha256\t'"${command_sha}" \
    $'started_at\t'"$(attempt_store_now)"; then
    rm -rf -- "$created_dir"
    return 1
  fi
  if [[ "$prompt_file" != none ]]; then
    attempt_store_atomic_copy "$prompt_file" "${created_dir}/${prompt_copy}" || return 1
    chmod 0444 "${created_dir}/${prompt_copy}" || return 1
  fi
  chmod 0444 "$input_file" || return 1
  output_ref="$created_dir"
}

attempt_store_signal_from_status() {
  local status="$1"

  if [[ "$status" -ge 129 && "$status" -le 192 ]]; then
    printf '%s\n' "$((status - 128))"
  else
    printf 'none\n'
  fi
}

attempt_store_finalize() {
  local attempt_dir="$1"
  local attempts_root="$2"
  local phase="$3"
  local round="$4"
  local compatibility_output="$5"
  local stderr_policy="$6"
  local exit_status="$7"

  local attempt_id="${attempt_dir##*/}"
  local output_log="${attempt_dir}/output.log"
  local stderr_log="${attempt_dir}/stderr.log"
  local result_file="${attempt_dir}/result.state"
  local status_name='failed'
  local output_sha
  local stderr_sha='none'
  local signal_value
  local latest_file="${attempts_root}/latest/${phase}.state"

  [[ -f "$output_log" ]] || : > "$output_log"
  output_sha="$(attempt_store_sha256_file "$output_log")" || return 1
  if [[ "$stderr_policy" == stdout ]]; then
    [[ -f "$stderr_log" ]] || : > "$stderr_log"
    stderr_sha="$(attempt_store_sha256_file "$stderr_log")" || return 1
  fi
  if [[ "$exit_status" -eq 0 ]]; then
    status_name='succeeded'
  fi
  signal_value="$(attempt_store_signal_from_status "$exit_status")"

  if ! attempt_store_atomic_write "$result_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'status\t'"${status_name}" \
    $'exit_status\t'"${exit_status}" \
    $'signal\t'"${signal_value}" \
    $'output_sha256\t'"${output_sha}" \
    $'stderr_sha256\t'"${stderr_sha}" \
    $'finished_at\t'"$(attempt_store_now)"; then
    return 1
  fi

  chmod 0444 "$output_log" "$result_file" || return 1
  if [[ "$stderr_policy" == stdout ]]; then
    chmod 0444 "$stderr_log" || return 1
  fi

  if [[ "$compatibility_output" != none ]]; then
    attempt_store_atomic_copy "$output_log" "$compatibility_output" || return 1
  fi

  attempt_store_atomic_write "$latest_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'phase\t'"${phase}" \
    $'round\t'"${round}" \
    $'status\t'"${status_name}" \
    $'exit_status\t'"${exit_status}" \
    $'attempt_path\t'"${attempt_id}" \
    $'output_path\t'"${attempt_id}/output.log" \
    $'result_path\t'"${attempt_id}/result.state" \
    $'updated_at\t'"$(attempt_store_now)" || return 1
}

attempt_store_publish_derived() {
  local attempt_dir="$1"
  local artifact_name="$2"
  local source_path="$3"
  local target_path

  if [[ ! "$artifact_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    attempt_store_error "Invalid derived artifact name: ${artifact_name}"
    return 1
  fi
  [[ -d "$attempt_dir" && ! -L "$attempt_dir" ]] || {
    attempt_store_error "Attempt directory is unavailable: ${attempt_dir}"
    return 1
  }
  [[ -f "${attempt_dir}/result.state" ]] || {
    attempt_store_error "Attempt is not terminal: ${attempt_dir}"
    return 1
  }
  [[ -f "$source_path" ]] || {
    attempt_store_error "Derived artifact source is unavailable: ${source_path}"
    return 1
  }
  target_path="${attempt_dir}/${artifact_name}"
  [[ ! -e "$target_path" && ! -L "$target_path" ]] || {
    attempt_store_error "Derived artifact already exists: ${target_path}"
    return 1
  }
  attempt_store_atomic_copy "$source_path" "$target_path" || return 1
  chmod 0444 "$target_path"
}

run_logged_attempt() {
  local -n attempt_dir_ref="$1"
  local -n attempt_log_ref="$2"
  local attempts_root="$3"
  local phase="$4"
  local round="$5"
  local mode="$6"
  local reasoning="$7"
  local prompt_file="$8"
  local compatibility_output="$9"
  local stderr_policy="${10}"
  shift 10

  local attempt_path
  local output_log
  local stderr_log
  local command_status
  local publish_status=0

  if [[ "${1:-}" != -- ]]; then
    attempt_store_error 'Attempt command separator is missing'
    return 1
  fi
  shift
  [[ "$#" -gt 0 ]] || { attempt_store_error 'Attempt command is empty'; return 1; }

  attempt_store_create attempt_path "$attempts_root" "$phase" "$round" "$mode" "$reasoning" \
    "$prompt_file" "$compatibility_output" "$stderr_policy" "$@" || return 1
  output_log="${attempt_path}/output.log"
  stderr_log="${attempt_path}/stderr.log"
  attempt_dir_ref="$attempt_path"
  attempt_log_ref="$output_log"

  case "$stderr_policy" in
    combined)
      if "$@" > "$output_log" 2>&1; then command_status=0; else command_status=$?; fi
      ;;
    stdout)
      if "$@" > "$output_log" 2> "$stderr_log"; then command_status=0; else command_status=$?; fi
      cat -- "$stderr_log" >&2 || true
      ;;
  esac

  if ! attempt_store_finalize "$attempt_path" "$attempts_root" "$phase" "$round" \
    "$compatibility_output" "$stderr_policy" "$command_status"; then
    publish_status=1
  fi

  if [[ "$publish_status" -ne 0 ]]; then
    return "$publish_status"
  fi
  return "$command_status"
}

readonly ISSUE_FORGE_ATTEMPT_STORE_LOADED=1
