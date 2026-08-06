#!/usr/bin/env bash
set -euo pipefail

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

fail() {
  printf '[queue] %s\n' "$1" >&2
  exit 1
}

queue_failpoint() {
  [[ "${CODEX_FLOW_QUEUE_FAILPOINT:-}" != "$1" ]] || fail "Queue failpoint triggered: $1"
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

queue_owner_token() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

canonical_repository_identity() {
  local remote
  remote="$(git config --get remote.origin.url)" || fail 'Missing remote.origin.url'
  queue_state_canonical_repository_identity "$remote" || fail 'Cannot derive canonical repository identity from remote.origin.url'
}

print_resume_hint() {
  log_info "run ID: ${run_id}"
  log_info "resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${run_id}"
}

release_queue_lease() {
  [[ "${lease_owned:-0}" -eq 1 ]] || return 0
  if ! assert_queue_lease_owned; then
    log_error "Queue lease ownership was lost; refusing to delete replacement lease"
    lease_owned=0
    return 1
  fi
  if ! rm -f -- "${queue_lock}/owner.${lease_owner_token}.state"; then
    log_error 'Queue lease owner record disappeared during compare-and-delete'
    lease_owned=0
    return 1
  fi
  if ! rmdir -- "$queue_lock"; then
    log_error 'Queue lease changed during compare-and-delete; replacement was not deleted'
    lease_owned=0
    return 1
  fi
  lease_owned=0
}

assert_queue_lease_owned() {
  local record="${queue_lock}/owner.${lease_owner_token}.state"
  [[ "${lease_owned:-0}" -eq 1 && -f "$record" ]] || { log_error "Queue lease ownership lost for run ${run_id}"; return 1; }
  queue_state_validate_file "$record" lease >/dev/null || return 1
  [[ "$(queue_state_read_field "$record" lease owner_token)" == "$lease_owner_token" && \
     "$(queue_state_read_field "$record" lease lease_generation)" == "$lease_generation" && \
     "$(queue_state_read_field "$record" lease run_id)" == "$run_id" && \
     "$(queue_state_read_field "$record" lease owner_pid)" == "$$" && \
     "$(queue_state_read_field "$record" lease owner_host)" == "$lease_owner_host" ]] || {
    log_error "Queue lease fencing identity no longer matches run ${run_id}"; return 1;
  }
}

record_abnormal_exit() {
  local status="$1" signal_name="${2:-}" current
  trap - EXIT INT TERM
  if [[ "${run_initialized:-0}" -eq 1 && "${run_completed:-0}" -ne 1 ]]; then
    current="$(queue_state_read_field "${run_state_dir}/run.state" run state 2>/dev/null || true)"
    if [[ "$current" == running ]]; then
      if [[ -n "$signal_name" ]]; then
        queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" running interrupted || true
      else
        queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" running failed || true
      fi
    fi
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" run "${active_phase:-queue}" "${signal_name:+interrupted}" 2>/dev/null || \
      queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" run "${active_phase:-queue}" failed 2>/dev/null || true
    print_resume_hint >&2
  fi
  release_queue_lease
  if [[ -n "$signal_name" ]]; then exit "$status"; fi
  exit "$status"
}

install_queue_traps() {
  trap 'record_abnormal_exit $? ' EXIT
  trap 'record_abnormal_exit 130 INT' INT
  trap 'record_abnormal_exit 143 TERM' TERM
}

acquire_queue_lease() {
  local owner_host owner_pid owner_run owner_token owner_generation owner_start local_host local_start record audit
  mkdir -p "$CODEX_FLOW_QUEUE_DIR"; queue_lock="${CODEX_FLOW_QUEUE_DIR}/lease.lock"; local_host="$(queue_host_identity)"
  lease_owner_token="$(queue_owner_token)"; lease_owner_host="$local_host"; local_start="$(queue_process_start_identity "$$")"; lease_generation=1
  if ! queue_state_acquire_lease_directory "$queue_lock"; then
    record="$(find "$queue_lock" -maxdepth 1 -type f -name 'owner.*.state' -print 2>/dev/null | LC_ALL=C sort)"
    [[ -n "$record" && "$record" != *$'\n'* ]] || fail "Invalid queue lease requires manual repair: ${queue_lock}"
    queue_state_validate_file "$record" lease || fail "Invalid queue lease requires manual repair: ${queue_lock}"
    owner_run="$(queue_state_read_field "$record" lease run_id)"; owner_host="$(queue_state_read_field "$record" lease owner_host)"
    owner_pid="$(queue_state_read_field "$record" lease owner_pid)"; owner_token="$(queue_state_read_field "$record" lease owner_token)"
    owner_generation="$(queue_state_read_field "$record" lease lease_generation)"; owner_start="$(queue_state_read_field "$record" lease process_start)"
    if [[ "$resume_requested" -ne 1 || "$owner_run" != "$run_id" ]]; then
      log_error "Queue lease records unfinished run ${owner_run}; resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${owner_run}"
      fail "Queue lease run ${owner_run} conflicts with requested run ${run_id}"
    fi
    if [[ "$owner_host" == "$local_host" ]]; then
      if kill -0 "$owner_pid" 2>/dev/null && { [[ "$owner_start" == unavailable ]] || [[ "$(queue_process_start_identity "$owner_pid")" == "$owner_start" ]]; }; then
        fail "Queue run is leased by live same-host PID ${owner_pid} on ${owner_host}"
      fi
      log_info "recovering dead same-host lease for explicit resume ${run_id}"
    elif [[ "$take_over_lease" -ne 1 ]]; then
      fail "Queue lease belongs to different or unverifiable host ${owner_host}; resume ${run_id} with --take-over-lease"
    else
      log_info "explicitly taking over lease from host ${owner_host}; operator asserts the old process has stopped"
    fi
    lease_generation=$((owner_generation + 1)); audit="${CODEX_FLOW_QUEUE_DIR}/lease.displaced.${owner_generation}.${owner_token}"
    mv -- "$queue_lock" "$audit" 2>/dev/null || fail 'Queue lease changed while attempting takeover; retry'
    queue_state_acquire_lease_directory "$queue_lock" || fail 'Another runner acquired the queue lease during takeover'
  fi
  record="${queue_lock}/owner.${lease_owner_token}.state"
  queue_state_write_lease "$record" "$run_id" "$lease_owner_token" "$lease_generation" "$$" "$local_host" "$local_start" \
    "${owner_run:-none}" "${owner_token:-none}" "${owner_generation:-none}"
  lease_owned=1; QUEUE_STATE_ASSERT_OWNED_FUNCTION=assert_queue_lease_owned
}

initialize_queue_run_state() {
  local ordered
  run_state_dir="${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}"
  ordered="$(join_issue_numbers "${issue_numbers[@]}")"
  mkdir -p "$run_state_dir"
  queue_state_create_manifest "$run_state_dir" "$run_id" "$ordered" "$review_every" "$draft_pr" "$auto_merge" \
    "$([[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -eq 0 ]] && printf 0 || printf 1)" "$batch_review_effort" "$batch_review_fix_effort" \
    "$batch_check_fix_effort" "$CODEX_FLOW_BASE_BRANCH" "$CODEX_FLOW_BASE_REF" "$(canonical_repository_identity)"
  queue_state_create_run "${run_state_dir}/run.state" "$run_id" planned
  run_initialized=1
  reconcile_current_pointer
  print_resume_hint
  queue_failpoint after_minimal_run_publication
  reconcile_queue_run_entities
  queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" planned running
}

validate_initial_entity() {
  local file="$1" schema="$2" label="$3"; shift 3
  local pair key expected
  queue_state_validate_file "$file" "$schema" || fail "Invalid existing ${label}: ${file}"
  for pair in "$@"; do key="${pair%%=*}"; expected="${pair#*=}"
    [[ "$(queue_state_read_field "$file" "$schema" "$key")" == "$expected" ]] || fail "Immutable ${label} field ${key} differs in ${file}"
  done
}

reconcile_queue_run_entities() {
  local start=0 end first last batch_id branch state_dir artifact index batch_file issue_file
  while [[ "$start" -lt "${#issue_numbers[@]}" ]]; do
    end=$((start + review_every)); [[ "$end" -le "${#issue_numbers[@]}" ]] || end="${#issue_numbers[@]}"
    first="${issue_numbers[$start]}"; last="${issue_numbers[$((end - 1))]}"
    batch_id="$(batch_id_for_range "$first" "$last")"; branch="$(batch_branch_name_for_range "$first" "$last")"
    state_dir="${run_state_dir}/batches/${batch_id}"; artifact="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    batch_file="${state_dir}/batch.state"
    if [[ -f "$batch_file" ]]; then
      validate_initial_entity "$batch_file" batch "batch ${batch_id}" "run_id=${run_id}" "batch_id=${batch_id}" "first_issue=${first}" "last_issue=${last}" "branch=${branch}" "artifact_path=${artifact}"
    else
      queue_state_create_batch "$batch_file" "$run_id" "$batch_id" "$first" "$last" "$branch" "$artifact"
    fi
    mkdir -p "${state_dir}/issues"
    for ((index = start; index < end; index += 1)); do
      issue_file="${state_dir}/issues/${issue_numbers[$index]}.state"
      if [[ -f "$issue_file" ]]; then
        validate_initial_entity "$issue_file" issue "Issue ${issue_numbers[$index]}" "run_id=${run_id}" "batch_id=${batch_id}" "issue_number=${issue_numbers[$index]}"
      else
        queue_state_create_issue "$issue_file" "$run_id" "$batch_id" "${issue_numbers[$index]}"
      fi
    done
    start="$end"
  done
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
  CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW="${manifest_fields[light_issue_review]}"
  run_initialized=1
  existing_run_state="$(queue_state_read_field "${run_state_dir}/run.state" run state)"
  [[ "$existing_run_state" != completed ]] || fail "Queue run ${run_id} is already completed"
  reconcile_queue_run_entities
  reconcile_current_pointer
  case "$existing_run_state" in
    running) ;;
    interrupted|failed|manual_review_required)
      queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" "$(queue_state_read_field "${run_state_dir}/run.state" run state)" running ;;
    planned) queue_state_transition "${run_state_dir}/run.state" run "run ${run_id}" planned running ;;
    *) fail "Queue run ${run_id} is not resumable" ;;
  esac
}

append_issue_context_to_batch_file() {
  local issue_number="$1"
  local issue_file="$2"
  local issues_file="$3"

  {
    printf '## Issue #%s\n\n' "$issue_number"
    cat "$issue_file"
    printf '\n'
  } >> "$issues_file"
}

archive_issue_codex_artifacts() {
  local batch_dir="$1"
  local issue_number="$2"
  local destination="${batch_dir}/issues/${issue_number}/codex"

  if [[ ! -d "$CODEX_FLOW_CODEX_DIR" ]]; then
    fail "Missing Codex artifact directory after issue ${issue_number}: ${CODEX_FLOW_CODEX_DIR}"
  fi

  if [[ -e "$destination" ]]; then
    fail "Codex archive destination already exists: ${destination}"
  fi

  mkdir -p "$(dirname "$destination")"
  cp -R "$CODEX_FLOW_CODEX_DIR" "$destination"
}

create_batch_branch() {
  local branch_name="$1"

  log_info "fetching origin/${CODEX_FLOW_BASE_BRANCH}"
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
  require_flow_base_ref
  log_info "creating batch branch ${branch_name}"
  git switch --create "$branch_name" "$CODEX_FLOW_BASE_REF"
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
  local issue_state commit_sha recorded_sha artifact_rel destination expected_message

  assert_queue_lease_owned || fail "Queue lease lost before Issue ${issue_number}"
  issue_state="$(queue_state_read_field "$issue_state_file" issue state)"
  [[ "$issue_state" != acknowledged ]] || return 0

  ensure_clean_worktree "Working tree must be clean before processing issue ${issue_number}."
  artifact_rel=".work/queue/batches/${current_batch_id}/issues/${issue_number}/codex"
  destination="${CODEX_FLOW_REPO_ROOT}/${artifact_rel}"
  expected_message="chore: address issue #${issue_number}"

  if [[ "$issue_state" == artifacts_archived ]]; then
    recorded_sha="$(queue_state_read_field "$issue_state_file" issue commit_sha)"
    [[ -d "$destination" ]] || fail "Recorded archive is missing for Issue ${issue_number}: ${artifact_rel}"
    git merge-base --is-ancestor "$recorded_sha" HEAD || fail "Recorded Issue ${issue_number} commit is not an ancestor of HEAD"
    [[ "$(git show -s --format=%s "$recorded_sha")" == "$expected_message" ]] || fail "Recorded Issue ${issue_number} commit message does not match"
    [[ "$(git branch --show-current)" == "$batch_branch" ]] || fail "Issue ${issue_number} is not on expected branch ${batch_branch}"
    [[ "$(queue_state_read_field "$issue_state_file" issue artifact_path)" == "$artifact_rel" ]] || fail "Issue ${issue_number} archive ownership does not match its manifest entity"
    ensure_clean_worktree "Issue ${issue_number} cannot be acknowledged with a dirty worktree."
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" artifacts_archived acknowledged "$recorded_sha" "$artifact_rel"
    return 0
  fi

  if [[ "$issue_state" == planned ]]; then queue_state_transition "$issue_state_file" issue "Issue ${issue_number}" planned leased; issue_state=leased; fi

  active_phase="issue_context_fetch"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_context_fetch before
  log_info "fetching issue ${issue_number}"
  if [[ "$issue_state" == leased ]]; then
    write_issue_context_file "$issue_number"
  elif [[ ! -f "$(issue_file_path "$issue_number")" ]]; then
    fail "Missing durable Issue ${issue_number} context while resuming state ${issue_state}"
  fi
  queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_context_fetch after
  issue_file="$(require_issue_file "$issue_number")"
  if ! grep -Fqx "## Issue #${issue_number}" "$issues_file" 2>/dev/null; then append_issue_context_to_batch_file "$issue_number" "$issue_file" "$issues_file"; fi

  issue_base_commit="$(queue_state_read_field "$issue_state_file" issue base_commit)"
  if [[ "$issue_base_commit" == none ]]; then
    issue_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
    queue_state_set_issue_base "$issue_state_file" leased "$issue_base_commit"
  fi
  active_phase="issue_bootstrap"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_bootstrap before
  write_current_issue_branch_state "$issue_number" "$batch_branch" "$issue_base_commit"
  queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_bootstrap after

  if [[ "$issue_state" == leased ]]; then queue_state_transition "$issue_state_file" issue "Issue ${issue_number}" leased running; issue_state=running; fi

  if [[ "$issue_state" == running ]]; then
    commit_sha=''
    if [[ "$(git show -s --format=%s HEAD)" == "$expected_message" ]]; then
      commit_sha="$(git rev-parse HEAD)"
      queue_failpoint after_issue_flow_commit
      git merge-base --is-ancestor "$issue_base_commit" "$commit_sha" || fail "Existing Issue ${issue_number} commit is not based on its saved base"
      log_info "reconciled existing commit ${commit_sha} for issue ${issue_number}"
    else
      rm -rf "$CODEX_FLOW_CODEX_DIR"
      active_phase="issue_flow"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_flow before

      log_info "running issue flow for issue ${issue_number}"
      if [[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -ne 0 ]]; then issue_light_review=1; fi
      CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_LIGHT_ISSUE_REVIEW="$issue_light_review" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"
      queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_flow after
      commit_sha="$(git rev-parse HEAD)"
    fi
    active_phase="issue_commit_reconciliation"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_commit_reconciliation before
    [[ "$(git show -s --format=%s "$commit_sha")" == "$expected_message" ]] || fail "Issue ${issue_number} commit message is not deterministic"
    ensure_clean_worktree "Issue ${issue_number} flow left uncommitted repository changes."
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" running committed "$commit_sha" none
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" issue_commit_reconciliation after
    issue_state=committed
  fi

  recorded_sha="$(queue_state_read_field "$issue_state_file" issue commit_sha)"
  if [[ "$issue_state" == committed ]]; then
    active_phase="artifact_archive"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" artifact_archive before
    if [[ -d "$destination" ]]; then
      [[ -f "${destination}/implementation.prompt.md" ]] || fail "Existing archive for Issue ${issue_number} is incomplete"
    else
      archive_issue_codex_artifacts "$batch_dir" "$issue_number"
    fi
    queue_failpoint after_artifact_archive
    queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" committed artifacts_archived "$recorded_sha" "$artifact_rel"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "issue-${issue_number}" artifact_archive after
  fi
  ensure_clean_worktree "Issue ${issue_number} flow left uncommitted repository changes."
  [[ -d "$destination" ]] || fail "Issue ${issue_number} archive validation failed"
  [[ "$(git branch --show-current)" == "$batch_branch" ]] || fail "Issue ${issue_number} is not on expected branch ${batch_branch}"
  queue_state_update_issue "$issue_state_file" "Issue ${issue_number}" artifacts_archived acknowledged "$recorded_sha" "$artifact_rel"
  rm -rf "$CODEX_FLOW_CODEX_DIR"
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
  local head_sha

  head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
  log_info "enabling auto-merge for batch PR #${pr_number}"
  gh pr merge "$pr_number" --auto --squash --delete-branch --match-head-commit "$head_sha"
  wait_for_batch_pr_merge "$pr_number"
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
}

process_batch() {
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
  local publish_state_file publish_line published_state published_merged published_head published_base published_sha

  assert_queue_lease_owned || fail 'Queue lease lost before batch phase'
  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  current_batch_id="$batch_id"
  batch_state_file="${run_state_dir}/batches/${batch_id}/batch.state"
  publish_state_file="${run_state_dir}/batches/${batch_id}/publish.state"
  batch_state="$(queue_state_read_field "$batch_state_file" batch state)"
  [[ "$batch_state" != completed ]] || return 0
  issues_file="${batch_dir}/issues.txt"

  mkdir -p "${batch_dir}/history"
  [[ -f "${batch_dir}/token-usage.tsv" ]] || initialize_batch_token_usage_tsv "$batch_dir"
  [[ -f "$issues_file" ]] || : > "$issues_file"
  printf '%s\n' "$batch_id" > "${CODEX_FLOW_QUEUE_DIR}/current_batch"

  if [[ "$batch_state" == planned ]]; then
    active_phase="batch_branch_preparation"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_branch_preparation before
    if git show-ref --verify --quiet "refs/heads/${batch_branch}"; then
      git switch "$batch_branch"
    else
      create_batch_branch "$batch_branch"
    fi
    batch_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
    printf '%s\n' "$batch_base_commit" > "${batch_dir}/base_commit"
    queue_state_update_batch "$batch_state_file" "$batch_id" planned branch_ready "$batch_base_commit"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_branch_preparation after
    batch_state=branch_ready
  else
    [[ "$(git branch --show-current)" == "$batch_branch" ]] || git switch "$batch_branch"
    batch_base_commit="$(queue_state_read_field "$batch_state_file" batch base_commit)"
    [[ "$batch_base_commit" != none ]] || fail "Batch ${batch_id} lacks its durable base commit"
  fi
  if [[ "$batch_state" == branch_ready ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" branch_ready issues_running; batch_state=issues_running; fi

  for ((index = start_index; index < end_index; index += 1)); do
    batch_issues+=("${issue_numbers[$index]}")
    process_issue_on_batch_branch "${issue_numbers[$index]}" "$batch_branch" "$batch_dir" "$issues_file"
  done

  for ((index = start_index; index < end_index; index += 1)); do
    [[ "$(queue_state_read_field "${run_state_dir}/batches/${batch_id}/issues/${issue_numbers[$index]}.state" issue state)" == acknowledged ]] || \
      fail "Batch ${batch_id} cannot continue before Issue ${issue_numbers[$index]} is acknowledged"
  done

  batch_issues_label="$(join_issue_numbers "${batch_issues[@]}")"

  if [[ "$batch_state" == issues_running ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" issues_running checks_running; batch_state=checks_running; fi
  if [[ "$batch_state" == checks_running ]]; then
    active_phase="batch_checks"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_checks before
    ensure_batch_checks_pass "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" "$batch_issues_label" "$batch_check_fix_effort"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_checks after
    queue_state_transition "$batch_state_file" batch "$batch_id" checks_running review_running; batch_state=review_running
  fi
  if [[ "$batch_state" == review_running ]]; then
    active_phase="batch_review"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_review before
    ensure_batch_review_accepted \
    "$batch_dir" \
    "$issues_file" \
    "$batch_base_commit" \
    "$first_issue" \
    "$last_issue" \
    "$batch_issues_label" \
    "$batch_review_effort" \
    "$batch_review_fix_effort" \
    "$batch_check_fix_effort"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_review after
    queue_state_transition "$batch_state_file" batch "$batch_id" review_running accepted; batch_state=accepted
  fi

  batch_head_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  printf '%s\n' "$batch_head_commit" > "${batch_dir}/head_commit"
  write_batch_changed_files "$batch_base_commit" "${batch_dir}/changed-files.txt"

  if [[ "$batch_state" == accepted ]]; then queue_state_transition "$batch_state_file" batch "$batch_id" accepted publishing; batch_state=publishing; fi
  active_phase="batch_publish"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_publish before
  if [[ -f "$publish_state_file" ]]; then
    queue_state_validate_file "$publish_state_file" publish
    batch_pr_number="$(queue_state_read_field "$publish_state_file" publish pr_number)"
    _batch_pr_url="$(queue_state_read_field "$publish_state_file" publish pr_url)"
    publish_line="$(gh pr view "$batch_pr_number" --json state,mergedAt,headRefName,baseRefName,headRefOid --jq '[.state, (.mergedAt // ""), .headRefName, .baseRefName, .headRefOid] | @tsv')"
    IFS=$'\t' read -r published_state published_merged published_head published_base published_sha <<< "$publish_line"
    [[ "$published_state" == OPEN || "$published_state" == MERGED ]] || fail "Published PR #${batch_pr_number} has unexpected state ${published_state}"
    [[ "$published_head" == "$batch_branch" && "$published_base" == "$CODEX_FLOW_BASE_BRANCH" && "$published_sha" == "$(queue_state_read_field "$publish_state_file" publish head_sha)" ]] || \
      fail "Published PR #${batch_pr_number} does not match expected head/base/SHA for ${batch_id}"
  else
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
      "$CODEX_FLOW_BASE_BRANCH" "$(git rev-parse HEAD)" open
  fi
  queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" batch_publish after

  if [[ "$auto_merge" -eq 1 && -z "${published_merged:-}" ]]; then
    active_phase="auto_merge"; queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" auto_merge before
    auto_merge_batch_pr "$batch_pr_number"
    queue_state_checkpoint "${run_state_dir}/checkpoint.state" "$run_id" "$batch_id" auto_merge after
    queue_state_record_publish "$publish_state_file" "$run_id" "$batch_id" "$batch_pr_number" "$_batch_pr_url" "$batch_branch" \
      "$CODEX_FLOW_BASE_BRANCH" "$(git rev-parse HEAD)" merged
  fi
  queue_state_transition "$batch_state_file" batch "$batch_id" publishing completed
  assert_queue_lease_owned || fail 'Queue lease lost after batch phase'
}

main() {
  local issue_count
  local planned_batch_count
  local start_index=0
  local end_index

  local arg resume_option_count=0 allowed_resume_args=0 current_pointer current_state pointed_run
  for arg in "$@"; do [[ "$arg" == --resume ]] && resume_option_count=$((resume_option_count + 1)); done
  if [[ "$resume_option_count" -gt 0 ]]; then
    for arg in "$@"; do case "$arg" in --resume|--take-over-lease|current|[A-Za-z0-9._-]*) allowed_resume_args=$((allowed_resume_args + 1));; *) fail '--resume rejects queue-shaping options and Issue arguments';; esac; done
    [[ "$#" -eq 2 || ( "$#" -eq 3 && " $* " == *' --take-over-lease '* ) ]] || fail '--resume accepts only a run ID/current and optional --take-over-lease'
  fi
  parse_queue_arguments "$@"
  ensure_unique_issues

  issue_count="${#issue_numbers[@]}"
  if [[ "$resume_requested" -eq 0 ]]; then
  planned_batch_count="$(batch_count_for_queue "$issue_count")"
  if [[ "$planned_batch_count" -gt 1 && "$auto_merge" -ne 1 ]]; then
    fail 'Multiple batches require --auto-merge so each next batch starts from the merged base branch.'
  fi
  fi

  require_command awk
  require_command gh
  require_command git
  require_command mktemp
  require_command od
  require_command sed

  enter_repo_root
  require_queue_prompt_templates
  lease_owned=0; run_initialized=0; run_completed=0; active_phase=startup; QUEUE_STATE_ASSERT_OWNED_FUNCTION=''
  if [[ "$resume_requested" -eq 1 ]]; then
    if [[ "$resume_target" == current ]]; then
      current_pointer="${CODEX_FLOW_QUEUE_DIR}/current"
      [[ -f "$current_pointer" ]] || fail 'No current resumable queue run is published'
      queue_state_validate_file "$current_pointer" pointer || fail "Invalid current queue pointer: ${current_pointer}"
      run_id="$(queue_state_read_field "$current_pointer" pointer run_id)"
      [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}/run.state" ]] || fail "Current pointer names unknown queue run ${run_id}"
      current_state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}/run.state" run state)"
      if [[ "$current_state" == completed ]]; then
        queue_state_remove_pointer_if_matches "$current_pointer" "$run_id" || fail 'Current pointer changed while repairing completed run'
        fail 'No current resumable queue run is published (removed stale completed pointer)'
      fi
    else
      run_id="$resume_target"; queue_state_require_token 'resume run ID' "$run_id"
    fi
    run_state_dir="${CODEX_FLOW_QUEUE_RUNS_DIR}/${run_id}"
    [[ -d "$run_state_dir" ]] || fail "Unknown queue run ID: ${run_id}"
    acquire_queue_lease
    install_queue_traps
    load_queue_run_state
    issue_count="${#issue_numbers[@]}"
  else
    ensure_clean_worktree 'Working tree must be clean before running the issue queue.'
    current_pointer="${CODEX_FLOW_QUEUE_DIR}/current"
    if [[ -f "$current_pointer" ]]; then
      queue_state_validate_file "$current_pointer" pointer || fail "Invalid current queue pointer: ${current_pointer}"
      pointed_run="$(queue_state_read_field "$current_pointer" pointer run_id)"
      [[ -f "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed_run}/run.state" ]] || fail "Current pointer names unknown queue run ${pointed_run}"
      current_state="$(queue_state_read_field "${CODEX_FLOW_QUEUE_RUNS_DIR}/${pointed_run}/run.state" run state)"
      [[ "$current_state" == completed ]] || fail "Current pointer names unfinished run ${pointed_run}; resume with: ${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_queue.sh --resume ${pointed_run}"
      queue_state_remove_pointer_if_matches "$current_pointer" "$pointed_run"
    fi
    run_id="$(queue_state_generate_run_id "$CODEX_FLOW_QUEUE_RUNS_DIR")"
    acquire_queue_lease
    install_queue_traps
    ensure_planned_batch_branches_available
    initialize_queue_run_state
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
  queue_failpoint after_run_completed_before_current_cleanup
  assert_queue_lease_owned || fail 'Queue lease lost before completion pointer cleanup'
  queue_state_remove_pointer_if_matches "${CODEX_FLOW_QUEUE_DIR}/current" "$run_id" "$lease_owner_token" "$lease_generation"
  rm -f -- "${CODEX_FLOW_QUEUE_DIR}/current_batch"
  run_completed=1
  release_queue_lease
  trap - EXIT INT TERM
}

main "$@"
