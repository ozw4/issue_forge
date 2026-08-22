#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_FINDING_SCHEDULER_LOADED:-}" ]]; then
  return 0
fi

# shellcheck source=tools/codex/lib/finding_ledger.sh
if ! declare -F require_tsv_header >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finding_ledger.sh"
fi
# shellcheck source=tools/codex/lib/review_details.sh
if [[ -z "${ISSUE_FORGE_REVIEW_DETAILS_LOADED:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_details.sh"
fi

readonly ACTIVE_FINDING_HEADER=$'finding_id\tseverity\ttext'
readonly ACTIVE_FINDING_DETAILS_HEADER=$'finding_id\tseverity\ttext\tevidence\timpact\trequired_outcome\tconstraints\tvalidation'

_finding_scheduler_require_regular_file() {
  local path="$1"
  local description="$2"

  if [[ ! -f "$path" || -L "$path" ]]; then
    printf '%s is not a regular file: %s\n' "$description" "$path" >&2
    return 1
  fi
}

_finding_scheduler_require_output_path() {
  local path="$1"
  local description="$2"

  if [[ -z "$path" || -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
    printf '%s destination is invalid: %s\n' "$description" "$path" >&2
    return 1
  fi
}

_finding_scheduler_paths_alias() {
  local first="$1"
  local second="$2"
  local first_canonical
  local second_canonical

  if [[ "$first" == "$second" ]] \
    || [[ -e "$first" && -e "$second" && "$first" -ef "$second" ]]; then
    return 0
  fi
  if first_canonical="$(_finding_scheduler_canonical_destination "$first")" \
    && second_canonical="$(_finding_scheduler_canonical_destination "$second")" \
    && [[ "$first_canonical" == "$second_canonical" ]]; then
    return 0
  fi
  return 1
}

_finding_scheduler_canonical_destination() {
  local path="$1"
  local parent
  local basename
  local canonical_parent

  if [[ "$path" == */* ]]; then
    parent="${path%/*}"
    basename="${path##*/}"
    [[ -n "$parent" ]] || parent='/'
  else
    parent='.'
    basename="$path"
  fi
  canonical_parent="$(cd -P -- "$parent" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "${canonical_parent%/}" "$basename"
}

_validate_fix_resolution_report() {
  local report="$1"
  local required_rows="${2:-any}"

  awk -F '\t' -v expected_header="$FIX_RESOLUTION_HEADER" -v required_rows="$required_rows" '
    function invalid() { failed = 1; exit 1 }
    NR == 1 {
      if ($0 != expected_header) invalid()
      next
    }
    {
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) invalid()
      if ($2 != "fixed" && $2 != "false_positive" && $2 != "cannot_fix") invalid()
      if ($3 == "" || index($3, "\r") || index($3, " | ") || $1 in seen) invalid()
      seen[$1] = 1
      row_count += 1
    }
    END {
      if (failed || NR == 0) exit 1
      if (required_rows != "any" && row_count != required_rows + 0) exit 1
    }
  ' "$report"
}

initialize_fix_resolution_report() {
  local output_file="$1"
  local temporary_file

  _finding_scheduler_require_output_path "$output_file" 'Fix resolution report' || return 1
  temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary fix resolution report: %s\n' "$output_file" >&2
    return 1
  }
  if ! printf '%s\n' "$FIX_RESOLUTION_HEADER" > "$temporary_file" \
    || ! mv -T -f -- "$temporary_file" "$output_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to initialize fix resolution report: %s\n' "$output_file" >&2
    return 1
  fi
}

append_fix_resolution_report() {
  local cumulative_file="$1"
  local incoming_file="$2"
  local incoming_id
  local temporary_file

  _finding_scheduler_require_regular_file "$cumulative_file" 'Cumulative fix resolution report' || return 1
  _finding_scheduler_require_regular_file "$incoming_file" 'Incoming fix resolution report' || return 1
  _finding_scheduler_require_output_path "$cumulative_file" 'Cumulative fix resolution report' || return 1
  require_tsv_header "$cumulative_file" "$FIX_RESOLUTION_HEADER" 'Cumulative fix resolution report' || return 1
  require_tsv_header "$incoming_file" "$FIX_RESOLUTION_HEADER" 'Incoming fix resolution report' || return 1
  if ! _validate_fix_resolution_report "$cumulative_file" \
    || ! _validate_fix_resolution_report "$incoming_file" 1; then
    printf 'Fix resolution report rows are invalid.\n' >&2
    return 1
  fi

  incoming_id="$(awk -F '\t' 'NR == 2 { print $1 }' "$incoming_file")"
  if awk -F '\t' -v incoming_id="$incoming_id" 'NR > 1 && $1 == incoming_id { found = 1 } END { exit !found }' \
    "$cumulative_file"; then
    printf 'Duplicate fix resolution finding ID: %s\n' "$incoming_id" >&2
    return 1
  fi

  temporary_file="$(mktemp "${cumulative_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary cumulative fix resolution report: %s\n' "$cumulative_file" >&2
    return 1
  }
  if ! awk 'FNR == 1 && NR != 1 { next } { print }' "$cumulative_file" "$incoming_file" > "$temporary_file" \
    || ! mv -T -f -- "$temporary_file" "$cumulative_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to append cumulative fix resolution report: %s\n' "$cumulative_file" >&2
    return 1
  fi
}

_build_next_active_finding_files() {
  local pending_file="$1"
  local pending_details_file="$2"
  local fix_resolution_file="$3"
  local active_temporary="$4"
  local active_details_temporary="$5"

  awk -F '\t' -v OFS='\t' \
    -v pending_file="$pending_file" \
    -v details_file="$pending_details_file" \
    -v resolution_file="$fix_resolution_file" \
    -v active_file="$active_temporary" \
    -v active_details_file="$active_details_temporary" \
    -v active_header="$ACTIVE_FINDING_HEADER" \
    -v active_details_header="$ACTIVE_FINDING_DETAILS_HEADER" '
    function valid_severity(value) {
      return value == "blocker" || value == "major" || value == "minor"
    }
    function invalid() { failed = 1; exit 1 }
    index($0, "\r") { invalid() }
    FILENAME == pending_file {
      if (FNR == 1) next
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !valid_severity($2) || $3 == "") invalid()
      if ($1 in pending_id_seen || $3 in pending_text_seen) invalid()
      pending_order[++pending_count] = $1
      pending_id_seen[$1] = 1
      pending_text_seen[$3] = 1
      pending_severity[$1] = $2
      pending_text[$1] = $3
      next
    }
    FILENAME == details_file {
      if (FNR == 1) next
      if (NF != 8 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !valid_severity($2)) invalid()
      if ($3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "" || $8 == "") invalid()
      if ($1 in detail_seen || !($1 in pending_id_seen)) invalid()
      if (pending_severity[$1] != $2 || pending_text[$1] != $3) invalid()
      detail_seen[$1] = 1
      detail_count += 1
      evidence[$1] = $4
      impact[$1] = $5
      required_outcome[$1] = $6
      constraints[$1] = $7
      validation[$1] = $8
      next
    }
    FILENAME == resolution_file {
      if (FNR == 1) next
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) invalid()
      if ($2 != "fixed" && $2 != "false_positive" && $2 != "cannot_fix") invalid()
      if ($3 == "" || index($3, " | ") || $1 in processed || !($1 in pending_id_seen)) invalid()
      processed[$1] = 1
      next
    }
    END {
      if (failed || detail_count != pending_count) exit 1
      for (i = 1; i <= pending_count; i++) {
        id = pending_order[i]
        if (!(id in detail_seen)) exit 1
      }

      print active_header > active_file
      print active_details_header > active_details_file
      severity_order[1] = "blocker"
      severity_order[2] = "major"
      severity_order[3] = "minor"
      for (severity_index = 1; severity_index <= 3 && selected == ""; severity_index++) {
        for (i = 1; i <= pending_count; i++) {
          id = pending_order[i]
          if (!(id in processed) && pending_severity[id] == severity_order[severity_index]) {
            selected = id
            break
          }
        }
      }
      if (selected != "") {
        print selected, pending_severity[selected], pending_text[selected] >> active_file
        print selected, pending_severity[selected], pending_text[selected], evidence[selected], impact[selected], required_outcome[selected], constraints[selected], validation[selected] >> active_details_file
      }
    }
  ' "$pending_file" "$pending_details_file" "$fix_resolution_file"
}

write_next_active_finding() {
  local pending_file="$1"
  local pending_details_file="$2"
  local fix_resolution_file="$3"
  local active_file="$4"
  local active_details_file="$5"
  local active_input
  local active_temporary
  local active_details_temporary

  if _finding_scheduler_paths_alias "$active_file" "$active_details_file"; then
    printf 'Active finding destinations must be distinct: %s and %s\n' \
      "$active_file" "$active_details_file" >&2
    return 1
  fi
  for active_input in "$pending_file" "$pending_details_file" "$fix_resolution_file"; do
    if _finding_scheduler_paths_alias "$active_file" "$active_input" \
      || _finding_scheduler_paths_alias "$active_details_file" "$active_input"; then
      printf 'Active finding destinations must not alias an input: %s\n' "$active_input" >&2
      return 1
    fi
  done

  _finding_scheduler_require_regular_file "$pending_file" 'Pending findings' || return 1
  _finding_scheduler_require_regular_file "$pending_details_file" 'Pending finding details' || return 1
  _finding_scheduler_require_regular_file "$fix_resolution_file" 'Fix resolution report' || return 1
  _finding_scheduler_require_output_path "$active_file" 'Active finding' || return 1
  _finding_scheduler_require_output_path "$active_details_file" 'Active finding details' || return 1
  require_tsv_header "$pending_file" "$PENDING_FINDINGS_HEADER" 'Pending findings' || return 1
  require_tsv_header "$pending_details_file" "$PENDING_FINDING_DETAILS_HEADER" 'Pending finding details' || return 1
  require_tsv_header "$fix_resolution_file" "$FIX_RESOLUTION_HEADER" 'Fix resolution report' || return 1

  active_temporary="$(mktemp "${active_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary active finding file: %s\n' "$active_file" >&2
    return 1
  }
  active_details_temporary="$(mktemp "${active_details_file}.tmp.XXXXXX")" || {
    rm -f -- "$active_temporary"
    printf 'Failed to create temporary active finding details file: %s\n' "$active_details_file" >&2
    return 1
  }

  if ! _build_next_active_finding_files \
    "$pending_file" "$pending_details_file" "$fix_resolution_file" \
    "$active_temporary" "$active_details_temporary"; then
    rm -f -- "$active_temporary" "$active_details_temporary"
    printf 'Active finding inputs are invalid.\n' >&2
    return 1
  fi
  if ! mv -T -f -- "$active_details_temporary" "$active_details_file"; then
    rm -f -- "$active_temporary" "$active_details_temporary"
    printf 'Failed to publish active finding details: %s\n' "$active_details_file" >&2
    return 1
  fi
  if ! mv -T -f -- "$active_temporary" "$active_file"; then
    rm -f -- "$active_temporary"
    printf 'Failed to publish active finding commit marker: %s\n' "$active_file" >&2
    return 1
  fi
}

active_finding_id() {
  local active_file="$1"
  local active_details_file="${2:-}"
  local active_id
  local active_status

  _finding_scheduler_require_regular_file "$active_file" 'Active finding' || return 1
  _finding_scheduler_require_regular_file \
    "$active_details_file" 'Active finding details' || return 1
  require_tsv_header "$active_file" "$ACTIVE_FINDING_HEADER" 'Active finding' || return 1
  require_tsv_header \
    "$active_details_file" "$ACTIVE_FINDING_DETAILS_HEADER" 'Active finding details' || return 1

  if active_id="$(awk -F '\t' \
    -v active_file="$active_file" \
    -v active_details_file="$active_details_file" '
    function invalid() { failed = 1; exit 1 }
    index($0, "\r") { invalid() }
    FILENAME == active_file {
      if (FNR == 1) next
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) invalid()
      if ($2 != "blocker" && $2 != "major" && $2 != "minor") invalid()
      if ($3 == "") invalid()
      active_count += 1
      active_id = $1
      active_severity = $2
      active_text = $3
      next
    }
    FILENAME == active_details_file {
      if (FNR == 1) next
      if (NF != 8 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) invalid()
      if ($2 != "blocker" && $2 != "major" && $2 != "minor") invalid()
      for (column = 3; column <= 8; column++) {
        if ($column == "") invalid()
      }
      details_count += 1
      details_id = $1
      details_severity = $2
      details_text = $3
    }
    END {
      if (failed || active_count > 1 || details_count > 1) exit 1
      if (active_count != details_count) exit 1
      if (active_count == 0) exit 2
      if (active_id != details_id \
        || active_severity != details_severity \
        || active_text != details_text) exit 1
      print active_id
    }
  ' "$active_file" "$active_details_file")"; then
    printf '%s\n' "$active_id"
    return 0
  else
    active_status=$?
  fi
  if [[ "$active_status" -eq 2 ]]; then
    return 2
  fi
  printf 'Active finding artifacts are inconsistent: %s and %s\n' \
    "$active_file" "$active_details_file" >&2
  return 1
}

finding_scheduler_state_digest() {
  local state_file
  local state_digest

  if [[ "$#" -eq 0 ]]; then
    printf 'Finding scheduler state digest requires at least one artifact.\n' >&2
    return 1
  fi
  for state_file in "$@"; do
    _finding_scheduler_require_regular_file \
      "$state_file" 'Finding scheduler state artifact' || return 1
    state_digest="$(git hash-object --no-filters -- "$state_file")" || {
      printf 'Failed to hash finding scheduler state artifact: %s\n' "$state_file" >&2
      return 1
    }
    printf '%s\n' "$state_digest"
  done
}

backup_finding_scheduler_state() {
  local backup_dir
  local backup_file
  local state_file
  local state_index=0

  if [[ "$#" -eq 0 ]]; then
    printf 'Finding scheduler state backup requires at least one artifact.\n' >&2
    return 1
  fi
  backup_dir="$(mktemp -d)" || {
    printf 'Failed to create finding scheduler state backup directory.\n' >&2
    return 1
  }
  for state_file in "$@"; do
    _finding_scheduler_require_regular_file \
      "$state_file" 'Finding scheduler state artifact' || {
      remove_finding_scheduler_state_backup "$backup_dir" || true
      return 1
    }
    printf -v backup_file '%s/artifact-%06d' "$backup_dir" "$state_index"
    if ! cp -p -- "$state_file" "$backup_file"; then
      remove_finding_scheduler_state_backup "$backup_dir" || true
      printf 'Failed to back up finding scheduler state artifact: %s\n' "$state_file" >&2
      return 1
    fi
    state_index=$((state_index + 1))
  done
  printf '%s\n' "$backup_dir"
}

restore_finding_scheduler_state() {
  local backup_dir="$1"
  local backup_file
  local restore_temporary
  local state_file
  local state_index=0
  shift

  if [[ ! -d "$backup_dir" || -L "$backup_dir" ]]; then
    printf 'Finding scheduler state backup directory is invalid: %s\n' "$backup_dir" >&2
    return 1
  fi
  for state_file in "$@"; do
    printf -v backup_file '%s/artifact-%06d' "$backup_dir" "$state_index"
    _finding_scheduler_require_regular_file \
      "$backup_file" 'Finding scheduler state backup artifact' || return 1
    if [[ -d "$state_file" && ! -L "$state_file" ]]; then
      printf 'Cannot restore finding scheduler state artifact replaced by a directory: %s (backup: %s)\n' \
        "$state_file" "$backup_file" >&2
      return 1
    fi
    state_index=$((state_index + 1))
  done
  state_index=0
  for state_file in "$@"; do
    printf -v backup_file '%s/artifact-%06d' "$backup_dir" "$state_index"
    restore_temporary="$(mktemp "${state_file}.restore.XXXXXX")" || {
      printf 'Failed to create temporary restored scheduler artifact: %s\n' \
        "$state_file" >&2
      return 1
    }
    if ! cp -p -- "$backup_file" "$restore_temporary" \
      || ! mv -T -f -- "$restore_temporary" "$state_file"; then
      rm -f -- "$restore_temporary"
      printf 'Failed to restore finding scheduler state artifact: %s\n' "$state_file" >&2
      return 1
    fi
    state_index=$((state_index + 1))
  done
}

remove_finding_scheduler_state_backup() {
  local backup_dir="$1"

  if [[ -z "$backup_dir" || ! -d "$backup_dir" || -L "$backup_dir" ]]; then
    printf 'Finding scheduler state backup directory is invalid: %s\n' "$backup_dir" >&2
    return 1
  fi
  if ! rm -f -- "$backup_dir"/artifact-* || ! rmdir -- "$backup_dir"; then
    printf 'Failed to remove finding scheduler state backup directory: %s\n' \
      "$backup_dir" >&2
    return 1
  fi
}

assert_finding_scheduler_state_matches() {
  local expected_digest="$1"
  local current_digest
  shift

  current_digest="$(finding_scheduler_state_digest "$@")" || {
    printf 'Finding scheduler state artifacts changed during the Fixer invocation.\n' >&2
    return 1
  }
  if [[ "$current_digest" != "$expected_digest" ]]; then
    printf 'Finding scheduler state artifacts changed during the Fixer invocation.\n' >&2
    return 1
  fi
}

assert_finding_scheduler_state_matches_or_restore() {
  local expected_digest="$1"
  local backup_dir="$2"
  shift 2

  if assert_finding_scheduler_state_matches "$expected_digest" "$@"; then
    remove_finding_scheduler_state_backup "$backup_dir"
    return 0
  fi
  restore_finding_scheduler_state "$backup_dir" "$@" || {
    printf 'Finding scheduler state restoration requires manual recovery; backup retained at: %s\n' \
      "$backup_dir" >&2
    return 1
  }
  assert_finding_scheduler_state_matches "$expected_digest" "$@" || {
    printf 'Restored finding scheduler state could not be verified; backup retained at: %s\n' \
      "$backup_dir" >&2
    return 1
  }
  remove_finding_scheduler_state_backup "$backup_dir" || return 1
  return 1
}

readonly ISSUE_FORGE_FINDING_SCHEDULER_LOADED=1
