#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_QUEUE_STATE_LOADED:-}" ]]; then
  return 0
fi
readonly ISSUE_FORGE_QUEUE_STATE_LOADED=1

readonly CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION=1

atomic_write_from_stdin() {
  local destination
  local destination_dir
  local destination_name
  local temporary_file
  local write_status

  if [[ "$#" -ne 1 ]]; then
    printf 'atomic_write_from_stdin requires exactly one destination path\n' >&2
    return 1
  fi

  destination="$1"
  destination_dir="$(dirname -- "$destination")"
  destination_name="$(basename -- "$destination")"

  if ! mkdir -p -- "$destination_dir"; then
    printf 'Failed to create atomic write directory: %s\n' "$destination_dir" >&2
    return 1
  fi

  if ! temporary_file="$(mktemp "${destination_dir}/.${destination_name}.tmp.XXXXXX")"; then
    printf 'Failed to create temporary file for atomic write: %s\n' "$destination" >&2
    return 1
  fi

  if cat > "$temporary_file"; then
    :
  else
    write_status="$?"
    rm -f -- "$temporary_file"
    printf 'Failed to write temporary file for atomic replacement: %s\n' "$destination" >&2
    return "$write_status"
  fi

  if mv -- "$temporary_file" "$destination"; then
    :
  else
    write_status="$?"
    rm -f -- "$temporary_file"
    printf 'Failed to atomically replace destination: %s\n' "$destination" >&2
    return "$write_status"
  fi
}

write_state_tsv() {
  local destination
  local state_contents

  if [[ "$#" -lt 1 ]]; then
    printf 'write_state_tsv requires a destination path\n' >&2
    return 1
  fi

  destination="$1"
  shift

  if (( $# % 2 != 0 )); then
    printf 'write_state_tsv requires key/value argument pairs for: %s\n' "$destination" >&2
    return 1
  fi

  printf -v state_contents 'schema_version\t%s\n' "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION"
  while [[ "$#" -gt 0 ]]; do
    printf -v state_contents '%s%s\t%s\n' "$state_contents" "$1" "$2"
    shift 2
  done

  printf '%s' "$state_contents" | atomic_write_from_stdin "$destination"
}

read_state_tsv_value() {
  local state_file
  local required_key
  local first_line
  local line_key
  local line_value

  if [[ "$#" -ne 2 ]]; then
    printf 'read_state_tsv_value requires a state path and key\n' >&2
    return 1
  fi

  state_file="$1"
  required_key="$2"

  if [[ ! -f "$state_file" ]]; then
    printf 'Missing queue state file: %s\n' "$state_file" >&2
    return 1
  fi

  if ! IFS= read -r first_line < "$state_file"; then
    printf 'Unsupported queue state schema in %s: expected schema_version<TAB>%s\n' \
      "$state_file" "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" >&2
    return 1
  fi

  if [[ "$first_line" != $'schema_version\t'"$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" ]]; then
    printf 'Unsupported queue state schema in %s: expected schema_version<TAB>%s\n' \
      "$state_file" "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" >&2
    return 1
  fi

  while IFS=$'\t' read -r line_key line_value; do
    if [[ "$line_key" == "$required_key" ]]; then
      printf '%s\n' "$line_value"
      return 0
    fi
  done < "$state_file"

  printf 'Missing required queue state key in %s: %s\n' "$state_file" "$required_key" >&2
  return 1
}

write_issue_state_tsv() {
  local destination
  local status
  local phase
  local exit_code
  local lease_owner

  if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
    printf 'write_issue_state_tsv requires state path, status, phase, exit code, and optional lease owner\n' >&2
    return 1
  fi

  destination="$1"
  status="$2"
  phase="$3"
  exit_code="$4"
  lease_owner="${5:-}"

  if [[ -z "$lease_owner" ]]; then
    if [[ ! -f "$destination" ]]; then
      printf 'Missing Issue state file for lease-preserving update: %s\n' "$destination" >&2
      return 1
    fi
    lease_owner="$(read_state_tsv_value "$destination" lease_owner)"
  fi

  if [[ -z "$lease_owner" ]]; then
    printf 'Missing lease owner for Issue state update: %s\n' "$destination" >&2
    return 1
  fi

  write_state_tsv "$destination" \
    status "$status" \
    phase "$phase" \
    lease_owner "$lease_owner" \
    exit_code "$exit_code"
}
