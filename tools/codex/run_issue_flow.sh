#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/history_helpers.sh
source "${SCRIPT_DIR}/lib/history_helpers.sh"
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "${SCRIPT_DIR}/lib/token_usage_helpers.sh"
# shellcheck source=tools/codex/lib/checks_review_helpers.sh
source "${SCRIPT_DIR}/lib/checks_review_helpers.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"
# shellcheck source=tools/codex/lib/prompt_templates.sh
source "${SCRIPT_DIR}/lib/prompt_templates.sh"
# shellcheck source=tools/codex/lib/queue_state.sh
source "${SCRIPT_DIR}/lib/queue_state.sh"

checkpoint_mode=0
checkpoint_lifecycle_started=0
phase='implementation'
phase_dispatch_complete=0

log_info() {
  printf '[flow] %s\n' "$1"
}

log_fail_with_path() {
  printf '[flow] %s\n' "$1" >&2
  printf '[flow] see log: %s\n' "$2" >&2
}

run_codex_phase() {
  local mode="$1"
  local prompt_file="$2"
  local output_file="$3"
  local reasoning_effort="$4"
  local stderr_policy="${5:-combined}"

  case "$stderr_policy" in
    combined)
      CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$output_file" 2>&1
      ;;
    stdout)
      CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$output_file"
      ;;
    *)
      printf 'Invalid Codex phase stderr policy: %s\n' "$stderr_policy" >&2
      exit 1
      ;;
  esac
}

run_implementation_phase() {
  log_info 'codex implementation'
  run_codex_phase write "$implement_prompt" "$implementation_log" "$CODEX_FLOW_IMPLEMENTATION_REASONING"
  archive_round_file "$implementation_log" 'implementation' 0 '.log'
  ensure_issue_token_usage_tsv 'implementation' "$issue_number" 0 "$CODEX_FLOW_IMPLEMENTATION_REASONING" "$implementation_log"

  if [[ -z "$(status_outside_work)" ]]; then
    log_fail_with_path 'initial implementation session produced no file changes' "$implementation_log"
    exit 1
  fi
}

resolve_checkpoint_mode() {
  if [[ -z "${CODEX_FLOW_PHASE_STATE_FILE:-}" ]]; then
    if [[ -n "${CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE:-}" ]]; then
      printf 'CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE requires CODEX_FLOW_PHASE_STATE_FILE.\n' >&2
      exit 1
    fi
    printf '0\n'
    return
  fi

  if [[ -z "${CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE:-}" ]]; then
    printf 'Queue checkpoint mode requires CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE.\n' >&2
    exit 1
  fi

  printf '1\n'
}

write_checkpoint_phase() {
  local status="$1"
  local next_phase="$2"
  local exit_code="${3:-}"

  write_issue_state_tsv "$CODEX_FLOW_PHASE_STATE_FILE" "$status" "$next_phase" "$exit_code"
}

advance_issue_phase() {
  local next_phase="$1"

  if [[ "$checkpoint_mode" -eq 1 ]]; then
    write_checkpoint_phase leased "$next_phase"
  fi
  phase="$next_phase"
}

handle_issue_flow_exit() {
  local original_exit_code="$?"
  local saved_phase

  trap - EXIT
  if [[ "$original_exit_code" -ne 0 && "$checkpoint_lifecycle_started" -eq 1 ]]; then
    set +e
    saved_phase="$(read_state_tsv_value "$CODEX_FLOW_PHASE_STATE_FILE" phase 2>/dev/null)"
    [[ -n "$saved_phase" ]] || saved_phase="$phase"
    write_checkpoint_phase failed "$saved_phase" "$original_exit_code" >/dev/null 2>&1
  fi

  exit "$original_exit_code"
}

initialize_history_rounds() {
  local review_maximum
  local candidate
  local stem

  checks_run_round="$(max_history_round 'checks' '.log')"
  fix_checks_round="$(max_history_round 'fix-from-checks' '.log')"
  fix_review_round="$(max_history_round 'fix-from-review' '.log')"
  review_maximum=0
  for stem in review-diff review-untracked review-summary review-raw review; do
    candidate="$(max_history_round "$stem" '.txt')"
    if [[ "$candidate" -gt "$review_maximum" ]]; then
      review_maximum="$candidate"
    fi
  done
  review_run_round="$review_maximum"
}

existing_review_is_accepted() {
  [[ -f "$review_output" ]] \
    && validate_review_output "$review_output" \
    && validate_review_output_semantics "$review_output" \
    && review_output_accepted "$review_output"
}

write_issue_head_commit() {
  local head_commit="$1"

  printf '%s\n' "$head_commit" | atomic_write_from_stdin "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE"
}

validate_saved_issue_head_commit() {
  local current_head="$1"
  local saved_head
  local resolved_saved_head

  if [[ ! -f "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE" ]]; then
    printf 'Missing Issue head commit checkpoint: %s\n' "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE" >&2
    exit 1
  fi

  saved_head="$(< "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE")"
  if ! resolved_saved_head="$(git rev-parse --verify "${saved_head}^{commit}" 2>/dev/null)"; then
    printf 'Invalid Issue head commit checkpoint in %s: %s\n' "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE" "$saved_head" >&2
    exit 1
  fi

  if [[ "$resolved_saved_head" != "$current_head" ]]; then
    printf 'Current HEAD does not match Issue head commit checkpoint: %s != %s\n' "$current_head" "$resolved_saved_head" >&2
    exit 1
  fi
}

reconcile_checkpoint_entry() {
  local status
  local lease_owner
  local current_head
  local worktree_status

  status="$(read_state_tsv_value "$CODEX_FLOW_PHASE_STATE_FILE" status)"
  phase="$(read_state_tsv_value "$CODEX_FLOW_PHASE_STATE_FILE" phase)"
  lease_owner="$(read_state_tsv_value "$CODEX_FLOW_PHASE_STATE_FILE" lease_owner)"
  if [[ -z "$lease_owner" ]]; then
    printf 'Queue checkpoint Issue state has an empty lease owner: %s\n' "$CODEX_FLOW_PHASE_STATE_FILE" >&2
    exit 1
  fi

  case "$phase" in
    implementation|checks|review|commit)
      case "$status" in
        leased|failed) ;;
        *)
          printf 'Queue checkpoint phase %s requires leased or failed status, found: %s\n' "$phase" "$status" >&2
          exit 1
          ;;
      esac
      ;;
    archive)
      if [[ "$status" != 'committed' ]]; then
        printf 'Queue checkpoint archive phase requires committed status, found: %s\n' "$status" >&2
        exit 1
      fi
      ;;
    *)
      printf 'Unsupported Issue phase for run_issue_flow.sh: %s\n' "$phase" >&2
      exit 1
      ;;
  esac

  checkpoint_lifecycle_started=1
  trap 'handle_issue_flow_exit' EXIT
  if [[ "$phase" != 'archive' ]]; then
    write_checkpoint_phase leased "$phase"
  fi

  current_head="$(git rev-parse --verify 'HEAD^{commit}')"
  worktree_status="$(status_outside_work)"

  case "$phase" in
    implementation)
      if [[ "$current_head" != "$base_commit" && -n "$worktree_status" ]]; then
        printf 'Cannot reconcile implementation phase with both an advanced HEAD and uncommitted Issue changes.\n' >&2
        exit 1
      fi
      if [[ "$current_head" != "$base_commit" ]]; then
        log_info 'reconciled committed changes before implementation phase checkpoint'
        advance_issue_phase commit
      elif [[ -n "$worktree_status" ]]; then
        log_info 'reconciled interrupted implementation changes; continuing with checks'
        advance_issue_phase checks
      fi
      ;;
    checks)
      if [[ "$current_head" != "$base_commit" ]]; then
        printf 'Cannot reconcile %s phase because HEAD advanced from the Issue base commit.\n' "$phase" >&2
        exit 1
      fi
      if [[ -z "$worktree_status" ]]; then
        printf 'Cannot reconcile %s phase without uncommitted Issue changes.\n' "$phase" >&2
        exit 1
      fi
      ;;
    review)
      if [[ "$current_head" != "$base_commit" ]]; then
        printf 'Cannot reconcile review phase because HEAD advanced from the Issue base commit.\n' >&2
        exit 1
      fi
      if [[ -z "$worktree_status" ]]; then
        printf 'Cannot reconcile review phase without uncommitted Issue changes.\n' >&2
        exit 1
      fi
      if ! existing_review_is_accepted; then
        log_info 'reconciling non-accepted review checkpoint through checks'
        advance_issue_phase checks
      fi
      ;;
    commit)
      if [[ "$current_head" != "$base_commit" && -n "$worktree_status" ]]; then
        printf 'Cannot reconcile commit phase with both an advanced HEAD and uncommitted Issue changes.\n' >&2
        exit 1
      fi
      ;;
    archive)
      if [[ -n "$worktree_status" ]]; then
        printf 'Cannot reconcile archive phase with uncommitted Issue changes.\n' >&2
        exit 1
      fi
      if [[ "$current_head" == "$base_commit" ]]; then
        printf 'Cannot reconcile archive phase because HEAD did not advance from the Issue base commit.\n' >&2
        exit 1
      fi
      validate_saved_issue_head_commit "$current_head"
      ;;
  esac
}

run_phase_dispatch() {
  local current_head

  case "$phase" in
    implementation)
      run_implementation_phase
      advance_issue_phase checks
      ;;
    checks)
      ensure_checks_pass
      advance_issue_phase review
      ;;
    review)
      if [[ "$checkpoint_mode" -eq 1 ]] && existing_review_is_accepted; then
        log_info 'reusing valid accepted review checkpoint'
      else
        ensure_review_accepted
      fi
      advance_issue_phase commit
      ;;
    commit)
      current_head="$(git rev-parse --verify 'HEAD^{commit}')"
      if [[ -n "$(status_outside_work)" ]]; then
        commit_issue_changes "chore: address issue #${issue_number}" 1 'Loop finished without repository changes to commit.'
        current_head="$(git rev-parse --verify 'HEAD^{commit}')"
      elif [[ "$checkpoint_mode" -eq 1 && "$current_head" != "$base_commit" ]]; then
        log_info 'reconciled Issue commit completed before phase checkpoint'
      else
        printf 'Loop finished without repository changes to commit.\n' >&2
        exit 1
      fi

      if [[ "$checkpoint_mode" -eq 1 ]]; then
        if [[ -f "$CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE" ]]; then
          validate_saved_issue_head_commit "$current_head"
        else
          write_issue_head_commit "$current_head"
        fi
        write_checkpoint_phase committed archive
      fi
      phase='archive'
      ;;
    archive)
      phase_dispatch_complete=1
      ;;
    *)
      printf 'Unsupported Issue phase for run_issue_flow.sh: %s\n' "$phase" >&2
      exit 1
      ;;
  esac

}

resolve_skip_publish_flag() {
  local value='0'

  if [[ -n "${CODEX_FLOW_SKIP_PUBLISH+x}" ]]; then
    value="$CODEX_FLOW_SKIP_PUBLISH"
  fi

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'CODEX_FLOW_SKIP_PUBLISH must be a non-negative integer: %s\n' "$value" >&2
    exit 1
  fi

  if [[ "$value" -eq 0 ]]; then
    printf '0\n'
    return
  fi

  printf '1\n'
}

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [issue_number]\n' "$0" >&2
  exit 1
fi

require_command awk
require_command git
require_command mktemp
require_command sed

skip_publish="$(resolve_skip_publish_flag)"
checkpoint_mode="$(resolve_checkpoint_mode)"
if [[ "$checkpoint_mode" -eq 1 && "$skip_publish" -ne 1 ]]; then
  printf 'Queue checkpoint mode requires CODEX_FLOW_SKIP_PUBLISH=1.\n' >&2
  exit 1
fi
if [[ "$skip_publish" -eq 0 ]]; then
  require_publish_commands
fi

enter_repo_root

issue_number="$(resolve_numeric_issue_number "${1:-}")"

issue_file="$(require_issue_file "$issue_number")"

current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}. Run the issue bootstrap entrypoint first.")"
base_commit="$(resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first.")"

if [[ "$checkpoint_mode" -eq 0 ]]; then
  ensure_clean_worktree 'Working tree must be clean before running the issue flow.'
fi
mkdir -p "$CODEX_FLOW_CODEX_DIR"
mkdir -p "$CODEX_FLOW_CODEX_HISTORY_DIR"
initialize_issue_token_usage_tsv

implement_prompt="${CODEX_FLOW_CODEX_DIR}/implementation.prompt.md"
fix_checks_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.prompt.md"
review_prompt="${CODEX_FLOW_CODEX_DIR}/review.prompt.md"
fix_review_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-review.prompt.md"

checks_log="${CODEX_FLOW_CODEX_DIR}/checks.log"
implementation_log="${CODEX_FLOW_CODEX_DIR}/implementation.log"
fix_checks_log="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.log"
review_diff="${CODEX_FLOW_CODEX_DIR}/review.diff"
review_untracked="${CODEX_FLOW_CODEX_DIR}/review.untracked.txt"
review_summary="${CODEX_FLOW_CODEX_DIR}/review.summary.txt"
review_raw_output="${CODEX_FLOW_CODEX_DIR}/review.raw.txt"
review_output="${CODEX_FLOW_CODEX_DIR}/review.txt"
fix_review_log="${CODEX_FLOW_CODEX_DIR}/fix-from-review.log"
history_dir="$CODEX_FLOW_CODEX_HISTORY_DIR"
history_allow_overwrite=0
if [[ "$checkpoint_mode" -eq 1 ]]; then
  initialize_history_rounds
else
  history_allow_overwrite=1
  checks_run_round=0
  fix_checks_round=0
  review_run_round=0
  fix_review_round=0
fi

write_issue_flow_prompt_files \
  "$issue_number" \
  "$issue_file" \
  "$implement_prompt" \
  "$fix_checks_prompt" \
  "$review_prompt" \
  "$fix_review_prompt" \
  "$checks_log" \
  "$review_diff" \
  "$review_untracked" \
  "$review_summary" \
  "$review_output"

if [[ "$checkpoint_mode" -eq 1 ]]; then
  reconcile_checkpoint_entry
fi

while [[ "$phase_dispatch_complete" -eq 0 ]]; do
  run_phase_dispatch
done

if [[ "$skip_publish" -ne 0 ]]; then
  log_info 'publish skipped because CODEX_FLOW_SKIP_PUBLISH is set'
  exit 0
fi

publish_issue_results "$issue_number" "$current_branch"
