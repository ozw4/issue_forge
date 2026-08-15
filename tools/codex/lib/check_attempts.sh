#!/usr/bin/env bash

# shellcheck disable=SC2034 # nameref output and last-attempt globals are consumed by callers.

# shellcheck source=tools/codex/lib/agent_attempts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent_attempts.sh"
# shellcheck source=tools/codex/lib/review_snapshots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_snapshots.sh"

readonly CHECK_ATTEMPT_MANIFEST_HEADER=$'check_id\tscope\tscope_id\toperation\tround\tattempt_id\tkind\trequirement_id\tbase_commit\tsnapshot_head\tsnapshot_tree\tstatus\texit_status\tsignal\tstarted_at\tfinished_at\tduration_ms\tlog_path\tlog_sha256'

check_attempt_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

check_attempt_epoch_ms() {
  date -u '+%s%3N'
}

check_attempt_repository_status_sha256() {
  git status --porcelain=v1 -z --untracked-files=all -- . \
    "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" | sha256sum | awk '{print $1}'
}

_check_attempt_valid_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

_check_attempt_valid_timestamp() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

_check_attempt_valid_relative_path() {
  local path="$1"

  [[ -n "$path" && "$path" != /* && "$path" != ./* && "$path" != */ && \
     "$path" != *//* && "$path" != *$'\t'* && "$path" != *$'\r'* && \
     "$path" != *$'\n'* && "$path" != *'/./'* && "$path" != '../'* && \
     "$path" != *'/../'* && "$path" != '..' && "$path" != *'/..' ]]
}

check_attempt_repo_relative_path() {
  local path="$1"
  local repo_root="${CODEX_FLOW_REPO_ROOT:-}"
  local relative

  if [[ -z "$repo_root" ]]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'Cannot resolve repository root for check attempt path: %s\n' "$path" >&2
      return 1
    }
  fi
  repo_root="${repo_root%/}"

  if [[ "$path" == "$repo_root"/* ]]; then
    relative="${path#"$repo_root"/}"
  elif [[ "$path" == /* ]]; then
    printf 'Check attempt path is outside the repository root: %s\n' "$path" >&2
    return 1
  else
    relative="$path"
  fi

  if ! _check_attempt_valid_relative_path "$relative"; then
    printf 'Check attempt path is not a normalized repository-relative path: %s\n' "$relative" >&2
    return 1
  fi
  printf '%s\n' "$relative"
}

_check_attempt_read_exact_state() {
  local state_file="$1"
  local output_name="$2"
  shift 2
  local -n output="$output_name"
  local -a expected_keys=("$@")
  local line key value index=0

  output=()
  [[ -f "$state_file" && ! -L "$state_file" ]] || {
    printf 'Check attempt state is missing or not a regular file: %s\n' "$state_file" >&2
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((index >= ${#expected_keys[@]})) || [[ "$line" != *$'\t'* || "$line" == *$'\r'* ]]; then
      printf 'Check attempt state has invalid structure: %s\n' "$state_file" >&2
      return 1
    fi
    key="${line%%$'\t'*}"
    value="${line#*$'\t'}"
    if [[ "$value" == *$'\t'* || "$key" != "${expected_keys[$index]}" || -z "$value" ]]; then
      printf 'Check attempt state has invalid field %s: %s\n' "${expected_keys[$index]}" "$state_file" >&2
      return 1
    fi
    output["$key"]="$value"
    index=$((index + 1))
  done < "$state_file"
  if ((index != ${#expected_keys[@]})); then
    printf 'Check attempt state has missing fields: %s\n' "$state_file" >&2
    return 1
  fi
}

_check_attempt_validate_request() {
  local request_file="$1"
  local output_name="$2"
  local -n request_ref="$output_name"
  local expected_check_id

  _check_attempt_read_exact_state "$request_file" "$output_name" \
    schema_version check_id scope scope_id operation round attempt_id kind \
    requirement_id base_commit repository_status_sha256 started_at || return 1

  [[ "${request_ref[schema_version]}" == 1 ]] || return 1
  [[ "${request_ref[check_id]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "${request_ref[round]}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${request_ref[attempt_id]}" =~ ^attempt-[0-9]{4,}$ ]] || return 1
  [[ "${request_ref[kind]}" == consumer-hook && "${request_ref[requirement_id]}" == consumer-check-hook ]] || return 1
  _check_attempt_valid_sha "${request_ref[base_commit]}" || return 1
  _check_attempt_valid_sha "${request_ref[repository_status_sha256]}" || return 1
  _check_attempt_valid_timestamp "${request_ref[started_at]}" || return 1
  case "${request_ref[scope]}:${request_ref[operation]}" in
    issue:issue-checks) [[ "${request_ref[scope_id]}" =~ ^[1-9][0-9]*$ ]] ;;
    batch:batch-checks) [[ "${request_ref[scope_id]}" =~ ^batch-[1-9][0-9]*-[1-9][0-9]*$ ]] ;;
    *) return 1 ;;
  esac
  expected_check_id="${request_ref[scope]}-${request_ref[scope_id]}-${request_ref[operation]}-round-${request_ref[round]}"
  [[ "${request_ref[check_id]}" == "$expected_check_id" ]]
}

_check_attempt_validate_snapshot() {
  local snapshot_file="$1"
  local output_name="$2"
  local -n snapshot_ref="$output_name"

  _check_attempt_read_exact_state "$snapshot_file" "$output_name" \
    schema_version head_commit worktree_tree created_at || return 1
  [[ "${snapshot_ref[schema_version]}" == 1 ]] || return 1
  _check_attempt_valid_sha "${snapshot_ref[head_commit]}" || return 1
  _check_attempt_valid_sha "${snapshot_ref[worktree_tree]}" || return 1
  _check_attempt_valid_timestamp "${snapshot_ref[created_at]}" || return 1
}

_check_attempt_validate_result() {
  local result_file="$1"
  local output_name="$2"
  local -n result_ref="$output_name"

  _check_attempt_read_exact_state "$result_file" "$output_name" \
    schema_version status exit_status signal started_at finished_at duration_ms \
    snapshot_match log_sha256 || return 1
  [[ "${result_ref[schema_version]}" == 1 ]] || return 1
  [[ "${result_ref[exit_status]}" =~ ^[0-9]+$ && "${result_ref[exit_status]}" -le 255 ]] || return 1
  [[ "${result_ref[duration_ms]}" =~ ^[0-9]+$ ]] || return 1
  [[ "${result_ref[snapshot_match]}" == yes || "${result_ref[snapshot_match]}" == no ]] || return 1
  [[ "${result_ref[signal]}" == none || "${result_ref[signal]}" == INT || \
     "${result_ref[signal]}" == TERM || "${result_ref[signal]}" == other ]] || return 1
  _check_attempt_valid_timestamp "${result_ref[started_at]}" || return 1
  _check_attempt_valid_timestamp "${result_ref[finished_at]}" || return 1
  _check_attempt_valid_sha "${result_ref[log_sha256]}" || return 1

  case "${result_ref[status]}:${result_ref[exit_status]}:${result_ref[signal]}:${result_ref[snapshot_match]}" in
    passed:0:none:yes|interrupted:130:INT:yes|interrupted:143:TERM:yes) ;;
    invalid:*:*:no)
      case "${result_ref[exit_status]}" in
        130) [[ "${result_ref[signal]}" == INT ]] || return 1 ;;
        143) [[ "${result_ref[signal]}" == TERM ]] || return 1 ;;
        *)
          if [[ "${result_ref[exit_status]}" -ge 128 ]]; then
            [[ "${result_ref[signal]}" == other ]] || return 1
          else
            [[ "${result_ref[signal]}" == none ]] || return 1
          fi
          ;;
      esac
      ;;
    failed:*)
      [[ "${result_ref[exit_status]}" -ne 0 && "${result_ref[exit_status]}" -ne 130 && \
         "${result_ref[exit_status]}" -ne 143 && "${result_ref[snapshot_match]}" == yes ]] || return 1
      if [[ "${result_ref[exit_status]}" -ge 128 ]]; then
        [[ "${result_ref[signal]}" == other ]] || return 1
      else
        [[ "${result_ref[signal]}" == none ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

_check_attempt_validate_argv() {
  local argv_file="$1"
  local expected_base="$2"
  local line index argument count=0

  [[ -f "$argv_file" && ! -L "$argv_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *$'\t'* && "$line" != *$'\r'* ]] || return 1
    index="${line%%$'\t'*}"
    argument="${line#*$'\t'}"
    [[ "$argument" != *$'\t'* && -n "$argument" && "$index" == "$count" ]] || return 1
    if [[ "$count" -eq 1 && "$argument" != "$expected_base" ]]; then return 1; fi
    count=$((count + 1))
  done < "$argv_file"
  [[ "$count" -eq 2 ]]
}

_check_attempt_validate_artifact_hashes() {
  local terminal_dir="$1"
  local hashes_file="${terminal_dir}/artifacts.sha256"
  local line hash artifact actual index=0
  local -a expected=(request.state snapshot.state argv.tsv combined.log result.state)

  [[ -f "$hashes_file" && ! -L "$hashes_file" ]] || return 1
  IFS= read -r line < "$hashes_file" || return 1
  [[ "$line" == $'sha256\tartifact' ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *$'\t'* && "$line" != *$'\r'* ]] || return 1
    hash="${line%%$'\t'*}"
    artifact="${line#*$'\t'}"
    [[ "$artifact" != *$'\t'* && "$index" -lt "${#expected[@]}" && \
       "$artifact" == "${expected[$index]}" ]] || return 1
    _check_attempt_valid_sha "$hash" || return 1
    [[ -f "${terminal_dir}/${artifact}" && ! -L "${terminal_dir}/${artifact}" ]] || return 1
    actual="$(sha256sum "${terminal_dir}/${artifact}" | awk '{print $1}')" || return 1
    [[ "$actual" == "$hash" ]] || return 1
    index=$((index + 1))
  done < <(tail -n +2 "$hashes_file")
  [[ "$index" -eq "${#expected[@]}" ]]
}

_check_attempt_terminal_row() {
  local terminal_dir="$1"
  local log_path_override="${2:-}"
  local names log_path actual_log_hash
  local -A request=() snapshot=() result=()

  [[ -d "$terminal_dir" && ! -L "$terminal_dir" ]] || return 1
  names="$(find "$terminal_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" || return 1
  [[ "$names" == $'argv.tsv\nartifacts.sha256\ncombined.log\nrequest.state\nresult.state\nsnapshot.state' || \
     "$names" == $'artifacts.sha256\nargv.tsv\ncombined.log\nrequest.state\nresult.state\nsnapshot.state' ]] || {
    printf 'Check attempt terminal directory has unexpected content: %s\n' "$terminal_dir" >&2
    return 1
  }
  _check_attempt_validate_request "${terminal_dir}/request.state" request || return 1
  _check_attempt_validate_snapshot "${terminal_dir}/snapshot.state" snapshot || return 1
  _check_attempt_validate_result "${terminal_dir}/result.state" result || return 1
  _check_attempt_validate_argv "${terminal_dir}/argv.tsv" "${request[base_commit]}" || return 1
  _check_attempt_validate_artifact_hashes "$terminal_dir" || return 1
  [[ "${request[attempt_id]}" == "${terminal_dir##*/}" || \
     "${request[attempt_id]}.running" == "${terminal_dir##*/}" ]] || return 1
  [[ "${request[operation]}" == "$(basename "$(dirname "$terminal_dir")")" ]] || return 1
  [[ "${result[started_at]}" == "${request[started_at]}" ]] || return 1
  actual_log_hash="$(sha256sum "${terminal_dir}/combined.log" | awk '{print $1}')" || return 1
  [[ "$actual_log_hash" == "${result[log_sha256]}" ]] || return 1
  if [[ -n "$log_path_override" ]]; then
    log_path="$log_path_override"
  else
    log_path="$(check_attempt_repo_relative_path "${terminal_dir}/combined.log")" || return 1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${request[check_id]}" "${request[scope]}" "${request[scope_id]}" \
    "${request[operation]}" "${request[round]}" "${request[attempt_id]}" \
    "${request[kind]}" "${request[requirement_id]}" "${request[base_commit]}" \
    "${snapshot[head_commit]}" "${snapshot[worktree_tree]}" "${result[status]}" \
    "${result[exit_status]}" "${result[signal]}" "${result[started_at]}" \
    "${result[finished_at]}" "${result[duration_ms]}" "$log_path" "${result[log_sha256]}"
}

check_attempt_validate_manifest() {
  local manifest_file="$1"
  local header line
  local -a fields=()
  local -A seen=()
  local key

  [[ -f "$manifest_file" && ! -L "$manifest_file" ]] || {
    printf 'Checks manifest is missing or not a regular file: %s\n' "$manifest_file" >&2
    return 1
  }
  IFS= read -r header < "$manifest_file" || return 1
  [[ "$header" == "$CHECK_ATTEMPT_MANIFEST_HEADER" ]] || {
    printf 'Checks manifest header is invalid: %s\n' "$manifest_file" >&2
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != *$'\r'* ]] || return 1
    IFS=$'\t' read -r -a fields <<< "$line"
    [[ "${#fields[@]}" -eq 19 ]] || return 1
    [[ "${fields[0]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ "${fields[4]}" =~ ^[1-9][0-9]*$ && "${fields[5]}" =~ ^attempt-[0-9]{4,}$ ]] || return 1
    [[ "${fields[6]}" == consumer-hook && "${fields[7]}" == consumer-check-hook ]] || return 1
    _check_attempt_valid_sha "${fields[8]}" && _check_attempt_valid_sha "${fields[9]}" && \
      _check_attempt_valid_sha "${fields[10]}" && _check_attempt_valid_sha "${fields[18]}" || return 1
    case "${fields[1]}:${fields[3]}" in
      issue:issue-checks) [[ "${fields[2]}" =~ ^[1-9][0-9]*$ ]] || return 1 ;;
      batch:batch-checks) [[ "${fields[2]}" =~ ^batch-[1-9][0-9]*-[1-9][0-9]*$ ]] || return 1 ;;
      *) return 1 ;;
    esac
    [[ "${fields[11]}" == passed || "${fields[11]}" == failed || \
       "${fields[11]}" == interrupted || "${fields[11]}" == invalid ]] || return 1
    [[ "${fields[12]}" =~ ^[0-9]+$ && "${fields[12]}" -le 255 ]] || return 1
    [[ "${fields[13]}" == none || "${fields[13]}" == INT || \
       "${fields[13]}" == TERM || "${fields[13]}" == other ]] || return 1
    case "${fields[11]}:${fields[12]}:${fields[13]}" in
      passed:0:none|interrupted:130:INT|interrupted:143:TERM) ;;
      invalid:130:INT|invalid:143:TERM) ;;
      invalid:*:none) [[ "${fields[12]}" -lt 128 ]] || return 1 ;;
      invalid:*:other) [[ "${fields[12]}" -ge 128 && "${fields[12]}" -ne 130 && "${fields[12]}" -ne 143 ]] || return 1 ;;
      failed:*:none) [[ "${fields[12]}" -gt 0 && "${fields[12]}" -lt 128 ]] || return 1 ;;
      failed:*:other) [[ "${fields[12]}" -ge 128 && "${fields[12]}" -ne 130 && "${fields[12]}" -ne 143 ]] || return 1 ;;
      *) return 1 ;;
    esac
    _check_attempt_valid_timestamp "${fields[14]}" && _check_attempt_valid_timestamp "${fields[15]}" || return 1
    [[ "${fields[16]}" =~ ^[0-9]+$ ]] || return 1
    _check_attempt_valid_relative_path "${fields[17]}" || return 1
    key="${fields[0]}:${fields[5]}"
    [[ -z "${seen[$key]:-}" ]] || {
      printf 'Checks manifest contains duplicate check/attempt identity: %s\n' "$key" >&2
      return 1
    }
    seen["$key"]=1
  done < <(tail -n +2 "$manifest_file")
}

check_attempt_read_manifest() {
  local manifest_file="$1"
  check_attempt_validate_manifest "$manifest_file" || return 1
  cat -- "$manifest_file"
}

check_attempt_manifest_latest_status() {
  local manifest_file="$1"
  check_attempt_validate_manifest "$manifest_file" || return 1
  awk -F '\t' 'NR > 1 { status = $12 } END { if (status == "") exit 1; print status }' "$manifest_file"
}

_check_attempt_initialize_manifest() {
  local manifest_file="$1"
  local directory temporary

  if [[ -e "$manifest_file" ]]; then
    check_attempt_validate_manifest "$manifest_file"
    return
  fi
  directory="$(dirname "$manifest_file")"
  mkdir -p "$directory" || return 1
  temporary="$(mktemp "${directory}/.checks-manifest.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$CHECK_ATTEMPT_MANIFEST_HEADER" > "$temporary" || \
     ! check_attempt_validate_manifest "$temporary" || \
     ! mv -T -- "$temporary" "$manifest_file"; then
    rm -f -- "$temporary" || true
    return 1
  fi
}

_check_attempt_append_manifest_row() {
  local manifest_file="$1"
  local row="$2"
  local directory temporary

  check_attempt_validate_manifest "$manifest_file" || return 1
  directory="$(dirname "$manifest_file")"
  temporary="$(mktemp "${directory}/.checks-manifest.tmp.XXXXXX")" || return 1
  if ! cp -- "$manifest_file" "$temporary" || ! printf '%s\n' "$row" >> "$temporary" || \
     ! check_attempt_validate_manifest "$temporary" || ! mv -T -f -- "$temporary" "$manifest_file"; then
    rm -f -- "$temporary" || true
    return 1
  fi
}

_check_attempt_validate_manifest_rows_against_root() {
  local attempts_root="$1"
  local manifest_file="$2"
  local mirror_mode="${3:-0}"
  local line terminal_dir expected_row
  local -a fields=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS=$'\t' read -r -a fields <<< "$line"
    terminal_dir="${attempts_root}/${fields[3]}/${fields[5]}"
    if [[ "$mirror_mode" -eq 1 ]]; then
      expected_row="$(_check_attempt_terminal_row "$terminal_dir" "${fields[17]}")" || return 1
    else
      expected_row="$(_check_attempt_terminal_row "$terminal_dir")" || return 1
    fi
    [[ "$expected_row" == "$line" ]] || {
      printf 'Checks manifest row does not match terminal attempt: %s\n' "$terminal_dir" >&2
      return 1
    }
  done < <(tail -n +2 "$manifest_file")
}

check_attempt_reconcile_store() {
  local attempts_root="$1"
  local manifest_file="$2"
  local operation_dir terminal_dir row key existing

  mkdir -p "$attempts_root" || return 1
  _check_attempt_initialize_manifest "$manifest_file" || return 1
  _check_attempt_validate_manifest_rows_against_root "$attempts_root" "$manifest_file" || return 1

  for operation_dir in "${attempts_root}"/*; do
    [[ -e "$operation_dir" ]] || continue
    [[ -d "$operation_dir" && ! -L "$operation_dir" ]] || return 1
    case "${operation_dir##*/}" in issue-checks|batch-checks) ;; *) return 1 ;; esac
    for terminal_dir in "${operation_dir}"/attempt-*; do
      [[ -d "$terminal_dir" ]] || continue
      [[ "$terminal_dir" != *.running ]] || continue
      row="$(_check_attempt_terminal_row "$terminal_dir")" || return 1
      key="$(printf '%s\n' "$row" | awk -F '\t' '{print $1 "\t" $6}')"
      existing="$(awk -F '\t' -v key="$key" 'NR > 1 && ($1 "\t" $6) == key { print; exit }' "$manifest_file")"
      if [[ -n "$existing" ]]; then
        [[ "$existing" == "$row" ]] || return 1
      else
        _check_attempt_append_manifest_row "$manifest_file" "$row" || return 1
      fi
    done
  done
}

check_attempt_validate_store() {
  local attempts_root="$1"
  local manifest_file="$2"
  local mirror_mode="${3:-0}"
  local operation_dir terminal_dir row

  check_attempt_validate_manifest "$manifest_file" || return 1
  _check_attempt_validate_manifest_rows_against_root "$attempts_root" "$manifest_file" "$mirror_mode" || return 1
  for operation_dir in "${attempts_root}"/*; do
    [[ -e "$operation_dir" ]] || continue
    [[ -d "$operation_dir" && ! -L "$operation_dir" ]] || return 1
    case "${operation_dir##*/}" in issue-checks|batch-checks) ;; *) return 1 ;; esac
    for terminal_dir in "${operation_dir}"/attempt-*; do
      [[ -d "$terminal_dir" ]] || continue
      [[ "$terminal_dir" != *.running ]] || continue
      if [[ "$mirror_mode" -eq 1 ]]; then
        row="$(_check_attempt_terminal_row "$terminal_dir" ignored)" || return 1
      else
        row="$(_check_attempt_terminal_row "$terminal_dir")" || return 1
      fi
      awk -F '\t' -v check_id="${row%%$'\t'*}" -v attempt_id="${terminal_dir##*/}" \
        'NR > 1 && $1 == check_id && $6 == attempt_id { found++ } END { exit found != 1 }' \
        "$manifest_file" || return 1
    done
  done
}

publish_check_attempt_provenance_copy() {
  local source_root="$1"
  local source_manifest="$2"
  local destination_root="$3"
  local destination_manifest="$4"

  check_attempt_validate_store "$source_root" "$source_manifest" || return 1
  [[ ! -e "$destination_root" && ! -e "$destination_manifest" ]] || {
    printf 'Check attempt compatibility destination already exists: %s\n' "$destination_root" >&2
    return 1
  }
  mkdir -p "$(dirname "$destination_root")" "$(dirname "$destination_manifest")" || return 1
  cp -R -- "$source_root" "$destination_root" || return 1
  cp -- "$source_manifest" "$destination_manifest" || return 1
  check_attempt_validate_store "$destination_root" "$destination_manifest" 1
}

publish_check_attempt_legacy_log() {
  local source_file="$1"
  local legacy_log_file="$2"

  if declare -F check_attempt_before_legacy_publish >/dev/null 2>&1; then
    check_attempt_before_legacy_publish "$source_file" "$legacy_log_file" || return 1
  fi
  publish_agent_attempt_legacy_log "$source_file" "$legacy_log_file"
}

run_check_attempt() {
  local attempts_root="$1"
  local manifest_file="$2"
  local legacy_log_file="$3"
  local scope="$4"
  local scope_id="$5"
  local operation="$6"
  local round="$7"
  local base_commit="$8"
  shift 8
  local -a argv=("$@")
  local operation_dir attempt_id running_dir terminal_dir check_id
  local started_at finished_at started_ms finished_ms duration_ms
  local command_status snapshot_match=yes snapshot_error='' terminal_status signal=none effective_status
  local repository_status_before repository_status_after
  local log_sha result_tmp hashes_tmp row argument index

  CHECK_ATTEMPT_LAST_DIR=''
  CHECK_ATTEMPT_LAST_LOG=''
  CHECK_ATTEMPT_LAST_STATUS=''
  CHECK_ATTEMPT_LAST_EXIT_STATUS=''
  CHECK_ATTEMPT_LAST_PUBLISH_ERROR=0

  [[ "${#argv[@]}" -eq 2 && "${argv[1]}" == "$base_commit" ]] || {
    printf 'Check attempt requires exact executable and base-commit argv entries.\n' >&2
    return 1
  }
  for argument in "${argv[@]}"; do
    [[ -n "$argument" && "$argument" != *$'\t'* && "$argument" != *$'\r'* && "$argument" != *$'\n'* ]] || {
      printf 'Check attempt argv contains an unsupported control character.\n' >&2
      return 1
    }
  done
  _check_attempt_valid_sha "$base_commit" || {
    printf 'Check attempt base commit is invalid: %s\n' "$base_commit" >&2
    return 1
  }
  case "$scope:$operation" in
    issue:issue-checks) [[ "$scope_id" =~ ^[1-9][0-9]*$ ]] || return 1 ;;
    batch:batch-checks) [[ "$scope_id" =~ ^batch-[1-9][0-9]*-[1-9][0-9]*$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$round" =~ ^[1-9][0-9]*$ ]] || return 1

  check_attempt_reconcile_store "$attempts_root" "$manifest_file" || return 1
  operation_dir="${attempts_root}/${operation}"
  mkdir -p "$operation_dir" || return 1
  attempt_id="$(agent_attempt_next_id "$operation_dir")" || return 1
  running_dir="${operation_dir}/${attempt_id}.running"
  terminal_dir="${operation_dir}/${attempt_id}"
  mkdir "$running_dir" || return 1
  check_id="${scope}-${scope_id}-${operation}-round-${round}"
  started_at="$(check_attempt_now)" || return 1
  started_ms="$(check_attempt_epoch_ms)" || return 1
  repository_status_before="$(check_attempt_repository_status_sha256)" || return 1

  printf '%s\t%s\n' \
    schema_version 1 \
    check_id "$check_id" \
    scope "$scope" \
    scope_id "$scope_id" \
    operation "$operation" \
    round "$round" \
    attempt_id "$attempt_id" \
    kind consumer-hook \
    requirement_id consumer-check-hook \
    base_commit "$base_commit" \
    repository_status_sha256 "$repository_status_before" \
    started_at "$started_at" > "${running_dir}/request.state" || return 1
  index=0
  : > "${running_dir}/argv.tsv" || return 1
  for argument in "${argv[@]}"; do
    printf '%s\t%s\n' "$index" "$argument" >> "${running_dir}/argv.tsv" || return 1
    index=$((index + 1))
  done
  capture_review_snapshot "${running_dir}/snapshot.state" || return 1

  if "${argv[@]}" > "${running_dir}/combined.log" 2>&1; then
    command_status=0
  else
    command_status=$?
  fi
  if ! snapshot_error="$(assert_review_snapshot_matches "${running_dir}/snapshot.state" "after ${operation} ${attempt_id}" 2>&1)"; then
    snapshot_match=no
  fi
  repository_status_after="$(check_attempt_repository_status_sha256)" || return 1
  if [[ "$repository_status_before" != "$repository_status_after" ]]; then
    snapshot_match=no
    if [[ -n "$snapshot_error" ]]; then snapshot_error+=$'\n'; fi
    snapshot_error+="Check repository status mismatch after ${operation} ${attempt_id}: expected ${repository_status_before}, current ${repository_status_after}"
  fi
  if [[ -n "$snapshot_error" ]]; then
    printf '%s\n' "$snapshot_error" >> "${running_dir}/combined.log" || return 1
  fi

  if [[ "$snapshot_match" == no ]]; then
    terminal_status=invalid
  else
    case "$command_status" in
      0) terminal_status=passed ;;
      130) terminal_status=interrupted; signal=INT ;;
      143) terminal_status=interrupted; signal=TERM ;;
      *)
        terminal_status=failed
        if [[ "$command_status" -ge 128 ]]; then signal=other; fi
        ;;
    esac
  fi
  if [[ "$snapshot_match" == no ]]; then
    case "$command_status" in 130) signal=INT ;; 143) signal=TERM ;; *) if [[ "$command_status" -ge 128 ]]; then signal=other; fi ;; esac
  fi
  finished_at="$(check_attempt_now)" || return 1
  finished_ms="$(check_attempt_epoch_ms)" || return 1
  duration_ms=$((finished_ms - started_ms))
  [[ "$duration_ms" -ge 0 ]] || duration_ms=0
  log_sha="$(sha256sum "${running_dir}/combined.log" | awk '{print $1}')" || return 1

  result_tmp="$(mktemp "${running_dir}/.result.state.tmp.XXXXXX")" || return 1
  if ! printf '%s\t%s\n' \
    schema_version 1 \
    status "$terminal_status" \
    exit_status "$command_status" \
    signal "$signal" \
    started_at "$started_at" \
    finished_at "$finished_at" \
    duration_ms "$duration_ms" \
    snapshot_match "$snapshot_match" \
    log_sha256 "$log_sha" > "$result_tmp" || \
     ! mv -T -- "$result_tmp" "${running_dir}/result.state"; then
    rm -f -- "$result_tmp" || true
    return 1
  fi
  hashes_tmp="$(mktemp "${running_dir}/.artifacts.sha256.tmp.XXXXXX")" || return 1
  {
    printf 'sha256\tartifact\n'
    for argument in request.state snapshot.state argv.tsv combined.log result.state; do
      printf '%s\t%s\n' "$(sha256sum "${running_dir}/${argument}" | awk '{print $1}')" "$argument"
    done
  } > "$hashes_tmp" || return 1
  mv -T -- "$hashes_tmp" "${running_dir}/artifacts.sha256" || return 1
  _check_attempt_terminal_row "$running_dir" >/dev/null || return 1
  [[ ! -e "$terminal_dir" ]] || return 1
  mv -T -- "$running_dir" "$terminal_dir" || return 1
  row="$(_check_attempt_terminal_row "$terminal_dir")" || return 1
  _check_attempt_append_manifest_row "$manifest_file" "$row" || return 1
  check_attempt_validate_store "$attempts_root" "$manifest_file" || return 1

  CHECK_ATTEMPT_LAST_DIR="$terminal_dir"
  CHECK_ATTEMPT_LAST_LOG="${terminal_dir}/combined.log"
  CHECK_ATTEMPT_LAST_STATUS="$terminal_status"
  CHECK_ATTEMPT_LAST_EXIT_STATUS="$command_status"
  if ! publish_check_attempt_legacy_log "$CHECK_ATTEMPT_LAST_LOG" "$legacy_log_file"; then
    CHECK_ATTEMPT_LAST_PUBLISH_ERROR=1
    printf 'Failed to publish legacy checks log from terminal attempt: %s\n' "$terminal_dir" >&2
    return 1
  fi
  if [[ "$snapshot_match" == no ]]; then
    printf 'Check attempt is invalid because the repository snapshot changed: %s\n' "$terminal_dir" >&2
    [[ -z "$snapshot_error" ]] || printf '%s\n' "$snapshot_error" >&2
    return 1
  fi

  case "$terminal_status" in
    passed) effective_status=0 ;;
    *) effective_status="$command_status"; [[ "$effective_status" -ne 0 ]] || effective_status=1 ;;
  esac
  return "$effective_status"
}
