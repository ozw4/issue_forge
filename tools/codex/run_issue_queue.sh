#!/usr/bin/env bash
set -euo pipefail

queue_bootstrap_private_environment() {
  local name requested_test_mode="${CODEX_FLOW_QUEUE_TEST_MODE:-0}"
  [[ "$requested_test_mode" == 0 || "$requested_test_mode" == 1 ]] || {
    printf '[queue] CODEX_FLOW_QUEUE_TEST_MODE must be 0 or 1\n' >&2
    exit 1
  }
  for name in \
    QUEUE_STATE_GUARD_DEPTH \
    QUEUE_STATE_GUARD_FD \
    QUEUE_STATE_ASSERT_IN_PROGRESS \
    QUEUE_STATE_ASSERT_OWNED_FUNCTION \
    QUEUE_STATE_SERIALIZATION_GUARD \
    ISSUE_FORGE_INTERNAL_QUEUE_GUARD_DEPTH \
    ISSUE_FORGE_INTERNAL_QUEUE_GUARD_FD \
    ISSUE_FORGE_INTERNAL_QUEUE_ASSERT_IN_PROGRESS \
    ISSUE_FORGE_INTERNAL_QUEUE_ASSERT_OWNED_FUNCTION \
    ISSUE_FORGE_INTERNAL_QUEUE_SERIALIZATION_GUARD \
    ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE \
    ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE \
    ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG \
    ISSUE_FORGE_INTERNAL_QUEUE_GUARD_BUSY_FUNCTION \
    ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE; do
    if ! unset "$name" 2>/dev/null; then
      printf '[queue] Private queue state variable is readonly and cannot be initialized: %s\n' "$name" >&2
      exit 1
    fi
  done
  unset CODEX_FLOW_QUEUE_TEST_MODE
  readonly ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE="$requested_test_mode"
  readonly ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1
}

queue_bootstrap_private_environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/history_helpers.sh
source "${SCRIPT_DIR}/lib/history_helpers.sh"
# shellcheck source=tools/codex/lib/checks_review_helpers.sh
source "${SCRIPT_DIR}/lib/checks_review_helpers.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/review_snapshots.sh
source "${SCRIPT_DIR}/lib/review_snapshots.sh"
# shellcheck source=tools/codex/lib/queue_state.sh
source "${SCRIPT_DIR}/lib/queue_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"
# shellcheck source=tools/codex/lib/prompt_templates.sh
source "${SCRIPT_DIR}/lib/prompt_templates.sh"
# shellcheck source=tools/codex/lib/batch_review_helpers.sh
source "${SCRIPT_DIR}/lib/batch_review_helpers.sh"

log_info() {
  printf '[queue] %s\n' "$1"
}

log_error() {
  printf '[queue] %s\n' "$1" >&2
}

fail() {
  printf '[queue] %s\n' "$1" >&2
  exit 1
}

queue_failpoint() {
  [[ "$ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE" == 1 && "${CODEX_FLOW_QUEUE_FAILPOINT:-}" == "$1" ]] \
    || return 0
  fail "Queue failpoint triggered: $1"
}

queue_test_barrier() {
  local name="$1" directory="${CODEX_FLOW_QUEUE_TEST_BARRIER_DIR:-}" label="${CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL:-$$}"
  [[ "$ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE" == 1 && -n "$directory" ]] || return 0
  mkdir -p "$directory"
  : > "${directory}/ready.${name}.${label}"
  while [[ ! -f "${directory}/release.${name}" ]]; do sleep 0.01; done
}

queue_test_pause() {
  local name="$1" directory="${CODEX_FLOW_QUEUE_TEST_PAUSE_DIR:-}" label="${CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL:-$$}"
  [[ "$ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE" == 1 && -n "$directory" && "${CODEX_FLOW_QUEUE_TEST_PAUSE_AT:-}" == "$name" ]] || return 0
  mkdir -p "$directory"
  : > "${directory}/paused.${name}.${label}"
  while [[ ! -f "${directory}/release.${name}.${label}" ]]; do sleep 0.01; done
}

validate_queue_private_environment() {
  local name
  for name in \
    QUEUE_STATE_GUARD_DEPTH \
    QUEUE_STATE_GUARD_FD \
    QUEUE_STATE_ASSERT_IN_PROGRESS \
    QUEUE_STATE_ASSERT_OWNED_FUNCTION \
    QUEUE_STATE_SERIALIZATION_GUARD \
    CODEX_FLOW_QUEUE_TEST_MODE; do
    if [[ -v "$name" ]]; then
      fail "Consumer config must not set private queue variable ${name}"
    fi
  done
  if [[ "$ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE" != 1 ]]; then
    for name in \
      CODEX_FLOW_QUEUE_FAILPOINT \
      CODEX_FLOW_QUEUE_TEST_BARRIER_DIR \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR \
      CODEX_FLOW_QUEUE_TEST_PAUSE_AT \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL \
      QUEUE_STATE_TEST_INTERRUPT_BEFORE_MV \
      QUEUE_STATE_TEST_PAUSE_DIR \
      QUEUE_STATE_TEST_PAUSE_AT \
      QUEUE_STATE_TEST_RUNNER_LABEL; do
      if [[ -n "${!name:-}" ]]; then
        fail "Queue test hook ${name} requires CODEX_FLOW_QUEUE_TEST_MODE=1"
      fi
    done
  fi
}

usage() {
  cat <<'EOF'
Usage: tools/codex/run_issue_queue.sh [options] <issue_number> [issue_number...]
       tools/codex/run_issue_queue.sh --resume <run_id|current> [--take-over-lease]

Options:
  --review-every <positive_integer>
  --batch-review-effort <non_empty_value_without_whitespace>
  --batch-fix-effort <non_empty_value_without_whitespace>
  --auto-merge
  --draft
  --resume <run_id|current>
  --take-over-lease
  --help
EOF
}

require_positive_integer_value() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then
    fail "${name} must be a positive integer: ${value}"
  fi
}

require_nonempty_no_whitespace_value() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    fail "${name} must be non-empty"
  fi

  if [[ "$value" =~ [[:space:]] ]]; then
    fail "${name} must not contain whitespace: ${value}"
  fi
}

parse_queue_arguments() {
  review_every="$CODEX_FLOW_QUEUE_REVIEW_EVERY"
  batch_review_effort="$CODEX_FLOW_BATCH_REVIEW_REASONING"
  batch_review_fix_effort="$CODEX_FLOW_BATCH_FIX_REASONING"
  batch_check_fix_effort="$CODEX_FLOW_BATCH_CHECK_FIX_REASONING"
  draft_pr=0
  auto_merge=0
  issue_numbers=()
  resume_requested=0
  resume_target=''
  take_over_lease=0

  if [[ "$CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT" -ne 0 ]]; then
    draft_pr=1
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --review-every)
        if [[ "$#" -lt 2 ]]; then
          fail '--review-every requires a value'
        fi
        review_every="$2"
        require_positive_integer_value '--review-every' "$review_every"
        shift 2
        ;;
      --batch-review-effort)
        if [[ "$#" -lt 2 ]]; then
          fail '--batch-review-effort requires a value'
        fi
        batch_review_effort="$2"
        require_nonempty_no_whitespace_value '--batch-review-effort' "$batch_review_effort"
        shift 2
        ;;
      --batch-fix-effort)
        if [[ "$#" -lt 2 ]]; then
          fail '--batch-fix-effort requires a value'
        fi
        batch_review_fix_effort="$2"
        batch_check_fix_effort="$2"
        require_nonempty_no_whitespace_value '--batch-fix-effort' "$2"
        shift 2
        ;;
      --auto-merge)
        auto_merge=1
        shift
        ;;
      --draft)
        draft_pr=1
        shift
        ;;
      --resume)
        [[ "$#" -ge 2 ]] || fail '--resume requires a run ID or current'
        [[ "$resume_requested" -eq 0 ]] || fail '--resume may be specified only once'
        resume_requested=1; resume_target="$2"; shift 2
        ;;
      --take-over-lease)
        take_over_lease=1; shift
        ;;
      --help)
        usage
        exit 0
        ;;
      --*)
        usage >&2
        exit 1
        ;;
      *)
        if [[ "$resume_requested" -eq 1 ]]; then fail '--resume does not accept Issue arguments'; fi
        require_numeric_issue_number "$1"
        issue_numbers+=("$1")
        shift
        ;;
    esac
  done

  require_positive_integer_value 'CODEX_FLOW_QUEUE_REVIEW_EVERY' "$review_every"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_REVIEW_REASONING' "$batch_review_effort"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_FIX_REASONING' "$batch_review_fix_effort"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_CHECK_FIX_REASONING' "$batch_check_fix_effort"

  if [[ "$resume_requested" -eq 1 ]]; then
    [[ "${#issue_numbers[@]}" -eq 0 ]] || fail '--resume does not accept Issue arguments'
    return 0
  fi
  [[ "$take_over_lease" -eq 0 ]] || fail '--take-over-lease is valid only with --resume'
  if [[ "${#issue_numbers[@]}" -eq 0 ]]; then
    usage >&2
    exit 1
  fi

  if [[ "$auto_merge" -eq 1 && "$draft_pr" -ne 0 ]]; then
    fail '--auto-merge cannot be used with a draft batch PR'
  fi
}

parse_queue_bootstrap_arguments() {
  local argument resume_count=0
  resume_requested=0
  resume_target=''
  take_over_lease=0

  for argument in "$@"; do
    [[ "$argument" == --resume ]] && resume_count=$((resume_count + 1))
  done
  [[ "$resume_count" -le 1 ]] || fail '--resume may be specified only once'
  [[ "$resume_count" -eq 1 ]] || return 0
  [[ "$#" -eq 2 || ( "$#" -eq 3 && " $* " == *' --take-over-lease '* ) ]] || \
    fail '--resume accepts only a run ID/current and optional --take-over-lease'
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --resume)
        [[ "$#" -ge 2 ]] || fail '--resume requires a run ID or current'
        resume_requested=1
        resume_target="$2"
        shift 2
        ;;
      --take-over-lease)
        take_over_lease=1
        shift
        ;;
      *) fail '--resume rejects queue-shaping options and Issue arguments' ;;
    esac
  done
  [[ "$resume_target" == current ]] || queue_state_require_token 'resume run ID' "$resume_target" || \
    fail "Invalid resume run ID: ${resume_target}"
}

ensure_unique_issues() {
  local issue_number
  local seen_file

  seen_file="$(mktemp)"
  trap 'rm -f "$seen_file"' RETURN

  for issue_number in "${issue_numbers[@]}"; do
    if grep -Fxq "$issue_number" "$seen_file"; then
      fail "Duplicate issue number in queue input: ${issue_number}"
    fi
    printf '%s\n' "$issue_number" >> "$seen_file"
  done

  trap - RETURN
  rm -f "$seen_file"
}

batch_count_for_queue() {
  local issue_count="$1"

  printf '%s\n' "$(((issue_count + review_every - 1) / review_every))"
}

batch_branch_name_for_range() {
  local first_issue="$1"
  local last_issue="$2"

  printf '%s%s-%s\n' "$CODEX_FLOW_BATCH_BRANCH_PREFIX" "$first_issue" "$last_issue"
}

batch_id_for_range() {
  local first_issue="$1"
  local last_issue="$2"

  printf 'batch-%s-%s\n' "$first_issue" "$last_issue"
}

join_issue_numbers() {
  local joined=''
  local issue_number

  for issue_number in "$@"; do
    if [[ -n "$joined" ]]; then
      joined="${joined},${issue_number}"
    else
      joined="$issue_number"
    fi
  done

  printf '%s\n' "$joined"
}

ensure_planned_batch_branches_available() {
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local branch_name
  local issue_count="${#issue_numbers[@]}"

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    branch_name="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
    ensure_issue_branch_available "$branch_name"
    start_index="$end_index"
  done
}

queue_host_identity() { hostname 2>/dev/null || uname -n; }

queue_process_start_identity() {
  local value
  value="$(awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf 'unavailable\n'
}

queue_process_group_identity() {
  local value
  value="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$value" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$value" || return 1
}

queue_owner_token() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

canonical_repository_identity() {
  local remote
  remote="$(git config --get remote.origin.url)" || fail 'Missing remote.origin.url'
  queue_state_canonical_repository_identity "$remote" || fail 'Cannot derive canonical repository identity from remote.origin.url'
}

queue_diagnostic_field() {
  local file="$1" key="$2"
  awk -F '\t' -v requested="$key" '$1 == requested { print $2; exit }' "$file" 2>/dev/null || true
}

queue_guard_busy_diagnostic() {
  local guard="$1" record='' owner_run='' owner_pid='' owner_host='' owner_generation='' owner_start=''
  local phase='' child_pid='' child_pgid='' child_start=''
  log_error "Queue serialization guard remained busy for 1 second: ${guard}"
  if [[ -d "${CODEX_FLOW_QUEUE_DIR}/lease.lock" ]]; then
    record="$(find "${CODEX_FLOW_QUEUE_DIR}/lease.lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort | head -n 1)"
  fi
  if [[ -n "$record" ]]; then
    owner_run="$(queue_diagnostic_field "$record" run_id)"
    owner_pid="$(queue_diagnostic_field "$record" owner_pid)"
    owner_host="$(queue_diagnostic_field "$record" owner_host)"
    owner_generation="$(queue_diagnostic_field "$record" lease_generation)"
    owner_start="$(queue_diagnostic_field "$record" process_start)"
    log_error "lease: run=${owner_run:-unknown} pid=${owner_pid:-unknown} host=${owner_host:-unknown} generation=${owner_generation:-unknown} process_start=${owner_start:-unknown}"
  fi
  if [[ -f "${ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE:-}" ]]; then
    phase="$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" phase)"
    child_pid="$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" child_pid)"
    child_pgid="$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" child_pgid)"
    child_start="$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" process_start)"
    log_error "active phase: ${phase:-unknown}; child PID=${child_pid:-unknown} PGID=${child_pgid:-unknown} process_start=${child_start:-unknown}"
  fi
  if [[ -n "$owner_run" ]]; then
    if [[ -n "$child_pgid" ]]; then
      log_error "safe recovery: wait for process group ${child_pgid} to exit (or terminate it with: kill -TERM -- -${child_pgid}), then run: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${owner_run}"
    else
      log_error "safe recovery: verify the recorded owner process has stopped, then run: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${owner_run}"
    fi
  else
    log_error 'safe recovery: wait for the recorded control-plane operation to finish; do not remove or replace the guard file'
  fi
}

initialize_queue_serialization_guard() {
  local git_common guard_dir guard guard_links
  git_common="$(git rev-parse --path-format=absolute --git-common-dir)" || fail 'Cannot resolve the Git common directory for queue serialization'
  [[ "$git_common" == /* && -d "$git_common" ]] || fail "Invalid Git common directory: ${git_common}"
  guard_dir="${git_common}/issue-forge/queue"
  if [[ -e "$guard_dir" && ( ! -d "$guard_dir" || -L "$guard_dir" ) ]]; then
    fail "Queue control directory is not the expected directory: ${guard_dir}"
  fi
  (umask 077; mkdir -p "$guard_dir") || fail "Cannot create queue control directory: ${guard_dir}"
  chmod 700 "$guard_dir" || fail "Cannot restrict queue control directory permissions: ${guard_dir}"
  guard="${guard_dir}/control.guard"
  if [[ -e "$guard" && ( ! -f "$guard" || -L "$guard" ) ]]; then
    fail "Queue serialization guard is not the expected regular file: ${guard}"
  fi
  if [[ ! -e "$guard" ]]; then
    (umask 077; : > "$guard") || fail "Cannot create queue serialization guard: ${guard}"
  fi
  chmod 600 "$guard" || fail "Cannot restrict queue serialization guard permissions: ${guard}"
  guard_links="$(stat -c '%h' -- "$guard" 2>/dev/null)" || fail "Cannot inspect queue serialization guard identity: ${guard}"
  [[ "$guard_links" == 1 ]] || fail "Queue serialization guard has unexpected hard-link count ${guard_links}: ${guard}"
  ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE="${guard_dir}/active-process.state"
  ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE="${guard_dir}/completion-cleanup.state"
  queue_state_require_singleton_path "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" optional || \
    fail "Invalid active queue process path: ${ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE}"
  queue_state_require_singleton_path "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" optional || \
    fail "Invalid completion cleanup path: ${ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE}"
  queue_state_configure_guard "$guard" queue_guard_busy_diagnostic || fail 'Cannot configure queue serialization guard'
}

reject_linked_worktree_queue_invocation() {
  local git_dir git_common_dir
  git_dir="$(git rev-parse --path-format=absolute --git-dir)" || fail 'Cannot resolve the Git directory for queue startup'
  git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)" || \
    fail 'Cannot resolve the Git common directory for queue startup'
  [[ "$git_dir" == /* && -d "$git_dir" ]] || fail "Invalid Git directory for queue startup: ${git_dir}"
  [[ "$git_common_dir" == /* && -d "$git_common_dir" ]] || \
    fail "Invalid Git common directory for queue startup: ${git_common_dir}"
  git_dir="$(cd "$git_dir" && pwd -P)" || fail "Cannot normalize Git directory for queue startup: ${git_dir}"
  git_common_dir="$(cd "$git_common_dir" && pwd -P)" || \
    fail "Cannot normalize Git common directory for queue startup: ${git_common_dir}"
  [[ "$git_dir" == "$git_common_dir" ]] || \
    fail 'Queue execution from a linked Git worktree is unsupported because queue ownership state is worktree-local; run from the primary worktree or use a separate clone'
}

print_resume_hint() {
  log_info "run ID: ${run_id}"
  log_info "resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${run_id}"
}

release_queue_lease() {
  local status=0
  [[ "${lease_owned:-0}" -eq 1 ]] || return 0
  queue_state_guard_enter || { log_error 'Cannot acquire queue serialization guard for lease release'; return 1; }
  if ! assert_queue_lease_owned; then
    log_error "Queue lease ownership was lost; refusing to delete replacement lease"
    lease_owned=0
    queue_state_guard_leave || true
    return 1
  fi
  queue_test_pause before_lease_release
  if [[ ! -f "${queue_lock}/owner.${lease_owner_token}.state" ]] || ! rm -- "${queue_lock}/owner.${lease_owner_token}.state"; then
    log_error 'Queue lease owner record disappeared during compare-and-delete'
    lease_owned=0
    queue_state_guard_leave || true
    return 1
  fi
  if ! rmdir -- "$queue_lock"; then
    log_error 'Queue lease changed during compare-and-delete; replacement was not deleted'
    lease_owned=0
    queue_state_guard_leave || true
    return 1
  fi
  lease_owned=0
  queue_state_set_owner_assertion ''
  queue_state_guard_leave || status=1
  return "$status"
}

assert_queue_lease_owned() {
  local record="${queue_lock}/owner.${lease_owner_token}.state" current_start entered=0 found
  local -A fields=()
  if [[ "$ISSUE_FORGE_INTERNAL_QUEUE_GUARD_DEPTH" -eq 0 ]]; then queue_state_guard_enter || return 1; entered=1; fi
  found="$(find "$queue_lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
  if [[ "${lease_owned:-0}" -ne 1 || ! -f "$record" || "$found" != "$record" ]] || \
     ! queue_state_parse_file "$record" lease fields || ! queue_state_validate_file "$record" lease; then
    log_error "Queue lease ownership lost for run ${run_id}"
    [[ "$entered" -eq 0 ]] || queue_state_guard_leave || true
    return 1
  fi
  current_start="$(queue_process_start_identity "$$")"
  if [[ "${fields[owner_token]}" != "$lease_owner_token" || "${fields[lease_generation]}" != "$lease_generation" || \
        "${fields[run_id]}" != "$run_id" || "${fields[owner_pid]}" != "$$" || "${fields[owner_host]}" != "$lease_owner_host" || \
        "${fields[process_start]}" == unavailable || "$current_start" == unavailable || "${fields[process_start]}" != "$current_start" || \
        "${record##*/}" != "owner.${fields[owner_token]}.state" ]]; then
    log_error "Queue lease fencing identity no longer matches run ${run_id}"
    [[ "$entered" -eq 0 ]] || queue_state_guard_leave || true
    return 1
  fi
  [[ "$entered" -eq 0 ]] || queue_state_guard_leave
}

record_abnormal_exit() {
  local status="$1" signal_name="${2:-}" current preserve_completed_lease=0
  trap - EXIT INT TERM
  terminate_controlled_process_tree || true
  if [[ "${run_initialized:-0}" -eq 1 && "${run_completed:-0}" -ne 1 ]]; then
    if [[ -f "${run_state_dir}/manifest.state" && -f "${run_state_dir}/run.state" ]] && \
       queue_state_validate_file "${run_state_dir}/manifest.state" manifest 2>/dev/null && \
       queue_state_validate_file "${run_state_dir}/run.state" run 2>/dev/null; then
      current="$(queue_state_read_field "${run_state_dir}/run.state" run state 2>/dev/null || true)"
      if [[ "$current" == completed ]]; then
        preserve_completed_lease=1
        log_error "Queue run ${run_id} completed its work; finalize control-plane cleanup with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${run_id}"
      elif [[ "$current" == running ]]; then
        if [[ -n "$signal_name" ]]; then
          queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" running interrupted || true
        else
          queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" running failed || true
        fi
        queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" run "${active_phase:-queue}" \
          "$([[ -n "$signal_name" ]] && printf interrupted || printf failed)" 2>/dev/null || true
        print_resume_hint >&2
      elif queue_state_enum_contains "$current" planned interrupted failed manual_review_required; then
        queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" run "${active_phase:-queue}" \
          "$([[ -n "$signal_name" ]] && printf interrupted || printf failed)" 2>/dev/null || true
        print_resume_hint >&2
      else
        log_error "Run ${run_id} has no valid recovery command for state ${current:-unknown}"
      fi
    else
      log_error "Run ${run_id} state disappeared or became invalid; no resume command can be advertised"
    fi
  fi
  if [[ "$preserve_completed_lease" -ne 1 ]]; then release_queue_lease || true; fi
  if [[ -n "$signal_name" ]]; then exit "$status"; fi
  exit "$status"
}

terminate_controlled_process_tree() {
  local attempt
  [[ "${controlled_child_active:-0}" -eq 1 ]] || return 0
  if [[ -f "${ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE:-}" ]] && \
     queue_state_validate_file "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" active_process 2>/dev/null; then
    active_phase="$(queue_state_read_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" active_process phase 2>/dev/null || printf '%s' "${active_phase:-startup}")"
  fi
  if [[ "${controlled_child_group_verified:-0}" -eq 1 && "${controlled_child_pgid:-}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "terminating controlled queue process group ${controlled_child_pgid} before releasing ownership"
    kill -TERM -- "-${controlled_child_pgid}" 2>/dev/null || true
  else
    log_error "terminating controlled queue child ${controlled_child_pid} before releasing ownership"
    kill -TERM "$controlled_child_pid" 2>/dev/null || true
  fi
  for ((attempt = 0; attempt < 200; attempt += 1)); do
    if [[ "${controlled_child_group_verified:-0}" -eq 1 && "${controlled_child_pgid:-}" =~ ^[1-9][0-9]*$ ]]; then
      kill -0 -- "-${controlled_child_pgid}" 2>/dev/null || break
    else
      kill -0 "$controlled_child_pid" 2>/dev/null || break
    fi
    sleep 0.01
  done
  if [[ "${controlled_child_group_verified:-0}" -eq 1 && "${controlled_child_pgid:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-${controlled_child_pgid}" 2>/dev/null; then
    kill -KILL -- "-${controlled_child_pgid}" 2>/dev/null || true
  elif kill -0 "$controlled_child_pid" 2>/dev/null; then
    kill -KILL "$controlled_child_pid" 2>/dev/null || true
  fi
  wait "${controlled_child_pid}" 2>/dev/null || true
  if [[ -f "${controlled_worker_result:-}" ]] && validate_controlled_worker_identity_file "$controlled_worker_result" worker_result 2>/dev/null; then
    active_phase="$(queue_state_read_field "$controlled_worker_result" worker_result phase 2>/dev/null || printf '%s' "${active_phase:-startup}")"
  fi
  controlled_child_active=0
  rm -f -- "${controlled_worker_registration:-}" "${controlled_worker_authorization:-}" "${controlled_worker_result:-}" \
    "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" || true
}

install_queue_traps() {
  trap 'record_abnormal_exit $? ' EXIT
  trap 'record_abnormal_exit 130 INT' INT
  trap 'record_abnormal_exit 143 TERM' TERM
}

reconcile_active_process_record_under_guard() {
  local file="$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" child_pid child_pgid child_start recorded_start recorded_run
  queue_state_require_singleton_path "$file" optional || fail "Invalid active queue process path: ${file}"
  [[ -e "$file" ]] || return 0
  queue_state_validate_file "$file" active_process || fail "Invalid active queue process record: ${file}"
  recorded_run="$(queue_state_read_field "$file" active_process run_id)"
  child_pid="$(queue_state_read_field "$file" active_process child_pid)"
  child_pgid="$(queue_state_read_field "$file" active_process child_pgid)"
  recorded_start="$(queue_state_read_field "$file" active_process process_start)"
  child_start="$(queue_process_start_identity "$child_pid")"
  if [[ "$child_start" != unavailable && "$child_start" == "$recorded_start" ]] || kill -0 -- "-${child_pgid}" 2>/dev/null; then
    fail "Queue run ${recorded_run} still has active process PID ${child_pid} PGID ${child_pgid} start ${recorded_start}; wait for it to exit before recovery"
  fi
  log_info "removing stale active-process record for stopped run ${recorded_run}"
  rm -- "$file" || fail "Cannot remove stale active-process record: ${file}"
}

acquire_queue_lease() {
  local owner_host owner_pid owner_run owner_token owner_generation owner_start local_host local_start record audit found owner_status
  local cleanup_run
  local -A owner_fields=() cleanup_fields=()
  mkdir -p "$CODEX_FLOW_QUEUE_DIR"; queue_lock="${CODEX_FLOW_QUEUE_DIR}/lease.lock"; local_host="$(queue_host_identity)"
  lease_owner_token="$(queue_owner_token)"; lease_owner_host="$local_host"; local_start="$(queue_process_start_identity "$$")"; lease_generation=1
  [[ "$local_start" != unavailable ]] || fail 'Cannot establish local process-start identity; queue lease acquisition is unverifiable'
  queue_test_barrier lease_acquire
  queue_state_guard_enter || fail 'Cannot acquire queue serialization guard'
  queue_state_require_singleton_path "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" optional || {
    queue_state_guard_leave || true
    fail "Invalid completion cleanup marker: ${ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE}"
  }
  if [[ -e "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" ]]; then
    if ! queue_state_parse_file "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" completion_cleanup cleanup_fields || \
       ! queue_state_validate_file "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" completion_cleanup; then
      queue_state_guard_leave || true
      fail "Invalid completion cleanup marker: ${ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE}"
    fi
    cleanup_run="${cleanup_fields[run_id]}"
    if [[ "$resume_requested" -eq 0 ]]; then discard_preflight_run; fi
    queue_state_guard_leave || true
    fail "Completed-run cleanup for ${cleanup_run} is pending; finish it with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${cleanup_run}"
  fi
  reconcile_active_process_record_under_guard
  if [[ -e "${CODEX_FLOW_QUEUE_DIR}/lease.state" ]]; then
    queue_state_guard_leave || true
    fail 'Unsupported legacy queue lease schema/path .work/queue/lease.state; manual migration is required'
  fi
  if [[ -d "$queue_lock" ]]; then
    found="$(find "$queue_lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
    if [[ -z "$found" ]]; then
      log_info 'recovering incomplete empty queue lease claim'
      rmdir -- "$queue_lock" || { queue_state_guard_leave || true; fail "Incomplete lease claim is not empty: ${queue_lock}"; }
    elif [[ "$found" == *$'\n'* ]]; then
      queue_state_guard_leave || true
      fail "Invalid queue lease has multiple owner records: ${queue_lock}"
    else
      record="$found"
      if ! queue_state_parse_file "$record" lease owner_fields || ! queue_state_validate_file "$record" lease || \
         [[ "${record##*/}" != "owner.${owner_fields[owner_token]}.state" ]]; then
        queue_state_guard_leave || true
        fail "Invalid queue lease owner identity: ${queue_lock}"
      fi
      owner_run="${owner_fields[run_id]}"; owner_host="${owner_fields[owner_host]}"; owner_pid="${owner_fields[owner_pid]}"
      owner_token="${owner_fields[owner_token]}"; owner_generation="${owner_fields[lease_generation]}"; owner_start="${owner_fields[process_start]}"
      queue_test_pause after_displaced_lease_read
    fi
  elif [[ -e "$queue_lock" ]]; then
    queue_state_guard_leave || true
    fail "Invalid queue lease path is not a directory: ${queue_lock}"
  fi
  if [[ -n "${owner_run:-}" ]]; then
    if [[ "$resume_requested" -ne 1 || "$owner_run" != "$run_id" ]]; then
      log_error "Queue lease records unfinished run ${owner_run}; resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${owner_run}"
      if [[ "$resume_requested" -eq 0 ]]; then discard_preflight_run; fi
      queue_state_guard_leave || true
      fail "Queue lease run ${owner_run} conflicts with requested run ${run_id}"
    fi
    if [[ "$owner_host" == "$local_host" ]]; then
      owner_status=unverifiable
      if kill -0 "$owner_pid" 2>/dev/null; then
        if [[ "$owner_start" != unavailable && "$(queue_process_start_identity "$owner_pid")" == "$owner_start" ]]; then owner_status=live; fi
      elif [[ -d /proc && ! -e "/proc/${owner_pid}" ]]; then
        owner_status=dead
      elif [[ -e "/proc/${owner_pid}" ]]; then
        owner_status=live
      fi
      if [[ "$owner_status" == live ]]; then
        queue_state_guard_leave || true
        fail "Queue run is leased by live same-host PID ${owner_pid} on ${owner_host}"
      fi
      if [[ "$owner_status" != dead && "$take_over_lease" -ne 1 ]]; then
        queue_state_guard_leave || true
        fail "Queue lease owner PID ${owner_pid} on ${owner_host} is unverifiable; resume with --take-over-lease only after asserting it stopped"
      fi
      log_info "recovering dead same-host lease for explicit resume ${run_id}"
    elif [[ "$take_over_lease" -ne 1 ]]; then
      queue_state_guard_leave || true
      fail "Queue lease belongs to different or unverifiable host ${owner_host}; resume ${run_id} with --take-over-lease"
    else
      log_info "explicitly taking over lease from host ${owner_host}; operator asserts the old process has stopped"
    fi
    lease_generation=$((owner_generation + 1)); audit="${CODEX_FLOW_QUEUE_DIR}/lease.displaced.${owner_generation}.${owner_token}"
    [[ ! -e "$audit" ]] || { queue_state_guard_leave || true; fail "Lease audit destination already exists: ${audit}"; }
    mv -T -- "$queue_lock" "$audit" || { queue_state_guard_leave || true; fail 'Queue lease displacement failed'; }
  fi
  mkdir "$queue_lock" || { queue_state_guard_leave || true; fail 'Queue lease claim publication failed'; }
  queue_failpoint after_exclusive_claim_before_owner_record
  record="${queue_lock}/owner.${lease_owner_token}.state"
  if ! queue_state_write_lease "$record" "$run_id" "$lease_owner_token" "$lease_generation" "$$" "$local_host" "$local_start" \
    "${owner_run:-none}" "${owner_token:-none}" "${owner_generation:-none}"; then
    queue_state_guard_leave || true
    fail 'Queue lease owner-record publication failed'
  fi
  lease_owned=1; queue_state_set_owner_assertion assert_queue_lease_owned
  queue_failpoint after_complete_owner_publication
  queue_state_guard_leave || fail 'Cannot release queue serialization guard after lease acquisition'
}

discard_preflight_run() {
  run_initialized=0
  rm -rf -- "${run_state_dir}/batches" || return 1
  rm -f -- "${run_state_dir}/manifest.state" "${run_state_dir}/run.state" "${run_state_dir}/checkpoint.state" || return 1
  rmdir -- "$run_state_dir" || return 1
}

initialize_queue_run_minimal() {
  local ordered
  run_state_dir="${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}"
  ordered="$(join_issue_numbers "${issue_numbers[@]}")"
  mkdir -p "$run_state_dir"
  queue_state_create_manifest "$run_state_dir" "$run_id" "$ordered" "$review_every" "$draft_pr" "$auto_merge" \
    "$([[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -eq 0 ]] && printf 0 || printf 1)" "$batch_review_effort" "$batch_review_fix_effort" \
    "$batch_check_fix_effort" "$CODEX_FLOW_BATCH_BRANCH_PREFIX" "$CODEX_FLOW_BASE_BRANCH" "$CODEX_FLOW_BASE_REF" "$(canonical_repository_identity)"
  queue_state_create_run "${run_state_dir}/run.state" "$run_id" planned
  initialize_queue_run_entities
  run_initialized=1
  queue_test_pause after_minimal_run_publication
  queue_failpoint after_minimal_run_publication
}

complete_queue_run_initialization() {
  reconcile_current_pointer
  validate_queue_run_graph
  queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" planned running
}

validate_initial_entity() {
  local file="$1" schema="$2" label="$3"; shift 3
  local pair key expected actual
  queue_state_validate_file "$file" "$schema" || fail "Invalid existing ${label}: ${file}"
  for pair in "$@"; do key="${pair%%=*}"; expected="${pair#*=}"
    actual="$(queue_state_read_field "$file" "$schema" "$key")"
    [[ "$actual" == "$expected" ]] || fail "Immutable ${label} field ${key} differs in ${file}: expected ${expected}, found ${actual}"
  done
}

initialize_queue_run_entities() {
  local start=0 end first last batch_id branch state_dir artifact index batch_file issue_file
  while [[ "$start" -lt "${#issue_numbers[@]}" ]]; do
    end=$((start + review_every)); [[ "$end" -le "${#issue_numbers[@]}" ]] || end="${#issue_numbers[@]}"
    first="${issue_numbers[$start]}"; last="${issue_numbers[$((end - 1))]}"
    batch_id="$(batch_id_for_range "$first" "$last")"; branch="$(batch_branch_name_for_range "$first" "$last")"
    state_dir="${run_state_dir}/batches/${batch_id}"; artifact="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    batch_file="${state_dir}/batch.state"
    [[ ! -e "$batch_file" ]] || fail "Fresh queue entity already exists: ${batch_file}"
    queue_state_create_batch "$batch_file" "$run_id" "$batch_id" "$first" "$last" "$branch" "$artifact"
    mkdir -p "${state_dir}/issues"
    for ((index = start; index < end; index += 1)); do
      issue_file="${state_dir}/issues/${issue_numbers[$index]}.state"
      [[ ! -e "$issue_file" ]] || fail "Fresh queue entity already exists: ${issue_file}"
      queue_state_create_issue "$issue_file" "$run_id" "$batch_id" "${issue_numbers[$index]}"
    done
    start="$end"
  done
}

validate_queue_run_graph() {
  local start=0 end first last batch_id branch state_dir artifact index batch_file issue_file entry name issue state commit context_path archive_path
  local batches_root="${run_state_dir}/batches"
  local -A expected_batches=() expected_issues=()
  [[ -d "$batches_root" && ! -L "$batches_root" ]] || fail "Missing authoritative batch graph for run ${run_id}: ${batches_root}"
  while [[ "$start" -lt "${#issue_numbers[@]}" ]]; do
    end=$((start + review_every)); [[ "$end" -le "${#issue_numbers[@]}" ]] || end="${#issue_numbers[@]}"
    first="${issue_numbers[$start]}"; last="${issue_numbers[$((end - 1))]}"
    batch_id="$(batch_id_for_range "$first" "$last")"; branch="$(batch_branch_name_for_range "$first" "$last")"
    expected_batches["$batch_id"]=1
    state_dir="${batches_root}/${batch_id}"; artifact="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "Missing authoritative batch entity ${batch_id} for run ${run_id}"
    batch_file="${state_dir}/batch.state"
    validate_initial_entity "$batch_file" batch "batch ${batch_id}" "run_id=${run_id}" "batch_id=${batch_id}" "first_issue=${first}" "last_issue=${last}" "branch=${branch}" "artifact_path=${artifact}"
    [[ -d "${state_dir}/issues" && ! -L "${state_dir}/issues" ]] || fail "Missing authoritative Issue graph for batch ${batch_id}"
    expected_issues=()
    for ((index = start; index < end; index += 1)); do
      issue="${issue_numbers[$index]}"; expected_issues["${issue}.state"]=1
      issue_file="${state_dir}/issues/${issue}.state"
      validate_initial_entity "$issue_file" issue "Issue ${issue}" "run_id=${run_id}" "batch_id=${batch_id}" "issue_number=${issue}"
      context_path="$(queue_state_read_field "$issue_file" issue context_path)"
      [[ "$context_path" == none || "$context_path" == ".work/queue/runs/${run_id}/contexts/${batch_id}/issues/${issue}.md" ]] || \
        fail "Issue ${issue} context identity does not match the immutable manifest graph"
      commit="$(queue_state_read_field "$issue_file" issue commit_sha)"
      archive_path="$(queue_state_read_field "$issue_file" issue artifact_path)"
      [[ "$archive_path" == none || ( "$commit" != none && "$archive_path" == ".work/queue/runs/${run_id}/archives/${batch_id}/issues/${issue}/${commit}" ) ]] || \
        fail "Issue ${issue} archive identity does not match the immutable manifest graph"
    done
    while IFS= read -r entry; do
      name="${entry##*/}"
      [[ -n "${expected_issues[$name]:-}" && -f "$entry" && ! -L "$entry" ]] || fail "Unexpected authoritative Issue entity in ${batch_id}: ${name}"
    done < <(find "${state_dir}/issues" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
    state="$(queue_state_read_field "$batch_file" batch state)"
    if [[ "$state" == completed ]]; then
      for ((index = start; index < end; index += 1)); do
        [[ "$(queue_state_read_field "${state_dir}/issues/${issue_numbers[$index]}.state" issue state)" == acknowledged ]] || \
          fail "Completed batch ${batch_id} contains non-acknowledged Issue ${issue_numbers[$index]}"
      done
    fi
    start="$end"
  done
  while IFS= read -r entry; do
    name="${entry##*/}"
    [[ -n "${expected_batches[$name]:-}" && -d "$entry" && ! -L "$entry" ]] || fail "Unexpected authoritative batch entity for run ${run_id}: ${name}"
  done < <(find "$batches_root" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
}

reconcile_current_pointer() {
  local pointer="${CODEX_FLOW_QUEUE_DIR}/current" pointed state
  if [[ -f "$pointer" ]]; then
    queue_state_validate_file "$pointer" pointer || fail "Invalid current queue pointer: ${pointer}"
    pointed="$(queue_state_read_field "$pointer" pointer run_id)"
    if [[ "$pointed" != "$run_id" ]]; then
      [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed}/run.state" ]] || fail "Current pointer names unknown run ${pointed}"
      state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed}/run.state" run state)"
      [[ "$state" == completed ]] || fail "Current pointer names conflicting nonterminal run ${pointed}"
      queue_state_remove_pointer_if_matches "$pointer" "$pointed"
    fi
  fi
  queue_state_publish_pointer "$pointer" "$run_id" "$lease_owner_token" "$lease_generation"
}

reconcile_interrupted_inner_phase() {
  local existing_run_state="$1" checkpoint="${run_state_dir}/checkpoint.state" phase status dirty report temporary
  [[ "$existing_run_state" == running || "$existing_run_state" == interrupted || "$existing_run_state" == failed || "$existing_run_state" == manual_review_required ]] || return 0
  [[ -f "$checkpoint" ]] || return 0
  queue_state_validate_file "$checkpoint" checkpoint || fail "Invalid recovery checkpoint for run ${run_id}"
  phase="$(queue_state_read_field "$checkpoint" checkpoint phase)"; status="$(queue_state_read_field "$checkpoint" checkpoint status)"
  [[ "$status" == before || "$status" == interrupted || "$status" == failed ]] || return 0
  case "$phase" in issue_flow|batch_checks|batch_review) ;; *) return 0 ;; esac
  dirty="$(status_outside_work)"
  [[ -n "$dirty" ]] || return 0
  report="${run_state_dir}/manual-review.txt"; temporary="$(mktemp "${run_state_dir}/.manual-review.tmp.XXXXXX")"
  {
    printf 'schema_version\t%s\nrun_id\t%s\nphase\t%s\n' "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" "$run_id" "$phase"
    printf 'dirty_paths_begin\n%s\ndirty_paths_end\n' "$dirty"
  } > "$temporary"
  mv -T -f -- "$temporary" "$report"
  if [[ "$existing_run_state" != manual_review_required ]]; then
    queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" "$existing_run_state" manual_review_required
  fi
  log_error "Dirty interrupted inner phase requires manual review: run=${run_id} phase=${phase}"
  log_error "Dirty paths were preserved exactly in ${report}:"
  printf '%s\n' "$dirty" >&2
  log_error "Recovery: inspect and finish or revert these paths, make the consumer worktree clean, then run: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${run_id}"
  fail "Refusing to silently replay dirty interrupted phase ${phase}"
}

load_queue_run_state() {
  local manifest="${run_state_dir}/manifest.state" issue_csv manifest_base_branch manifest_base_ref existing_run_state
  local -A manifest_fields=()
  queue_state_parse_file "$manifest" manifest manifest_fields; queue_state_validate_file "$manifest" manifest
  [[ "${manifest_fields[run_id]}" == "$run_id" ]] || fail "Manifest run ID mismatch for ${run_id}"
  manifest_base_branch="${manifest_fields[base_branch]}"; manifest_base_ref="${manifest_fields[base_ref]}"
  [[ "$manifest_base_branch" == "$CODEX_FLOW_BASE_BRANCH" && "$manifest_base_ref" == "$CODEX_FLOW_BASE_REF" ]] || \
    fail "Resume repository configuration mismatch: manifest uses ${manifest_base_branch}/${manifest_base_ref}, current config uses ${CODEX_FLOW_BASE_BRANCH}/${CODEX_FLOW_BASE_REF}"
  [[ "${manifest_fields[repository_identity]}" == "$(canonical_repository_identity)" ]] || fail 'Resume repository identity does not match the immutable manifest'
  issue_csv="${manifest_fields[issues]}"; IFS=',' read -r -a issue_numbers <<< "$issue_csv"
  review_every="${manifest_fields[review_every]}"; draft_pr="${manifest_fields[draft_pr]}"; auto_merge="${manifest_fields[auto_merge]}"
  batch_review_effort="${manifest_fields[batch_review_reasoning]}"; batch_review_fix_effort="${manifest_fields[batch_fix_reasoning]}"
  batch_check_fix_effort="${manifest_fields[batch_check_fix_reasoning]}"
  CODEX_FLOW_BATCH_BRANCH_PREFIX="${manifest_fields[batch_branch_prefix]}"
  CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW="${manifest_fields[light_issue_review]}"
  run_initialized=1
  existing_run_state="$(queue_state_read_field "${run_state_dir}/run.state" run state)"
  [[ "$existing_run_state" != completed ]] || fail "Queue run ${run_id} is already completed"
  validate_queue_run_graph
  reconcile_interrupted_inner_phase "$existing_run_state"
  reconcile_current_pointer
  case "$existing_run_state" in
    running) ;;
    interrupted|failed|manual_review_required)
      queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" "$(queue_state_read_field "${run_state_dir}/run.state" run state)" running ;;
    planned) queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" planned running ;;
    *) fail "Queue run ${run_id} is not resumable" ;;
  esac
}

validate_durable_issue_context() {
  local path="$1" issue_number="$2" expected_hash="${3:-}" actual_hash
  [[ -f "$path" && ! -L "$path" ]] || fail "Durable Issue ${issue_number} context is not a regular file: ${path}"
  grep -Fqx "# Issue #${issue_number}" "$path" || fail "Durable Issue ${issue_number} context has the wrong Issue identity"
  grep -Fq 'Title: ' "$path" || fail "Durable Issue ${issue_number} context lacks a title"
  grep -Fq 'URL: ' "$path" || fail "Durable Issue ${issue_number} context lacks a URL"
  actual_hash="$(sha256sum "$path" | awk '{print $1}')"
  [[ -z "$expected_hash" || "$expected_hash" == none || "$actual_hash" == "$expected_hash" ]] || fail "Durable Issue ${issue_number} context content changed"
  printf '%s\n' "$actual_hash"
}

publish_durable_issue_context() {
  local source="$1" destination="$2" issue_number="$3" directory temporary hash
  directory="$(dirname "$destination")"; mkdir -p "$directory"
  [[ ! -e "$destination" ]] || fail "Durable Issue context destination already exists without recorded identity: ${destination}"
  temporary="$(mktemp "${directory}/.issue-context.tmp.XXXXXX")"
  cp -- "$source" "$temporary"
  hash="$(validate_durable_issue_context "$temporary" "$issue_number")"
  mv -T -- "$temporary" "$destination"
  printf '%s\n' "$hash"
}

rebuild_batch_issues_file() {
  local batch_id="$1" start_index="$2" end_index="$3" issues_file="$4" directory temporary index issue state_file context_path context_hash
  directory="$(dirname "$issues_file")"; mkdir -p "$directory"
  temporary="$(mktemp "${directory}/.issues.txt.tmp.XXXXXX")"
  for ((index = start_index; index < end_index; index += 1)); do
    issue="${issue_numbers[$index]}"; state_file="${run_state_dir}/batches/${batch_id}/issues/${issue}.state"
    context_path="$(queue_state_read_field "$state_file" issue context_path)"; context_hash="$(queue_state_read_field "$state_file" issue context_sha256)"
    [[ "$context_path" != none && "$context_hash" != none ]] || { rm -f "$temporary"; fail "Issue ${issue} lacks complete durable context identity"; }
    validate_durable_issue_context "${CODEX_FLOW_REPO_ROOT}/${context_path}" "$issue" "$context_hash" >/dev/null
    {
      printf '## Issue #%s\n\n' "$issue"
      cat "${CODEX_FLOW_REPO_ROOT}/${context_path}"
      printf '\n'
    } >> "$temporary"
  done
  mv -T -f -- "$temporary" "$issues_file"
}

generate_issue_archive_manifest() {
  local root="$1" output="$2" issue_number="$3" batch_id="$4" commit_sha="$5" path relative hash
  [[ -d "${root}/codex" && ! -L "${root}/codex" ]] || return 1
  if find "${root}/codex" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then return 1; fi
  {
    printf 'archive_schema_version\t1\nrun_id\t%s\nbatch_id\t%s\nissue_number\t%s\ncommit_sha\t%s\n' "$run_id" "$batch_id" "$issue_number" "$commit_sha"
    while IFS= read -r path; do
      relative="${path#"${root}"/}"
      [[ "$relative" != *$'\t'* && "$relative" != *$'\n'* ]] || return 1
      if [[ -d "$path" ]]; then
        printf 'content_directory\t%s\n' "$relative"
      else
        hash="$(sha256sum "$path" | awk '{print $1}')" || return 1
        printf 'content_sha256\t%s\t%s\n' "$hash" "$relative"
      fi
    done < <(find "${root}/codex" -mindepth 1 -print | LC_ALL=C sort)
  } > "$output"
}

validate_issue_archive() {
  local destination="$1" issue_number="$2" batch_id="$3" commit_sha="$4" expected_manifest_hash="${5:-none}" source="${6:-}" generated manifest_hash source_root source_manifest
  [[ -d "$destination" && ! -L "$destination" ]] || fail "Authoritative archive is missing for Issue ${issue_number}: ${destination}"
  [[ -f "${destination}/archive.manifest" && ! -L "${destination}/archive.manifest" ]] || fail "Authoritative archive manifest is missing for Issue ${issue_number}"
  [[ "$(find "$destination" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == $'archive.manifest\ncodex' ]] || fail "Authoritative archive has unexpected top-level content for Issue ${issue_number}"
  generated="$(mktemp)"
  generate_issue_archive_manifest "$destination" "$generated" "$issue_number" "$batch_id" "$commit_sha" || { rm -f "$generated"; fail "Authoritative archive contains unsupported content for Issue ${issue_number}"; }
  cmp -s "$generated" "${destination}/archive.manifest" || { rm -f "$generated"; fail "Authoritative archive content manifest does not match Issue ${issue_number}"; }
  if [[ -n "$source" && -d "$source" ]]; then
    source_root="$(mktemp -d)"; mkdir "${source_root}/codex"; cp -R -- "${source}/." "${source_root}/codex/"
    source_manifest="$(mktemp)"
    generate_issue_archive_manifest "$source_root" "$source_manifest" "$issue_number" "$batch_id" "$commit_sha" || { rm -rf "$source_root"; rm -f "$source_manifest" "$generated"; fail "Current Codex artifacts contain unsupported content for Issue ${issue_number}"; }
    cmp -s "$source_manifest" "$generated" || { rm -rf "$source_root"; rm -f "$source_manifest" "$generated"; fail "Existing archive content differs from current Issue ${issue_number} artifacts"; }
    rm -rf "$source_root"; rm -f "$source_manifest"
  fi
  rm -f "$generated"
  manifest_hash="$(sha256sum "${destination}/archive.manifest" | awk '{print $1}')"
  [[ "$expected_manifest_hash" == none || "$manifest_hash" == "$expected_manifest_hash" ]] || fail "Authoritative archive identity changed for Issue ${issue_number}"
  printf '%s\n' "$manifest_hash"
}

publish_issue_archive() {
  local destination="$1" issue_number="$2" batch_id="$3" commit_sha="$4" parent temporary manifest_hash
  [[ -d "$CODEX_FLOW_CODEX_DIR" ]] || fail "Missing Codex artifact directory after Issue ${issue_number}: ${CODEX_FLOW_CODEX_DIR}"
  parent="$(dirname "$destination")"; mkdir -p "$parent"
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name '.archive.tmp.*' -exec rm -rf -- {} +
  if [[ -e "$destination" ]]; then
    validate_issue_archive "$destination" "$issue_number" "$batch_id" "$commit_sha" none "$CODEX_FLOW_CODEX_DIR"
    return
  fi
  temporary="$(mktemp -d "${parent}/.archive.tmp.XXXXXX")"
  mkdir "${temporary}/codex"; cp -R -- "${CODEX_FLOW_CODEX_DIR}/." "${temporary}/codex/"
  queue_failpoint during_artifact_archive_copy
  generate_issue_archive_manifest "$temporary" "${temporary}/archive.manifest" "$issue_number" "$batch_id" "$commit_sha" || fail "Cannot build complete archive manifest for Issue ${issue_number}"
  validate_issue_archive "$temporary" "$issue_number" "$batch_id" "$commit_sha" none "$CODEX_FLOW_CODEX_DIR" >/dev/null
  mv -T -- "$temporary" "$destination"
  queue_failpoint after_artifact_archive_publication
  manifest_hash="$(validate_issue_archive "$destination" "$issue_number" "$batch_id" "$commit_sha" none "$CODEX_FLOW_CODEX_DIR")"
  printf '%s\n' "$manifest_hash"
}

publish_compatibility_archive_view() {
  local authoritative="$1" compatibility="$2"
  mkdir -p "$(dirname "$compatibility")"
  rm -rf -- "$compatibility"
  cp -R -- "${authoritative}/codex" "$compatibility"
}

validate_batch_branch_ref() {
  local branch_name="$1" expected_head="$2" boundary="$3" local_head remote_line remote_head
  git show-ref --verify --quiet "refs/heads/${branch_name}" || fail "Missing expected batch branch ${branch_name} at ${boundary}"
  local_head="$(git rev-parse --verify "refs/heads/${branch_name}^{commit}")"
  [[ "$local_head" == "$expected_head" ]] || fail "Batch branch ${branch_name} HEAD ${local_head} does not match saved ${boundary} SHA ${expected_head}"
  remote_line="$(git ls-remote --heads origin "refs/heads/${branch_name}" 2>/dev/null || true)"
  if [[ -n "$remote_line" ]]; then
    [[ "$(printf '%s\n' "$remote_line" | wc -l)" -eq 1 ]] || fail "Remote batch branch ${branch_name} is ambiguous"
    remote_head="${remote_line%%[[:space:]]*}"
    [[ "$remote_head" == "$expected_head" ]] || fail "Local/remote disagreement for batch branch ${branch_name}: local ${local_head}, remote ${remote_head}, saved ${expected_head}"
  fi
}

prepare_batch_branch() {
  local branch_name="$1" batch_id="$2" batch_state_file="$3" state="$4" saved_base resolved_base remote_line
  if [[ "$state" == planned ]]; then
    log_info "fetching origin/${CODEX_FLOW_BASE_BRANCH}"
    git fetch origin "$CODEX_FLOW_BASE_BRANCH"
    require_flow_base_ref
    resolved_base="$(git rev-parse --verify "${CODEX_FLOW_BASE_REF}^{commit}")"
    queue_state_update_batch "$batch_state_file" "$batch_id" planned base_resolved "$resolved_base"
    state=base_resolved
  fi
  saved_base="$(queue_state_read_field "$batch_state_file" batch base_commit)"
  [[ "$saved_base" != none ]] || fail "Batch ${batch_id} lacks its saved intended base"
  git cat-file -e "${saved_base}^{commit}" || fail "Saved batch base does not resolve to a commit: ${saved_base}"
  if [[ "$state" == base_resolved ]]; then
    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
      validate_batch_branch_ref "$branch_name" "$saved_base" 'branch-ready boundary'
      git switch "$branch_name"
    else
      remote_line="$(git ls-remote --heads origin "refs/heads/${branch_name}" 2>/dev/null || true)"
      [[ -z "$remote_line" ]] || fail "Remote branch ${branch_name} exists before its saved local branch-ready boundary"
      log_info "creating batch branch ${branch_name} from saved base ${saved_base}"
      git switch --create "$branch_name" "$saved_base"
    fi
    queue_failpoint after_batch_branch_creation
    validate_batch_branch_ref "$branch_name" "$saved_base" 'branch-ready boundary'
    queue_state_transition "$batch_state_file" batch "$batch_id" base_resolved branch_ready
  fi
}

validate_exact_issue_commit() {
  local issue_number="$1" batch_branch="$2" issue_base="$3" commit_sha="$4" commit_token parent extra count subject
  [[ "$(git branch --show-current)" == "$batch_branch" ]] || fail "Issue ${issue_number} is not on expected branch ${batch_branch}"
  git cat-file -e "${issue_base}^{commit}" || fail "Saved Issue ${issue_number} base is not a commit: ${issue_base}"
  git cat-file -e "${commit_sha}^{commit}" || fail "Saved Issue ${issue_number} commit is not a commit: ${commit_sha}"
  read -r commit_token parent extra <<< "$(git rev-list --parents -n 1 "$commit_sha")"
  [[ "$commit_token" == "$commit_sha" && -n "$parent" && -z "${extra:-}" ]] || fail "Issue ${issue_number} commit must have exactly one parent"
  [[ "$parent" == "$issue_base" ]] || fail "Issue ${issue_number} commit parent ${parent} does not equal saved base ${issue_base}"
  count="$(git rev-list --count "${issue_base}..${commit_sha}")"
  [[ "$count" == 1 ]] || fail "Issue ${issue_number} commit range must contain exactly one commit, found ${count}"
  git merge-base --is-ancestor "$commit_sha" "refs/heads/${batch_branch}" || fail "Issue ${issue_number} commit is not reachable from expected branch ${batch_branch}"
  subject="$(git show -s --format=%s "$commit_sha")"
  [[ "$subject" == "chore: address issue #${issue_number}" ]] || fail "Issue ${issue_number} commit subject is not deterministic: ${subject}"
  ensure_clean_worktree "Issue ${issue_number} commit validation requires a clean consumer worktree."
}

process_issue_on_batch_branch() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issues_file="$4"
  local issue_file
  local issue_base_commit
  local issue_light_review=0
  local issue_state_file="${run_state_dir}/batches/${current_batch_id}/issues/${issue_number}.state"
  local issue_state commit_sha recorded_sha artifact_rel destination context_rel context_path context_hash archive_hash compatibility

  assert_queue_lease_owned || fail "Queue lease lost before Issue ${issue_number}"
  issue_state="$(queue_state_read_field "$issue_state_file" issue state)"
  ensure_clean_worktree "Working tree must be clean before processing issue ${issue_number}."

  if [[ "$issue_state" == planned ]]; then
    rm -f -- "$(issue_file_path "$issue_number")"
    context_rel=".work/queue/runs/${run_id}/contexts/${current_batch_id}/issues/${issue_number}.md"
    queue_state_lease_issue "$issue_state_file" "Issue ${issue_number}" "$context_rel"
    issue_state=leased
  fi

  context_rel="$(queue_state_read_field "$issue_state_file" issue context_path)"
  context_path="${CODEX_FLOW_REPO_ROOT}/${context_rel}"
  context_hash="$(queue_state_read_field "$issue_state_file" issue context_sha256)"
  if [[ "$issue_state" == leased ]]; then
    queue_set_active_phase issue_context_fetch; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_context_fetch before
    if [[ "$context_hash" != none ]]; then
      validate_durable_issue_context "$context_path" "$issue_number" "$context_hash" >/dev/null
      log_info "reconciled existing durable Issue ${issue_number} context without refetching"
    else
      if [[ -e "$context_path" ]]; then
        context_hash="$(validate_durable_issue_context "$context_path" "$issue_number")"
        log_info "reconciled existing durable Issue ${issue_number} context without refetching; adopted complete run-owned publication"
      else
        queue_failpoint fail_issue_context_fetch
        if [[ ! -f "$(issue_file_path "$issue_number")" ]]; then
          log_info "fetching issue ${issue_number}"
          write_issue_context_file "$issue_number"
        fi
        validate_durable_issue_context "$(issue_file_path "$issue_number")" "$issue_number" >/dev/null
        context_hash="$(publish_durable_issue_context "$(issue_file_path "$issue_number")" "$context_path" "$issue_number")"
      fi
      queue_state_set_issue_context "$issue_state_file" "$context_rel" "$context_hash"
    fi
    cp -- "$context_path" "$(issue_file_path "$issue_number")"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_context_fetch after
  else
    [[ "$context_hash" != none ]] || fail "Issue ${issue_number} state ${issue_state} lacks context identity"
    validate_durable_issue_context "$context_path" "$issue_number" "$context_hash" >/dev/null
    cp -- "$context_path" "$(issue_file_path "$issue_number")"
  fi
  issue_file="$(require_issue_file "$issue_number")"

  issue_base_commit="$(queue_state_read_field "$issue_state_file" issue base_commit)"
  if [[ "$issue_base_commit" == none ]]; then
    issue_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
    queue_state_set_issue_base "$issue_state_file" leased "$issue_base_commit"
  fi
  queue_set_active_phase issue_bootstrap; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_bootstrap before
  write_current_issue_branch_state "$issue_number" "$batch_branch" "$issue_base_commit"
  queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_bootstrap after

  if [[ "$issue_state" == leased ]]; then queue_state_transition "$issue_state_file" issue "Issue ${issue_number}" leased running; issue_state=running; fi

  if [[ "$issue_state" == running ]]; then
    commit_sha=''
    if [[ "$(git rev-parse HEAD)" != "$issue_base_commit" ]]; then
      commit_sha="$(git rev-parse HEAD)"
      validate_exact_issue_commit "$issue_number" "$batch_branch" "$issue_base_commit" "$commit_sha"
      log_info "reconciled existing commit ${commit_sha} for issue ${issue_number}"
    else
      rm -rf "$CODEX_FLOW_CODEX_DIR"
      queue_set_active_phase issue_flow; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_flow before
      queue_failpoint fail_issue_flow

      log_info "running issue flow for issue ${issue_number}"
      if [[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -ne 0 ]]; then issue_light_review=1; fi
      CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_LIGHT_ISSUE_REVIEW="$issue_light_review" \
        CODEX_FLOW_AGENT_ATTEMPTS_ROOT="${run_state_dir}/batches/${current_batch_id}/attempts/issue-${issue_number}" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"
      queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_flow after
      commit_sha="$(git rev-parse HEAD)"
      queue_failpoint after_issue_flow_commit
    fi
    queue_set_active_phase issue_commit_reconciliation; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_commit_reconciliation before
    validate_exact_issue_commit "$issue_number" "$batch_branch" "$issue_base_commit" "$commit_sha"
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" running committed "$commit_sha" none none
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_commit_reconciliation after
    issue_state=committed
  fi

  recorded_sha="$(queue_state_read_field "$issue_state_file" issue commit_sha)"
  artifact_rel=".work/queue/runs/${run_id}/archives/${current_batch_id}/issues/${issue_number}/${recorded_sha}"
  destination="${CODEX_FLOW_REPO_ROOT}/${artifact_rel}"
  if [[ "$issue_state" == committed ]]; then
    validate_exact_issue_commit "$issue_number" "$batch_branch" "$issue_base_commit" "$recorded_sha"
    queue_set_active_phase artifact_archive; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" artifact_archive before
    archive_hash="$(publish_issue_archive "$destination" "$issue_number" "$current_batch_id" "$recorded_sha")"
    queue_failpoint after_artifact_archive
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" committed artifacts_archived "$recorded_sha" "$artifact_rel" "$archive_hash"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" artifact_archive after
    issue_state=artifacts_archived
    queue_failpoint after_artifact_state_transition
  fi
  artifact_rel="$(queue_state_read_field "$issue_state_file" issue artifact_path)"; destination="${CODEX_FLOW_REPO_ROOT}/${artifact_rel}"
  archive_hash="$(queue_state_read_field "$issue_state_file" issue archive_manifest_sha256)"
  validate_exact_issue_commit "$issue_number" "$batch_branch" "$issue_base_commit" "$recorded_sha"
  validate_issue_archive "$destination" "$issue_number" "$current_batch_id" "$recorded_sha" "$archive_hash" >/dev/null
  if [[ "$issue_state" == artifacts_archived ]]; then
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" artifacts_archived acknowledged "$recorded_sha" "$artifact_rel" "$archive_hash"
    issue_state=acknowledged
  fi
  [[ "$issue_state" == acknowledged ]] || fail "Issue ${issue_number} stopped in unexpected state ${issue_state}"
  compatibility="${batch_dir}/issues/${issue_number}/codex"
  publish_compatibility_archive_view "$destination" "$compatibility"
  rm -rf -- "$CODEX_FLOW_CODEX_DIR"
}

read_pr_state_tsv() {
  local pr_number="$1"

  gh pr view "$pr_number" --json state,mergedAt --jq '[.state, (.mergedAt // "")] | @tsv'
}

wait_for_batch_pr_merge() {
  local pr_number="$1"
  local start_seconds="$SECONDS"
  local state_line
  local state
  local merged_at

  while true; do
    state_line="$(read_pr_state_tsv "$pr_number")"
    IFS=$'\t' read -r state merged_at <<< "$state_line"

    if [[ -z "$state" ]]; then
      fail "Malformed PR state response for PR #${pr_number}: ${state_line}"
    fi

    if [[ -n "$merged_at" ]]; then
      log_info "batch PR #${pr_number} merged"
      return 0
    fi

    if [[ "$state" == 'CLOSED' ]]; then
      fail "Batch PR #${pr_number} closed without merging"
    fi

    if (( SECONDS - start_seconds >= CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS )); then
      fail "Timed out waiting for batch PR #${pr_number} to merge"
    fi

    sleep "$CODEX_FLOW_AUTO_MERGE_POLL_SECONDS"
  done
}

auto_merge_batch_pr() {
  local pr_number="$1"
  local head_sha="$2"

  log_info "enabling auto-merge for batch PR #${pr_number}"
  gh pr merge "$pr_number" --auto --squash --delete-branch --match-head-commit "$head_sha"
  wait_for_batch_pr_merge "$pr_number"
  queue_failpoint after_batch_merge_visible
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
}

queue_set_active_phase() {
  local requested="$1"
  active_phase="$requested"
  [[ "${controlled_worker:-0}" -eq 1 ]] || return 0
  queue_state_write_active_process "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" "$run_id" "$requested" \
    "$controlled_child_pid" "$controlled_child_pgid" "$controlled_child_process_start" "$controlled_parent_pid" \
    "$controlled_parent_process_start" "$lease_owner_token" "$lease_generation" || return 1
  controlled_worker_test_pause "after_active_phase_${requested}"
}

queue_exact_process_is_live() {
  local pid="$1" expected_start="$2" actual_start
  kill -0 "$pid" 2>/dev/null || return 1
  actual_start="$(queue_process_start_identity "$pid")"
  [[ "$actual_start" != unavailable && "$actual_start" == "$expected_start" ]]
}

controlled_worker_parent_is_live() {
  queue_exact_process_is_live "$controlled_parent_pid" "$controlled_parent_process_start"
}

controlled_worker_require_parent() {
  local attempt
  controlled_worker_parent_is_live && return 0
  if [[ "${controlled_worker_registered:-0}" -eq 1 ]]; then
    for ((attempt = 0; attempt < 150; attempt += 1)); do sleep 0.01; done
  fi
  return 1
}

controlled_worker_test_pause() {
  local name="$1" directory="${CODEX_FLOW_QUEUE_TEST_PAUSE_DIR:-}" label="${CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL:-$$}"
  [[ "$ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE" == 1 && -n "$directory" && "${CODEX_FLOW_QUEUE_TEST_PAUSE_AT:-}" == "$name" ]] || return 0
  mkdir -p "$directory"
  : > "${directory}/paused.${name}.${label}"
  while [[ ! -f "${directory}/release.${name}.${label}" ]]; do
    controlled_worker_require_parent || return 1
    sleep 0.01
  done
}

controlled_worker_record_result() {
  local status="$1"
  [[ "${controlled_worker_registered:-0}" -eq 1 ]] || return 0
  trap - EXIT INT TERM
  queue_state_write_worker_result "$controlled_worker_result" "$run_id" "$controlled_child_pid" "$controlled_child_pgid" \
    "$controlled_child_process_start" "$controlled_parent_pid" "$controlled_parent_process_start" "$lease_owner_token" \
    "$lease_generation" "${active_phase:-worker_startup}" "$status" "${controlled_worker_signal:-none}" || true
  rm -f -- "$controlled_worker_registration" "$controlled_worker_authorization" || true
  if ! controlled_worker_parent_is_live && [[ -e "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" ]]; then
    if queue_state_validate_file "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" active_process 2>/dev/null && \
       [[ "$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" child_pid)" == "$controlled_child_pid" ]] && \
       [[ "$(queue_diagnostic_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" owner_token)" == "$lease_owner_token" ]]; then
      rm -f -- "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" || true
    fi
  fi
}

controlled_worker_signal_exit() {
  controlled_worker_signal="$1"
  case "$1" in INT) exit 130 ;; TERM) exit 143 ;; esac
}

validate_controlled_worker_identity_file() {
  local file="$1" schema="$2"
  queue_state_validate_file "$file" "$schema" || return 1
  [[ "$(queue_state_read_field "$file" "$schema" run_id)" == "$run_id" && \
     "$(queue_state_read_field "$file" "$schema" child_pid)" == "$controlled_child_pid" && \
     "$(queue_state_read_field "$file" "$schema" child_pgid)" == "$controlled_child_pgid" && \
     "$(queue_state_read_field "$file" "$schema" process_start)" == "$controlled_child_process_start" && \
     "$(queue_state_read_field "$file" "$schema" owner_pid)" == "$controlled_parent_pid" && \
     "$(queue_state_read_field "$file" "$schema" owner_process_start)" == "$controlled_parent_process_start" && \
     "$(queue_state_read_field "$file" "$schema" owner_token)" == "$lease_owner_token" && \
     "$(queue_state_read_field "$file" "$schema" lease_generation)" == "$lease_generation" ]]
}

process_batch_body() {
  local start_index="$1"
  local end_index="$2"
  local first_issue="${issue_numbers[$start_index]}"
  local last_issue="${issue_numbers[$((end_index - 1))]}"
  local batch_id
  local batch_dir
  local batch_branch
  local batch_base_commit
  local batch_head_commit
  local batch_pr_number
  local _batch_pr_url
  local issues_file
  local batch_issues_label
  local index
  local -a batch_issues=()
  local batch_state_file batch_state
  local publish_state_file published_state
  local CODEX_FLOW_AGENT_ATTEMPTS_ROOT

  assert_queue_lease_owned || fail 'Queue lease lost before batch phase'
  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  current_batch_id="$batch_id"
  CODEX_FLOW_AGENT_ATTEMPTS_ROOT="${run_state_dir}/batches/${batch_id}/attempts/batch"
  batch_state_file="${run_state_dir}/batches/${batch_id}/batch.state"
  publish_state_file="${run_state_dir}/batches/${batch_id}/publish.state"
  batch_state="$(queue_state_read_field "$batch_state_file" batch state)"
  if [[ "$batch_state" == completed ]]; then return 0; fi
  issues_file="${batch_dir}/issues.txt"

  mkdir -p "${batch_dir}/history"
  [[ -f "${batch_dir}/token-usage.tsv" ]] || initialize_batch_token_usage_tsv "$batch_dir"
  [[ -f "$issues_file" ]] || : > "$issues_file"
  queue_state_publish_plain_singleton "${CODEX_FLOW_QUEUE_DIR}/current_batch" "$batch_id" || \
    fail 'Cannot publish current_batch singleton'

  if [[ "$batch_state" == publishing ]]; then
    batch_head_commit="$(queue_state_read_field "$batch_state_file" batch accepted_head)"
    queue_reconcile_batch_pr_state "$publish_state_file" "$batch_state_file" "$run_id" "$batch_id" \
      "$batch_branch" "$batch_head_commit" published_state batch_pr_number _batch_pr_url
    if [[ "$published_state" == merged ]]; then
      queue_state_transition "$batch_state_file" batch "$batch_id" publishing completed
      assert_queue_lease_owned || fail 'Queue lease lost after merged batch reconciliation'
      return 0
    fi
  fi

  if [[ "$batch_state" == planned || "$batch_state" == base_resolved ]]; then
    queue_set_active_phase batch_branch_preparation; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_branch_preparation before
    prepare_batch_branch "$batch_branch" "$batch_id" "$batch_state_file" "$batch_state"
    batch_base_commit="$(queue_state_read_field "$batch_state_file" batch base_commit)"
    printf '%s\n' "$batch_base_commit" > "${batch_dir}/base_commit"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_branch_preparation after
    batch_state=branch_ready
  else
    batch_base_commit="$(queue_state_read_field "$batch_state_file" batch base_commit)"
    [[ "$batch_base_commit" != none ]] || fail "Batch ${batch_id} lacks its durable base commit"
    git show-ref --verify --quiet "refs/heads/${batch_branch}" || fail "Missing expected batch branch ${batch_branch}"
    [[ "$(git branch --show-current)" == "$batch_branch" ]] || git switch "$batch_branch"
  fi
  if [[ "$batch_state" == branch_ready ]]; then validate_batch_branch_ref "$batch_branch" "$batch_base_commit" 'branch-ready boundary'; fi
  if [[ "$batch_state" == branch_ready ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" branch_ready issues_running; batch_state=issues_running; fi

  for ((index = start_index; index < end_index; index += 1)); do
    batch_issues+=("${issue_numbers[$index]}")
    process_issue_on_batch_branch "${issue_numbers[$index]}" "$batch_branch" "$batch_dir" "$issues_file"
  done

  rebuild_batch_issues_file "$batch_id" "$start_index" "$end_index" "$issues_file"

  for ((index = start_index; index < end_index; index += 1)); do
    [[ "$(queue_state_read_field "${run_state_dir}/batches/${batch_id}/issues/${issue_numbers[$index]}.state" issue state)" == acknowledged ]] || \
      fail "Batch ${batch_id} cannot continue before Issue ${issue_numbers[$index]} is acknowledged"
  done

  batch_issues_label="$(join_issue_numbers "${batch_issues[@]}")"

  if [[ "$batch_state" == issues_running ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" issues_running checks_running; batch_state=checks_running; fi
  if [[ "$batch_state" == checks_running ]]; then
    queue_set_active_phase batch_checks; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_checks before
    queue_failpoint fail_batch_checks
    ensure_batch_checks_pass "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" "$batch_issues_label" "$batch_check_fix_effort"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_checks after
    queue_state_transition "$batch_state_file" batch "$batch_id" checks_running review_running; batch_state=review_running
  fi
  if [[ "$batch_state" == review_running ]]; then
    queue_set_active_phase batch_review; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_review before
    queue_failpoint fail_batch_review
    ensure_batch_review_accepted \
    "$batch_dir" \
    "$issues_file" \
    "$batch_base_commit" \
    "$first_issue" \
    "$last_issue" \
    "$batch_issues_label" \
    "$batch_review_effort" \
    "$batch_review_fix_effort" \
    "$batch_check_fix_effort" \
    "${run_state_dir}/batches/${batch_id}"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_review after
    batch_head_commit="$(git rev-parse --verify 'HEAD^{commit}')"
    queue_state_mark_batch_accepted "$batch_state_file" "$batch_id" "$batch_head_commit"; batch_state=accepted
    queue_failpoint after_batch_acceptance
  fi

  batch_head_commit="$(queue_state_read_field "$batch_state_file" batch accepted_head)"
  [[ "$batch_head_commit" != none ]] || fail "Batch ${batch_id} lacks its accepted head identity"
  validate_batch_branch_ref "$batch_branch" "$batch_head_commit" 'accepted head'
  printf '%s\n' "$batch_head_commit" > "${batch_dir}/head_commit"
  write_batch_changed_files "$batch_base_commit" "${batch_dir}/changed-files.txt"

  if [[ "$batch_state" == accepted ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" accepted publishing; batch_state=publishing; fi
  validate_batch_branch_ref "$batch_branch" "$batch_head_commit" 'publication input'
  queue_set_active_phase batch_publish; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_publish before
  queue_failpoint fail_batch_publish
  queue_reconcile_batch_pr_state "$publish_state_file" "$batch_state_file" "$run_id" "$batch_id" \
    "$batch_branch" "$batch_head_commit" published_state batch_pr_number _batch_pr_url
  if [[ "$published_state" == none ]]; then
    publish_batch_results \
    "$first_issue" \
    "$last_issue" \
    "$batch_branch" \
    "$draft_pr" \
    batch_pr_number \
    _batch_pr_url \
    "${batch_issues[@]}"
    queue_failpoint after_batch_publish
    queue_state_record_publish "$publish_state_file" "$run_id" "$batch_id" "$batch_pr_number" "$_batch_pr_url" "$batch_branch" \
      "$CODEX_FLOW_BASE_BRANCH" "$batch_head_commit" open
    queue_reconcile_batch_pr_state "$publish_state_file" "$batch_state_file" "$run_id" "$batch_id" \
      "$batch_branch" "$batch_head_commit" published_state batch_pr_number _batch_pr_url
  fi
  queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_publish after

  if [[ "$published_state" == merged ]]; then
    queue_state_transition "$batch_state_file" batch "$batch_id" publishing completed
    assert_queue_lease_owned || fail 'Queue lease lost after merged batch reconciliation'
    return 0
  fi

  if [[ "$auto_merge" -eq 1 ]]; then
    queue_set_active_phase auto_merge; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" auto_merge before
    auto_merge_batch_pr "$batch_pr_number" "$batch_head_commit"
    queue_reconcile_batch_pr_state "$publish_state_file" "$batch_state_file" "$run_id" "$batch_id" \
      "$batch_branch" "$batch_head_commit" published_state batch_pr_number _batch_pr_url
    [[ "$published_state" == merged ]] || fail "Batch PR #${batch_pr_number} was not merged after auto-merge completed"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" auto_merge after
  fi
  queue_state_transition "$batch_state_file" batch "$batch_id" publishing completed
  assert_queue_lease_owned || fail 'Queue lease lost after batch phase'
}

process_batch() {
  local start_index="$1" end_index="$2" worker_status=1 attempt parent_pgid registration_phase
  local first_issue="${issue_numbers[$start_index]}" last_issue="${issue_numbers[$((end_index - 1))]}"
  queue_state_guard_enter || fail 'Cannot acquire queue serialization guard before batch phase'
  assert_queue_lease_owned || fail 'Queue lease lost before batch phase'
  controlled_parent_pid="$$"
  controlled_parent_process_start="$(queue_process_start_identity "$$")"
  parent_pgid="$(queue_process_group_identity "$$")" || {
    queue_state_guard_leave || true
    fail 'Cannot establish queue parent process-group identity'
  }
  controlled_worker_prefix="$(dirname "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE")/worker.${run_id}.${lease_owner_token}.${lease_generation}"
  rm -f -- "${controlled_worker_prefix}."*.registration "${controlled_worker_prefix}."*.authorization "${controlled_worker_prefix}."*.result
  set -m
  (
    trap - EXIT INT TERM
    controlled_worker=1
    controlled_child_pid="$BASHPID"
    controlled_child_pgid="$(queue_process_group_identity "$BASHPID")"
    controlled_child_process_start="$(queue_process_start_identity "$BASHPID")"
    controlled_worker_registration="${controlled_worker_prefix}.${controlled_child_pid}.registration"
    controlled_worker_authorization="${controlled_worker_prefix}.${controlled_child_pid}.authorization"
    controlled_worker_result="${controlled_worker_prefix}.${controlled_child_pid}.result"
    controlled_worker_registered=0
    controlled_worker_signal=none
    active_phase="batch-${first_issue}-${last_issue}"
    [[ "$controlled_child_pgid" =~ ^[1-9][0-9]*$ && "$controlled_child_process_start" != unavailable ]] || exit 1
    controlled_worker_test_pause after_worker_fork_before_registration || exit 1
    controlled_worker_require_parent || exit 1
    queue_state_write_worker_registration "$controlled_worker_registration" "$run_id" "$controlled_child_pid" \
      "$controlled_child_pgid" "$controlled_child_process_start" "$controlled_parent_pid" "$controlled_parent_process_start" \
      "$lease_owner_token" "$lease_generation"
    controlled_worker_registered=1
    trap 'controlled_worker_record_result $?' EXIT
    trap 'controlled_worker_signal_exit INT' INT
    trap 'controlled_worker_signal_exit TERM' TERM
    while [[ ! -e "$controlled_worker_authorization" ]]; do
      controlled_worker_require_parent || exit 1
      sleep 0.01
    done
    validate_controlled_worker_identity_file "$controlled_worker_authorization" worker_authorization || exit 1
    controlled_worker_require_parent || exit 1
    controlled_worker_test_pause after_worker_authorization_before_first_external_mutation || exit 1
    controlled_worker_require_parent || exit 1
    process_batch_body "$start_index" "$end_index"
  ) &
  controlled_child_pid=$!
  set +m
  controlled_child_active=1
  controlled_child_group_verified=0
  controlled_child_pgid=''
  controlled_child_process_start="$(queue_process_start_identity "$controlled_child_pid")"
  controlled_worker_registration="${controlled_worker_prefix}.${controlled_child_pid}.registration"
  controlled_worker_authorization="${controlled_worker_prefix}.${controlled_child_pid}.authorization"
  controlled_worker_result="${controlled_worker_prefix}.${controlled_child_pid}.result"
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    if [[ -e "$controlled_worker_registration" ]]; then break; fi
    queue_exact_process_is_live "$controlled_child_pid" "$controlled_child_process_start" || break
    sleep 0.01
  done
  if [[ ! -e "$controlled_worker_registration" ]] || ! queue_state_validate_file "$controlled_worker_registration" worker_registration; then
    terminate_controlled_process_tree || true
    queue_state_guard_leave || true
    fail 'Controlled batch worker exited before publishing a complete registration'
  fi
  controlled_child_pgid="$(queue_state_read_field "$controlled_worker_registration" worker_registration child_pgid)"
  controlled_child_process_start="$(queue_state_read_field "$controlled_worker_registration" worker_registration process_start)"
  if ! validate_controlled_worker_identity_file "$controlled_worker_registration" worker_registration || \
     [[ "$controlled_child_pgid" == "$parent_pgid" ]] || \
     [[ "$(queue_process_group_identity "$controlled_child_pid" || true)" != "$controlled_child_pgid" ]]; then
    terminate_controlled_process_tree || true
    queue_state_guard_leave || true
    fail 'Controlled batch worker registration has an invalid or non-distinct process-group identity'
  fi
  controlled_child_group_verified=1
  registration_phase="batch-${first_issue}-${last_issue}"
  queue_state_write_active_process "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" "$run_id" \
    "$registration_phase" "$controlled_child_pid" "$controlled_child_pgid" "$controlled_child_process_start" \
    "$controlled_parent_pid" "$controlled_parent_process_start" "$lease_owner_token" "$lease_generation"
  queue_test_pause after_worker_registration_before_authorization
  queue_state_write_worker_authorization "$controlled_worker_authorization" "$run_id" "$controlled_child_pid" \
    "$controlled_child_pgid" "$controlled_child_process_start" "$controlled_parent_pid" "$controlled_parent_process_start" \
    "$lease_owner_token" "$lease_generation"
  if wait "$controlled_child_pid"; then worker_status=0; else worker_status=$?; fi
  controlled_child_active=0
  if kill -0 -- "-${controlled_child_pgid}" 2>/dev/null; then
    queue_state_guard_abandon || true
    log_error "Controlled process group ${controlled_child_pgid} outlived batch worker ${controlled_child_pid}; ownership remains fenced by the inherited guard"
    log_error "safe recovery: terminate it with: kill -TERM -- -${controlled_child_pgid}; then resume run ${run_id}"
    return 1
  fi
  if [[ -f "$controlled_worker_result" ]] && validate_controlled_worker_identity_file "$controlled_worker_result" worker_result; then
    active_phase="$(queue_state_read_field "$controlled_worker_result" worker_result phase)"
  elif [[ -f "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" ]]; then
    active_phase="$(queue_state_read_field "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" active_process phase)"
  fi
  rm -f -- "$controlled_worker_registration" "$controlled_worker_authorization" "$controlled_worker_result"
  rm -f -- "$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE" || {
    queue_state_guard_leave || true
    fail 'Cannot remove completed active-process record'
  }
  queue_state_guard_leave || fail 'Cannot release queue serialization guard after batch phase'
  return "$worker_status"
}

validate_completed_queue_run() {
  local manifest="${run_state_dir}/manifest.state" state_file="${run_state_dir}/run.state" state
  local -A fields=() state_fields=()
  [[ -d "$run_state_dir" && ! -L "$run_state_dir" ]] || fail "Unknown queue run ID: ${run_id}"
  queue_state_parse_file "$manifest" manifest fields || fail "Invalid completed-run manifest: ${manifest}"
  queue_state_validate_file "$manifest" manifest || fail "Invalid completed-run manifest: ${manifest}"
  [[ "${fields[run_id]}" == "$run_id" ]] || fail "Manifest run ID mismatch for ${run_id}"
  [[ "${fields[repository_identity]}" == "$(canonical_repository_identity)" ]] || \
    fail 'Completed-run repository identity does not match the immutable manifest'
  queue_state_parse_file "$state_file" run state_fields || fail "Invalid completed run state: ${state_file}"
  queue_state_validate_file "$state_file" run || fail "Invalid completed run state: ${state_file}"
  [[ "${state_fields[run_id]}" == "$run_id" ]] || fail "Run state identity mismatch for ${run_id}"
  state="${state_fields[state]}"
  [[ "$state" == completed ]] || return 2
  IFS=',' read -r -a issue_numbers <<< "${fields[issues]}"
  review_every="${fields[review_every]}"
  CODEX_FLOW_BATCH_BRANCH_PREFIX="${fields[batch_branch_prefix]}"
}

resolve_completed_lease_without_current() {
  local marker="$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE"
  local lock="${CODEX_FLOW_QUEUE_DIR}/lease.lock" found state
  local -A fields=()
  resolved_completion_run_id=''
  queue_state_guard_enter || fail 'Cannot inspect queue lease while resolving --resume current'
  queue_state_require_singleton_path "$marker" optional || {
    queue_state_guard_leave || true
    fail "Invalid completion cleanup marker while resolving --resume current: ${marker}"
  }
  if [[ -e "$marker" ]]; then
    if ! queue_state_parse_file "$marker" completion_cleanup fields || ! queue_state_validate_file "$marker" completion_cleanup; then
      queue_state_guard_leave || true
      fail "Invalid completion cleanup marker while resolving --resume current: ${marker}"
    fi
    resolved_completion_run_id="${fields[run_id]}"
    queue_state_guard_leave || fail 'Cannot release queue guard after resolving completion cleanup marker'
    return 0
  fi
  if [[ -d "$lock" && ! -L "$lock" ]]; then
    found="$(find "$lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
    [[ -n "$found" && "$found" != *$'\n'* ]] || {
      queue_state_guard_leave || true
      fail "Invalid queue lease while resolving --resume current: ${lock}"
    }
    if ! queue_state_parse_file "$found" lease fields || ! queue_state_validate_file "$found" lease || \
       [[ "${found##*/}" != "owner.${fields[owner_token]}.state" ]]; then
      queue_state_guard_leave || true
      fail "Invalid queue lease owner while resolving --resume current: ${found}"
    fi
    resolved_completion_run_id="${fields[run_id]}"
    [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${resolved_completion_run_id}/run.state" ]] || {
      queue_state_guard_leave || true
      fail "Queue lease names unknown run ${resolved_completion_run_id}"
    }
    state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${resolved_completion_run_id}/run.state" run state)"
    if [[ "$state" != completed ]]; then
      queue_state_guard_leave || true
      fail "No current pointer is published; queue lease names unfinished run ${resolved_completion_run_id}; resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${resolved_completion_run_id}"
    fi
  elif [[ -e "$lock" || -L "$lock" ]]; then
    queue_state_guard_leave || true
    fail "Invalid queue lease path while resolving --resume current: ${lock}"
  fi
  queue_state_guard_leave || fail 'Cannot release queue guard after resolving --resume current'
}

validate_completed_lease_audit_under_guard() {
  local audit="$1" expected_run="$2" expected_token="$3" expected_generation="$4" found
  local -A fields=()
  [[ -d "$audit" && ! -L "$audit" ]] || fail "Completed-run lease audit is not the expected directory: ${audit}"
  found="$(find "$audit" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
  [[ -n "$found" && "$found" != *$'\n'* ]] || fail "Completed-run lease audit is incomplete or ambiguous: ${audit}"
  if ! queue_state_parse_file "$found" lease fields || ! queue_state_validate_file "$found" lease; then
    fail "Invalid completed-run lease audit owner: ${found}"
  fi
  [[ "${found##*/}" == "owner.${fields[owner_token]}.state" && "${fields[run_id]}" == "$expected_run" && \
     "${fields[owner_token]}" == "$expected_token" && "${fields[lease_generation]}" == "$expected_generation" ]] || \
    fail "Completed-run lease audit fencing identity mismatch: ${audit}"
}

completed_terminal_requires_reconciliation() {
  local expected_run="$1" expected_token="$2" expected_generation="$3" expected_lease_required="$4"
  local expected_batch="$5" pointer="$6" batch_pointer="$7" lock="$8" active="$9" audit
  local found='' value='' foreign_owner=0
  local -A fields=()
  terminal_reconciliation_required=0

  queue_state_require_singleton_path "$pointer" optional || fail "Invalid current queue pointer path: ${pointer}"
  if [[ -e "$pointer" ]]; then
    queue_state_parse_file "$pointer" pointer fields || fail "Invalid current queue pointer: ${pointer}"
    queue_state_validate_file "$pointer" pointer || fail "Invalid current queue pointer: ${pointer}"
    if [[ "${fields[run_id]}" == "$expected_run" ]]; then
      terminal_reconciliation_required=1
    else
      foreign_owner=1
    fi
  fi

  if [[ -e "$lock" && ( ! -d "$lock" || -L "$lock" ) ]]; then
    fail "Invalid queue lease path during completed-run terminal inspection: ${lock}"
  fi
  if [[ -d "$lock" && ! -L "$lock" ]]; then
    found="$(find "$lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
    [[ -n "$found" && "$found" != *$'\n'* ]] || fail "Invalid queue lease during completed-run terminal inspection: ${lock}"
    fields=()
    queue_state_parse_file "$found" lease fields || fail "Invalid queue lease owner during completed-run terminal inspection: ${found}"
    queue_state_validate_file "$found" lease || fail "Invalid queue lease owner during completed-run terminal inspection: ${found}"
    [[ "${found##*/}" == "owner.${fields[owner_token]}.state" ]] || \
      fail "Queue lease owner filename does not match embedded owner token: ${found}"
    if [[ "${fields[run_id]}" == "$expected_run" ]]; then
      terminal_reconciliation_required=1
    else
      foreign_owner=1
    fi
  fi

  queue_state_require_singleton_path "$active" optional || fail "Invalid active queue process path: ${active}"
  if [[ -e "$active" ]]; then
    fields=()
    queue_state_parse_file "$active" active_process fields || fail "Invalid active queue process record: ${active}"
    queue_state_validate_file "$active" active_process || fail "Invalid active queue process record: ${active}"
    if [[ "${fields[run_id]}" == "$expected_run" ]]; then
      terminal_reconciliation_required=1
    else
      foreign_owner=1
    fi
  fi

  audit="${CODEX_FLOW_QUEUE_DIR}/lease.finalized.${expected_generation}.${expected_token}"
  if [[ "$expected_lease_required" == 1 ]]; then
    [[ -e "$audit" ]] || terminal_reconciliation_required=1
    if [[ -e "$audit" ]]; then
      validate_completed_lease_audit_under_guard "$audit" "$expected_run" "$expected_token" "$expected_generation"
    fi
  elif [[ -e "$audit" || -L "$audit" ]]; then
    terminal_reconciliation_required=1
  fi

  queue_state_require_singleton_path "$batch_pointer" optional || \
    fail "Invalid current_batch singleton path: ${batch_pointer}"
  if [[ -e "$batch_pointer" ]]; then
    value="$(<"$batch_pointer")"
    queue_state_require_token 'current batch pointer' "$value" || \
      fail "Invalid current_batch value during completed-run terminal inspection: ${batch_pointer}"
    if [[ "$foreign_owner" -eq 0 && "$expected_batch" != none && "$value" == "$expected_batch" ]]; then
      terminal_reconciliation_required=1
    fi
  fi
}

completion_cleanup_phase_at_least() {
  local actual_phase="$1" threshold_phase="$2" actual_rank threshold_rank
  case "$actual_phase" in
    planned) actual_rank=0 ;;
    lease_retired) actual_rank=1 ;;
    batch_pointer_removed) actual_rank=2 ;;
    current_removed) actual_rank=3 ;;
    completed) actual_rank=4 ;;
    *) fail "Unknown completion cleanup phase: ${actual_phase}" ;;
  esac
  case "$threshold_phase" in
    planned) threshold_rank=0 ;;
    lease_retired) threshold_rank=1 ;;
    batch_pointer_removed) threshold_rank=2 ;;
    current_removed) threshold_rank=3 ;;
    completed) threshold_rank=4 ;;
    *) fail "Unknown required completion cleanup phase: ${threshold_phase}" ;;
  esac
  [[ "$actual_rank" -ge "$threshold_rank" ]]
}

reconcile_completed_cleanup_phase_postconditions_under_guard() {
  local phase="$1" expected_run="$2" expected_token="$3" expected_generation="$4" lease_required="$5"
  local expected_batch="$6" audit="$7" lock="$8" batch_pointer="$9" pointer="${10}" active="${11}"
  local value

  if completion_cleanup_phase_at_least "$phase" lease_retired; then
    if [[ "$lease_required" == 1 ]]; then
      [[ -e "$audit" ]] || fail "Completion cleanup invariant failed: phase ${phase} requires finalized lease audit ${audit}"
      validate_completed_lease_audit_under_guard "$audit" "$expected_run" "$expected_token" "$expected_generation"
    elif [[ -e "$audit" || -L "$audit" ]]; then
      fail "Completion cleanup invariant failed: lease_required=0 forbids finalized lease audit ${audit}"
    fi
    [[ ! -e "$lock" && ! -L "$lock" ]] || \
      fail "Completion cleanup invariant failed: phase ${phase} requires the queue lease path to be absent"
  fi

  if completion_cleanup_phase_at_least "$phase" batch_pointer_removed; then
    queue_state_require_singleton_path "$batch_pointer" optional || \
      fail "Invalid current_batch singleton path while reconciling cleanup phase ${phase}: ${batch_pointer}"
    if [[ -e "$batch_pointer" ]]; then
      value="$(<"$batch_pointer")"
      [[ "$expected_batch" != none && "$value" == "$expected_batch" ]] || \
        fail "Completion cleanup invariant failed: phase ${phase} found a different current_batch value"
      rm -- "$batch_pointer" || fail "Cannot reconcile reappeared current_batch for cleanup phase ${phase}"
    fi
  fi

  if completion_cleanup_phase_at_least "$phase" current_removed; then
    queue_state_require_singleton_path "$pointer" optional || \
      fail "Invalid current pointer while reconciling cleanup phase ${phase}: ${pointer}"
    if [[ -e "$pointer" ]]; then
      queue_state_remove_pointer_if_matches "$pointer" "$expected_run" "$expected_token" "$expected_generation" || \
        fail "Completion cleanup invariant failed: phase ${phase} found a different current fencing identity"
    fi
  fi

  if [[ "$phase" == completed ]]; then
    queue_state_require_singleton_path "$active" optional || \
      fail "Invalid active-process singleton while reconciling completed cleanup: ${active}"
    [[ ! -e "$active" ]] || fail 'Completion cleanup terminal invariant failed: same-run active-process residue remains'
  fi
}

finalize_completed_queue_run() {
  local pointer="${CODEX_FLOW_QUEUE_DIR}/current" batch_pointer="${CODEX_FLOW_QUEUE_DIR}/current_batch"
  local marker="$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETION_CLEANUP_FILE" active="$ISSUE_FORGE_INTERNAL_QUEUE_ACTIVE_PROCESS_FILE"
  local terminal="${run_state_dir}/completion-cleanup.state"
  local found='' record='' pointer_run='' pointer_token='' pointer_generation=''
  local owner_run='' owner_host='' owner_pid='' owner_start='' owner_token='' owner_generation=''
  local cleanup_token='' cleanup_generation='' cleanup_phase='' cleanup_lease_required='' cleanup_batch=''
  local active_run='' active_token='' active_generation='' active_pid='' active_pgid='' active_start=''
  local owner_status local_host audit batch_value='' batch_state same_run_residue=0 marker_present=0 owner_is_self=0
  local terminal_present=0 terminal_reconciliation_required=0 terminal_marker_same_run=0
  local -A owner_fields=() pointer_fields=() cleanup_fields=() active_fields=() terminal_fields=() discovery_fields=()

  validate_completed_queue_run || fail "Queue run ${run_id} is not completed and cannot use completion finalization"
  queue_lock="${CODEX_FLOW_QUEUE_DIR}/lease.lock"
  queue_state_require_singleton_path "$terminal" optional || fail "Invalid completed-run terminal cleanup state: ${terminal}"
  if [[ -e "$terminal" ]]; then
    if ! queue_state_parse_file "$terminal" completion_cleanup terminal_fields || \
       ! queue_state_validate_file "$terminal" completion_cleanup || \
       [[ "${terminal_fields[run_id]}" != "$run_id" || "${terminal_fields[phase]}" != completed ]]; then
      fail "Invalid completed-run terminal cleanup state: ${terminal}"
    fi
    terminal_present=1
    queue_state_require_singleton_path "$marker" optional || fail "Invalid completion cleanup marker: ${marker}"
    if [[ -e "$marker" ]]; then
      if ! queue_state_parse_file "$marker" completion_cleanup discovery_fields || ! queue_state_validate_file "$marker" completion_cleanup; then
        fail "Invalid completion cleanup marker: ${marker}"
      fi
      [[ "${discovery_fields[run_id]}" != "$run_id" ]] || terminal_marker_same_run=1
    fi
    completed_terminal_requires_reconciliation "$run_id" "${terminal_fields[owner_token]}" \
      "${terminal_fields[lease_generation]}" "${terminal_fields[lease_required]}" \
      "${terminal_fields[batch_pointer]}" "$pointer" "$batch_pointer" "$queue_lock" "$active"
    if [[ "$terminal_marker_same_run" -eq 0 && "$terminal_reconciliation_required" -eq 0 ]]; then
      run_completed=1
      trap - EXIT INT TERM
      log_info "Queue run ${run_id} is already completed and its control plane is already finalized; no cleanup or work resume is required"
      return 0
    fi
  fi
  validate_queue_run_graph
  queue_state_guard_enter || fail 'Cannot acquire queue serialization guard for completed-run finalization'

  queue_state_require_singleton_path "$marker" optional || {
    queue_state_guard_leave || true
    fail "Invalid completion cleanup marker: ${marker}"
  }
  if [[ -e "$marker" ]]; then
    if ! queue_state_parse_file "$marker" completion_cleanup cleanup_fields || ! queue_state_validate_file "$marker" completion_cleanup; then
      queue_state_guard_leave || true
      fail "Invalid completion cleanup marker: ${marker}"
    fi
    [[ "${cleanup_fields[run_id]}" == "$run_id" ]] || {
      queue_state_guard_leave || true
      fail "Completion cleanup for run ${cleanup_fields[run_id]} is pending; completed run ${run_id} was not modified; finish it with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${cleanup_fields[run_id]}"
    }
    marker_present=1; same_run_residue=1
    cleanup_token="${cleanup_fields[owner_token]}"; cleanup_generation="${cleanup_fields[lease_generation]}"
    cleanup_lease_required="${cleanup_fields[lease_required]}"; cleanup_batch="${cleanup_fields[batch_pointer]}"
    cleanup_phase="${cleanup_fields[phase]}"
  fi
  [[ "$terminal_reconciliation_required" -ne 1 ]] || same_run_residue=1

  queue_state_require_singleton_path "$pointer" optional || {
    queue_state_guard_leave || true
    fail "Invalid current queue pointer path: ${pointer}"
  }
  if [[ -e "$pointer" ]]; then
    if ! queue_state_parse_file "$pointer" pointer pointer_fields || ! queue_state_validate_file "$pointer" pointer; then
      queue_state_guard_leave || true
      fail "Invalid current queue pointer: ${pointer}"
    fi
    pointer_run="${pointer_fields[run_id]}"; pointer_token="${pointer_fields[owner_token]}"
    pointer_generation="${pointer_fields[lease_generation]}"
    [[ "$pointer_run" != "$run_id" ]] || same_run_residue=1
  fi

  if [[ -e "$queue_lock" && ( ! -d "$queue_lock" || -L "$queue_lock" ) ]]; then
    queue_state_guard_leave || true
    fail "Invalid queue lease path during completed-run finalization: ${queue_lock}"
  fi
  if [[ -d "$queue_lock" && ! -L "$queue_lock" ]]; then
    found="$(find "$queue_lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
    [[ -n "$found" && "$found" != *$'\n'* ]] || {
      queue_state_guard_leave || true
      fail "Invalid queue lease during completed-run finalization: ${queue_lock}"
    }
    record="$found"
    if ! queue_state_parse_file "$record" lease owner_fields || ! queue_state_validate_file "$record" lease; then
      queue_state_guard_leave || true
      fail "Invalid queue lease owner during completed-run finalization: ${record}"
    fi
    [[ "${record##*/}" == "owner.${owner_fields[owner_token]}.state" ]] || {
      queue_state_guard_leave || true
      fail "Queue lease owner filename does not match embedded owner token: ${record}"
    }
    owner_run="${owner_fields[run_id]}"; owner_host="${owner_fields[owner_host]}"; owner_pid="${owner_fields[owner_pid]}"
    owner_start="${owner_fields[process_start]}"; owner_token="${owner_fields[owner_token]}"; owner_generation="${owner_fields[lease_generation]}"
    [[ "$owner_run" != "$run_id" ]] || same_run_residue=1
  fi

  if [[ "$same_run_residue" -ne 1 ]]; then
    queue_state_guard_leave || fail 'Cannot release serialization guard after completed-run inspection'
    run_completed=1
    trap - EXIT INT TERM
    log_info "Queue run ${run_id} is already completed and its control plane is already finalized; no cleanup or work resume is required"
    return 0
  fi
  if [[ -n "$pointer_run" && "$pointer_run" != "$run_id" ]]; then
    queue_state_guard_leave || true
    fail "Completed run ${run_id} still has pending cleanup, but current belongs to run ${pointer_run}; no control-plane state was modified"
  fi
  if [[ -n "$owner_run" && "$owner_run" != "$run_id" ]]; then
    queue_state_guard_leave || true
    fail "Completed run ${run_id} still has pending cleanup, but the lease belongs to run ${owner_run}; no control-plane state was modified"
  fi
  if [[ -n "$pointer_run" && -n "$owner_run" && \
        ( "$pointer_token" != "$owner_token" || "$pointer_generation" != "$owner_generation" ) ]]; then
    queue_state_guard_leave || true
    fail "Completed run ${run_id} has contradictory current/lease fencing identities"
  fi

  if [[ "$marker_present" -eq 1 ]]; then
    if [[ -n "$pointer_run" && ( "$pointer_token" != "$cleanup_token" || "$pointer_generation" != "$cleanup_generation" ) ]]; then
      queue_state_guard_leave || true
      fail "Completed run ${run_id} current pointer contradicts its cleanup transaction identity"
    fi
    if [[ -n "$owner_run" && ( "$owner_token" != "$cleanup_token" || "$owner_generation" != "$cleanup_generation" ) ]]; then
      queue_state_guard_leave || true
      fail "Completed run ${run_id} lease contradicts its cleanup transaction identity"
    fi
  elif [[ "$terminal_present" -eq 1 ]]; then
    cleanup_token="${terminal_fields[owner_token]}"; cleanup_generation="${terminal_fields[lease_generation]}"
    cleanup_lease_required="${terminal_fields[lease_required]}"; cleanup_batch="${terminal_fields[batch_pointer]}"
    cleanup_phase=completed
    if [[ -n "$pointer_run" && ( "$pointer_token" != "$cleanup_token" || "$pointer_generation" != "$cleanup_generation" ) ]]; then
      queue_state_guard_leave || true
      fail "Completed run ${run_id} current pointer contradicts its terminal cleanup identity"
    fi
    if [[ -n "$owner_run" && ( "$owner_token" != "$cleanup_token" || "$owner_generation" != "$cleanup_generation" ) ]]; then
      queue_state_guard_leave || true
      fail "Completed run ${run_id} lease contradicts its terminal cleanup identity"
    fi
  else
    if [[ -n "$pointer_run" ]]; then
      cleanup_token="$pointer_token"; cleanup_generation="$pointer_generation"
    else
      cleanup_token="$owner_token"; cleanup_generation="$owner_generation"
    fi
    cleanup_lease_required=0
    [[ -z "$owner_run" ]] || cleanup_lease_required=1
    cleanup_phase=planned
  fi

  queue_state_require_singleton_path "$batch_pointer" optional || {
    queue_state_guard_leave || true
    fail "Invalid current_batch singleton path: ${batch_pointer}"
  }
  if [[ -e "$batch_pointer" ]]; then
    batch_value="$(<"$batch_pointer")"
    queue_state_require_token 'current batch pointer' "$batch_value" || {
      queue_state_guard_leave || true
      fail "Invalid current_batch value during completed-run finalization: ${batch_pointer}"
    }
    if [[ "$marker_present" -eq 1 || "$terminal_present" -eq 1 ]]; then
      [[ "$cleanup_batch" != none && "$batch_value" == "$cleanup_batch" ]] || {
        queue_state_guard_leave || true
        fail "current_batch does not match completed run ${run_id}'s cleanup transaction; no state was modified"
      }
    else
      batch_state="${run_state_dir}/batches/${batch_value}/batch.state"
      if ! queue_state_validate_file "$batch_state" batch || [[ "$(queue_state_read_field "$batch_state" batch run_id)" != "$run_id" ]]; then
        queue_state_guard_leave || true
        fail "current_batch cannot be proven to belong to completed run ${run_id}; no state was modified"
      fi
      cleanup_batch="$batch_value"
    fi
  elif [[ "$marker_present" -ne 1 && "$terminal_present" -ne 1 ]]; then
    cleanup_batch=none
  fi

  queue_state_require_singleton_path "$active" optional || {
    queue_state_guard_leave || true
    fail "Invalid active queue process path: ${active}"
  }
  if [[ -e "$active" ]]; then
    if ! queue_state_parse_file "$active" active_process active_fields || ! queue_state_validate_file "$active" active_process; then
      queue_state_guard_leave || true
      fail "Invalid active queue process record: ${active}"
    fi
    active_run="${active_fields[run_id]}"; active_token="${active_fields[owner_token]}"
    active_generation="${active_fields[lease_generation]}"; active_pid="${active_fields[child_pid]}"
    active_pgid="${active_fields[child_pgid]}"; active_start="${active_fields[process_start]}"
    [[ "$active_run" == "$run_id" ]] || {
      queue_state_guard_leave || true
      fail "Active-process record belongs to run ${active_run}; completed run ${run_id} was not modified"
    }
    [[ "$active_token" == "$cleanup_token" && "$active_generation" == "$cleanup_generation" ]] || {
      queue_state_guard_leave || true
      fail "Completed run ${run_id} active-process fencing identity contradicts its cleanup identity"
    }
    if queue_exact_process_is_live "$active_pid" "$active_start" || kill -0 -- "-${active_pgid}" 2>/dev/null; then
      queue_state_guard_leave || true
      fail "Completed run ${run_id} still has active process PID ${active_pid} PGID ${active_pgid}; wait for it to exit before finalization"
    fi
  fi

  local_host="$(queue_host_identity)"
  if [[ -n "$owner_run" && "$cleanup_phase" == planned ]]; then
    owner_status=unverifiable
    if [[ "$owner_host" == "$local_host" ]]; then
      if queue_exact_process_is_live "$owner_pid" "$owner_start"; then owner_status=live
      elif [[ -d /proc && ! -e "/proc/${owner_pid}" ]]; then owner_status=dead
      fi
      if [[ "${lease_owned:-0}" -eq 1 && "$owner_pid" == "$$" && "$owner_token" == "${lease_owner_token:-}" && \
            "$owner_generation" == "${lease_generation:-}" ]]; then owner_is_self=1; fi
      if [[ "$owner_status" == live && "$owner_is_self" -ne 1 ]]; then
        queue_state_guard_leave || true
        fail "Completed-run finalization is still active in same-host PID ${owner_pid} for run ${run_id}"
      fi
      if [[ "$owner_status" != dead && "$owner_status" != live && "$take_over_lease" -ne 1 ]]; then
        queue_state_guard_leave || true
        fail "Completed-run lease owner is unverifiable; rerun --resume ${run_id} --take-over-lease only after asserting it stopped"
      fi
    elif [[ "$take_over_lease" -ne 1 ]]; then
      queue_state_guard_leave || true
      fail "Completed-run lease belongs to host ${owner_host}; rerun --resume ${run_id} --take-over-lease"
    fi
  fi

  audit="${CODEX_FLOW_QUEUE_DIR}/lease.finalized.${cleanup_generation}.${cleanup_token}"
  if [[ "$cleanup_lease_required" == 1 && -e "$audit" ]]; then
    validate_completed_lease_audit_under_guard "$audit" "$run_id" "$cleanup_token" "$cleanup_generation"
    if completion_cleanup_phase_at_least "$cleanup_phase" lease_retired && [[ -n "$owner_run" ]]; then
      queue_state_guard_leave || true
      fail "Completion cleanup invariant failed: phase ${cleanup_phase} requires the same-run lease path to be absent"
    fi
  elif [[ -e "$audit" || -L "$audit" ]]; then
    queue_state_guard_leave || true
    fail "Unexpected completed-run lease audit path: ${audit}"
  fi
  if completion_cleanup_phase_at_least "$cleanup_phase" lease_retired; then
    if [[ "$cleanup_lease_required" == 1 && ! -e "$audit" ]]; then
      queue_state_guard_leave || true
      fail "Completion cleanup invariant failed: phase ${cleanup_phase} requires finalized lease audit ${audit}"
    fi
    if [[ "$cleanup_lease_required" == 0 && -n "$owner_run" ]]; then
      queue_state_guard_leave || true
      fail "Completion cleanup invariant failed: lease_required=0 requires the same-run lease path to be absent"
    fi
  elif [[ "$cleanup_lease_required" == 0 && -n "$owner_run" ]]; then
    queue_state_guard_leave || true
    fail 'Completion cleanup invariant failed: lease_required=0 contradicts the same-run lease path'
  fi

  if [[ "$marker_present" -ne 1 ]]; then
    queue_state_write_completion_cleanup "$marker" "$run_id" "$cleanup_token" "$cleanup_generation" \
      "$cleanup_lease_required" "$cleanup_batch" "$cleanup_phase" || {
      queue_state_guard_leave || true
      fail 'Cannot publish completed-run cleanup transaction'
    }
    queue_test_pause after_completion_cleanup_marker
  fi
  if [[ -e "$active" ]]; then
    rm -- "$active" || {
      queue_state_guard_leave || true
      fail "Cannot remove stopped active-process record for completed run ${run_id}"
    }
  fi

  if [[ "$cleanup_phase" == planned ]]; then
    if [[ "$cleanup_lease_required" == 1 ]]; then
      if [[ -n "$owner_run" ]]; then
        [[ ! -e "$audit" ]] || {
          queue_state_guard_leave || true
          fail "Completed-run lease audit destination already exists: ${audit}"
        }
        mv -T -- "$queue_lock" "$audit" || {
          queue_state_guard_leave || true
          fail 'Completed-run stale lease retirement failed'
        }
        lease_owned=0
        queue_state_set_owner_assertion ''
        owner_run=''
      else
        validate_completed_lease_audit_under_guard "$audit" "$run_id" "$cleanup_token" "$cleanup_generation"
      fi
    elif [[ -e "$queue_lock" ]]; then
      queue_state_guard_leave || true
      fail 'Completion cleanup invariant failed: lease_required=0 cannot retire a same-run lease'
    fi
    queue_state_transition_completion_cleanup "$marker" planned lease_retired || {
      queue_state_guard_leave || true
      fail 'Cannot record completed lease retirement'
    }
    cleanup_phase=lease_retired
    queue_test_pause after_completed_lease_retirement
  fi
  reconcile_completed_cleanup_phase_postconditions_under_guard "$cleanup_phase" "$run_id" "$cleanup_token" \
    "$cleanup_generation" "$cleanup_lease_required" "$cleanup_batch" "$audit" "$queue_lock" \
    "$batch_pointer" "$pointer" "$active"
  if [[ "$cleanup_phase" == lease_retired ]]; then
    if [[ -e "$batch_pointer" ]]; then
      batch_value="$(<"$batch_pointer")"
      [[ "$cleanup_batch" != none && "$batch_value" == "$cleanup_batch" ]] || {
        queue_state_guard_leave || true
        fail 'current_batch changed during completed-run finalization'
      }
      rm -- "$batch_pointer" || {
        queue_state_guard_leave || true
        fail 'Cannot remove stale current_batch during completed-run finalization'
      }
    fi
    queue_state_transition_completion_cleanup "$marker" lease_retired batch_pointer_removed || {
      queue_state_guard_leave || true
      fail 'Cannot record completed current_batch removal'
    }
    cleanup_phase=batch_pointer_removed
    queue_test_pause after_completed_current_batch_removal
  fi
  if [[ "$cleanup_phase" == batch_pointer_removed ]]; then
    queue_test_pause before_completed_current_removal
    if [[ -e "$pointer" ]]; then
      queue_state_remove_pointer_if_matches "$pointer" "$run_id" "$cleanup_token" "$cleanup_generation" || {
        queue_state_guard_leave || true
        fail 'Current pointer changed during completed-run finalization'
      }
    fi
    queue_state_transition_completion_cleanup "$marker" batch_pointer_removed current_removed || {
      queue_state_guard_leave || true
      fail 'Cannot record completed current removal'
    }
    cleanup_phase=current_removed
    queue_test_pause after_completed_current_removal
  fi
  if [[ "$cleanup_phase" == current_removed ]]; then
    [[ ! -e "$queue_lock" && ! -L "$queue_lock" && ! -e "$batch_pointer" && ! -L "$batch_pointer" && \
       ! -e "$pointer" && ! -L "$pointer" && ! -e "$active" && ! -L "$active" ]] || {
      queue_state_guard_leave || true
      fail 'Completion cleanup final verification failed before terminal transition'
    }
    if [[ "$cleanup_lease_required" == 1 ]]; then
      [[ -e "$audit" ]] || {
        queue_state_guard_leave || true
        fail "Completion cleanup final verification requires finalized lease audit ${audit}"
      }
      validate_completed_lease_audit_under_guard "$audit" "$run_id" "$cleanup_token" "$cleanup_generation"
    elif [[ -e "$audit" || -L "$audit" ]]; then
      queue_state_guard_leave || true
      fail "Completion cleanup final verification forbids unexpected lease audit ${audit}"
    fi
    queue_test_pause before_completion_cleanup_terminal
    queue_state_transition_completion_cleanup "$marker" current_removed completed || {
      queue_state_guard_leave || true
      fail 'Cannot mark completed-run cleanup terminal'
    }
    cleanup_phase=completed
  fi
  if [[ "$cleanup_phase" == completed ]]; then
    [[ ! -e "$queue_lock" && ! -L "$queue_lock" && ! -e "$batch_pointer" && ! -L "$batch_pointer" && \
       ! -e "$pointer" && ! -L "$pointer" && ! -e "$active" && ! -L "$active" ]] || {
      queue_state_guard_leave || true
      fail 'Completion cleanup terminal invariant failed: same-run control-plane residue remains'
    }
    if [[ "$cleanup_lease_required" == 1 ]]; then
      [[ -e "$audit" ]] || {
        queue_state_guard_leave || true
        fail "Completion cleanup terminal invariant failed: required lease audit is missing: ${audit}"
      }
      validate_completed_lease_audit_under_guard "$audit" "$run_id" "$cleanup_token" "$cleanup_generation"
    elif [[ -e "$audit" || -L "$audit" ]]; then
      queue_state_guard_leave || true
      fail "Completion cleanup terminal invariant failed: unexpected lease audit exists: ${audit}"
    fi
    if [[ -e "$terminal" ]]; then
      if ! queue_state_parse_file "$terminal" completion_cleanup terminal_fields || \
         ! queue_state_validate_file "$terminal" completion_cleanup || \
         [[ "${terminal_fields[run_id]}" != "$run_id" || "${terminal_fields[owner_token]}" != "$cleanup_token" || \
            "${terminal_fields[lease_generation]}" != "$cleanup_generation" || "${terminal_fields[lease_required]}" != "$cleanup_lease_required" || \
            "${terminal_fields[batch_pointer]}" != "$cleanup_batch" || "${terminal_fields[phase]}" != completed ]]; then
        queue_state_guard_leave || true
        fail "Completed-run terminal cleanup identity mismatch: ${terminal}"
      fi
    else
      queue_state_write_completion_cleanup "$terminal" "$run_id" "$cleanup_token" "$cleanup_generation" \
        "$cleanup_lease_required" "$cleanup_batch" completed || {
        queue_state_guard_leave || true
        fail 'Cannot publish completed-run terminal cleanup state'
      }
    fi
    queue_state_require_singleton_path "$marker" required || {
      queue_state_guard_leave || true
      fail "Completion cleanup marker disappeared before terminal removal: ${marker}"
    }
    rm -- "$marker" || {
      queue_state_guard_leave || true
      fail 'Cannot remove terminal completion cleanup marker'
    }
  fi
  queue_state_guard_leave || fail 'Cannot release serialization guard after completed-run finalization'
  run_completed=1
  trap - EXIT INT TERM
  log_info "Queue run ${run_id} is already completed; control plane finalized without rerunning work"
}

main() {
  local issue_count
  local planned_batch_count
  local start_index=0
  local end_index

  local current_pointer current_state pointed_run
  local -A resume_state_fields=()
  parse_queue_bootstrap_arguments "$@"
  validate_queue_private_environment

  require_command git
  enter_repo_root
  reject_linked_worktree_queue_invocation
  require_command awk
  require_command flock
  require_command mktemp
  require_command sed
  require_command sha256sum
  require_command cmp
  require_command find
  require_command stat
  lease_owned=0; run_initialized=0; run_completed=0; active_phase=startup; queue_state_set_owner_assertion ''
  if [[ "$resume_requested" -eq 0 ]]; then
    issue_forge_validate_queue_consumer_config
    validate_queue_private_environment
    parse_queue_arguments "$@"
    ensure_unique_issues
    issue_count="${#issue_numbers[@]}"
    planned_batch_count="$(batch_count_for_queue "$issue_count")"
    if [[ "$planned_batch_count" -gt 1 && "$auto_merge" -ne 1 ]]; then
      fail 'Multiple batches require --auto-merge so each next batch starts from the merged base branch.'
    fi
  fi
  initialize_queue_serialization_guard
  if [[ -e "${CODEX_FLOW_QUEUE_DIR}/lease.state" ]]; then
    fail 'Unsupported legacy queue lease schema/path .work/queue/lease.state; manual migration is required'
  fi
  queue_state_require_singleton_path "${CODEX_FLOW_QUEUE_DIR}/current" optional || \
    fail "Invalid current queue pointer path: ${CODEX_FLOW_QUEUE_DIR}/current"
  if [[ -e "${CODEX_FLOW_QUEUE_DIR}/current" ]] && ! grep -q $'^schema_version\t' "${CODEX_FLOW_QUEUE_DIR}/current"; then
    fail 'Unsupported legacy queue current schema v1; manual migration is required'
  fi
  if [[ "$resume_requested" -eq 1 ]]; then
    if [[ "$resume_target" == current ]]; then
      current_pointer="${CODEX_FLOW_QUEUE_DIR}/current"
      if [[ ! -e "$current_pointer" ]]; then
        resolve_completed_lease_without_current
        if [[ -n "$resolved_completion_run_id" ]]; then
          run_id="$resolved_completion_run_id"
        else
          trap - EXIT INT TERM
          log_info 'No current queue control-plane cleanup is pending; control plane is already finalized'
          return 0
        fi
      else
        queue_state_validate_file "$current_pointer" pointer || fail "Invalid current queue pointer: ${current_pointer}"
        run_id="$(queue_state_read_field "$current_pointer" pointer run_id)"
        [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}/run.state" ]] || fail "Current pointer names unknown queue run ${run_id}"
        current_state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}/run.state" run state)"
      fi
    else
      run_id="$resume_target"; queue_state_require_token 'resume run ID' "$run_id"
    fi
    run_state_dir="${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}"
    [[ -d "$run_state_dir" ]] || fail "Unknown queue run ID: ${run_id}"
    if ! queue_state_parse_file "${run_state_dir}/run.state" run resume_state_fields || \
       ! queue_state_validate_file "${run_state_dir}/run.state" run; then
      fail "Invalid queue run state: ${run_state_dir}/run.state"
    fi
    [[ "${resume_state_fields[run_id]}" == "$run_id" ]] || fail "Run state identity mismatch for ${run_id}"
    current_state="${resume_state_fields[state]}"
    if [[ "$current_state" == completed ]]; then
      install_queue_traps
      finalize_completed_queue_run
      return 0
    fi
    issue_forge_validate_queue_consumer_config
    validate_queue_private_environment
    parse_queue_arguments "$@"
    ensure_unique_issues
    install_queue_traps
    require_command gh
    require_command od
    require_command ps
    require_queue_prompt_templates
    acquire_queue_lease
    queue_test_pause after_acquire
    load_queue_run_state
    issue_count="${#issue_numbers[@]}"
  else
    install_queue_traps
    require_command gh
    require_command od
    require_command ps
    require_queue_prompt_templates
    ensure_clean_worktree 'Working tree must be clean before running the issue queue.'
    current_pointer="${CODEX_FLOW_QUEUE_DIR}/current"
    queue_state_require_singleton_path "$current_pointer" optional || fail "Invalid current queue pointer path: ${current_pointer}"
    if [[ -e "$current_pointer" ]]; then
      queue_state_validate_file "$current_pointer" pointer || fail "Invalid current queue pointer: ${current_pointer}"
      pointed_run="$(queue_state_read_field "$current_pointer" pointer run_id)"
      [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed_run}/run.state" ]] || fail "Current pointer names unknown queue run ${pointed_run}"
      current_state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed_run}/run.state" run state)"
      if [[ "$current_state" == completed ]]; then
        fail "Current pointer names completed run ${pointed_run}; finalize control-plane cleanup with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${pointed_run}"
      fi
      fail "Current pointer names unfinished run ${pointed_run}; resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${pointed_run}"
    fi
    run_id="$(queue_state_generate_run_id "$CODEX_FLOW_QUEUE_RUNS_DIR")"
    initialize_queue_run_minimal
    acquire_queue_lease
    complete_queue_run_initialization
    queue_test_pause after_acquire
    ensure_planned_batch_branches_available
  fi
  print_resume_hint
  queue_failpoint after_lease_before_issue_fetch

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    process_batch "$start_index" "$end_index"
    start_index="$end_index"
  done
  queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" running completed
  queue_test_pause after_run_completed_before_current_cleanup
  queue_failpoint after_run_completed_before_current_cleanup
  finalize_completed_queue_run
}

main "$@"
