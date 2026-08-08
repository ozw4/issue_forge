#!/usr/bin/env bash

if declare -F issue_forge_queue_manual_review_guard_loaded >/dev/null 2>&1; then
  return 0
fi

queue_manual_review_guard_error() {
  printf '[queue] Manual-review guard failed: %s\n' "$1" >&2
  return 1
}

queue_manual_review_validate_report() {
  local report="$1"
  local expected_run="$2"
  local -n phase_result="$3"
  local schema run parsed_phase last_index index
  local -a lines=()

  queue_state_require_singleton_path "$report" required \
    || queue_manual_review_guard_error "missing or invalid manual-review report: ${report}" \
    || return 1
  if [[ -s "$report" && -n "$(tail -c 1 "$report")" ]]; then
    queue_manual_review_guard_error "manual-review report is missing its final newline: ${report}"
    return 1
  fi
  mapfile -t lines < "$report" \
    || queue_manual_review_guard_error "cannot read manual-review report: ${report}" \
    || return 1
  [[ "${#lines[@]}" -ge 6 ]] \
    || queue_manual_review_guard_error "manual-review report is incomplete: ${report}" \
    || return 1

  [[ "${lines[0]}" == $'schema_version\t'* ]] \
    || queue_manual_review_guard_error "manual-review report lacks schema_version: ${report}" \
    || return 1
  schema="${lines[0]#*$'\t'}"
  [[ "$schema" == "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" ]] \
    || queue_manual_review_guard_error "unsupported manual-review report schema ${schema}: ${report}" \
    || return 1

  [[ "${lines[1]}" == $'run_id\t'* ]] \
    || queue_manual_review_guard_error "manual-review report lacks run_id: ${report}" \
    || return 1
  run="${lines[1]#*$'\t'}"
  [[ "$run" == "$expected_run" ]] \
    || queue_manual_review_guard_error "manual-review report belongs to run ${run}, not ${expected_run}" \
    || return 1

  [[ "${lines[2]}" == $'phase\t'* ]] \
    || queue_manual_review_guard_error "manual-review report lacks phase: ${report}" \
    || return 1
  parsed_phase="${lines[2]#*$'\t'}"
  case "$parsed_phase" in
    issue_flow|batch_checks|batch_review) ;;
    *)
      queue_manual_review_guard_error "unsupported manual-review phase ${parsed_phase}: ${report}"
      return 1
      ;;
  esac

  [[ "${lines[3]}" == dirty_paths_begin ]] \
    || queue_manual_review_guard_error "manual-review report lacks dirty_paths_begin: ${report}" \
    || return 1
  last_index=$((${#lines[@]} - 1))
  [[ "${lines[$last_index]}" == dirty_paths_end ]] \
    || queue_manual_review_guard_error "manual-review report lacks dirty_paths_end: ${report}" \
    || return 1
  for ((index = 4; index < last_index; index += 1)); do
    [[ -n "${lines[$index]}" ]] \
      || queue_manual_review_guard_error "manual-review report contains an empty dirty-path entry: ${report}" \
      || return 1
    case "${lines[$index]}" in
      dirty_paths_begin|dirty_paths_end)
        queue_manual_review_guard_error "manual-review report contains nested dirty-path markers: ${report}"
        return 1
        ;;
    esac
  done

  phase_result="$parsed_phase"
}

queue_manual_review_inspect_state() {
  local state_file="$1"
  local -n report_result="$2"
  local -n phase_result="$3"
  local state run report_path report_phase

  [[ -e "$state_file" ]] || return 1
  queue_state_validate_file "$state_file" run \
    || queue_manual_review_guard_error "invalid run state while checking manual review: ${state_file}" \
    || return 2
  state="$(queue_state_read_field "$state_file" run state)" || return 2
  [[ "$state" == manual_review_required ]] || return 1
  run="$(queue_state_read_field "$state_file" run run_id)" || return 2
  report_path="$(dirname "$state_file")/manual-review.txt"
  queue_manual_review_validate_report "$report_path" "$run" report_phase || return 2
  report_result="$report_path"
  phase_result="$report_phase"
}

queue_manual_review_require_clean_resolution() {
  local state_file="$1"
  local report phase dirty

  queue_manual_review_inspect_state "$state_file" report phase || return $?
  if ! dirty="$(issue_forge_status_outside_work_original)"; then
    queue_manual_review_guard_error "cannot inspect the consumer worktree for ${report}"
    return 2
  fi
  if [[ -n "$dirty" ]]; then
    printf '[queue] Dirty interrupted inner phase remains unresolved: run=%s phase=%s\n' \
      "$(queue_state_read_field "$state_file" run run_id)" "$phase" >&2
    printf '[queue] Original manual-review report is preserved at %s\n' "$report" >&2
    printf '[queue] Dirty paths still present:\n%s\n' "$dirty" >&2
    printf '[queue] Recovery: finish or revert these paths, make the consumer worktree clean, then resume the same run.\n' >&2
    return 1
  fi
}

queue_install_manual_review_guard() {
  local definition

  [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 ]] || return 0
  declare -F queue_state_transition >/dev/null 2>&1 || return 0
  declare -F queue_state_checkpoint >/dev/null 2>&1 || return 0
  declare -F status_outside_work >/dev/null 2>&1 || return 0
  declare -F issue_forge_queue_state_transition_original >/dev/null 2>&1 && return 0

  definition="$(declare -f queue_state_transition)" || return 1
  definition="${definition/#queue_state_transition /issue_forge_queue_state_transition_original }"
  eval "$definition"
  definition="$(declare -f queue_state_checkpoint)" || return 1
  definition="${definition/#queue_state_checkpoint /issue_forge_queue_state_checkpoint_original }"
  eval "$definition"
  definition="$(declare -f status_outside_work)" || return 1
  definition="${definition/#status_outside_work /issue_forge_status_outside_work_original }"
  eval "$definition"

  status_outside_work() {
    local state_file report phase inspect_status

    if [[ -n "${run_state_dir:-}" ]]; then
      state_file="${run_state_dir}/run.state"
      if queue_manual_review_inspect_state "$state_file" report phase; then
        return 0
      else
        inspect_status=$?
        [[ "$inspect_status" -eq 2 ]] && return 1
      fi
    fi
    issue_forge_status_outside_work_original "$@"
  }

  queue_state_transition() {
    local target="$1" schema="$2" expected="$4" requested="$5" inspect_status

    if [[ "$schema" == run && "$expected" == manual_review_required && "$requested" == running ]]; then
      if queue_manual_review_require_clean_resolution "$target"; then
        :
      else
        inspect_status=$?
        [[ "$inspect_status" -eq 1 || "$inspect_status" -eq 2 ]] && return 1
      fi
    fi
    issue_forge_queue_state_transition_original "$@"
  }

  queue_state_checkpoint() {
    local target="$1" checkpoint_run="$2" entity="$3" state_file report phase inspect_status

    if [[ "$entity" == run ]]; then
      state_file="$(dirname "$target")/run.state"
      if queue_manual_review_inspect_state "$state_file" report phase; then
        [[ "$(queue_state_read_field "$state_file" run run_id)" == "$checkpoint_run" ]] \
          || queue_manual_review_guard_error "checkpoint run ${checkpoint_run} does not match manual-review state"
        return $?
      else
        inspect_status=$?
        [[ "$inspect_status" -eq 2 ]] && return 1
      fi
    fi
    issue_forge_queue_state_checkpoint_original "$@"
  }
}

queue_install_manual_review_guard || return 1
issue_forge_queue_manual_review_guard_loaded() { :; }
