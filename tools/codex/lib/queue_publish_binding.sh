#!/usr/bin/env bash

queue_publish_binding_error() {
  printf '[queue] Publish state binding validation failed: %s\n' "$1" >&2
  return 1
}

queue_publish_validate_state_file() {
  if declare -F issue_forge_queue_state_validate_file_original >/dev/null 2>&1; then
    issue_forge_queue_state_validate_file_original "$@"
  else
    queue_state_validate_file "$@"
  fi
}

queue_validate_publish_state_binding() {
  local publish_file="$1"
  local manifest_file="$2"
  local batch_file="$3"
  local expected_run="$4"
  local expected_batch="$5"
  local expected_branch="$6"
  local expected_publish_file expected_batch_file
  local -A publish_fields=() manifest_fields=() batch_fields=()

  declare -F queue_state_parse_file >/dev/null 2>&1 \
    || queue_publish_binding_error 'queue state parser is unavailable' \
    || return 1
  declare -F queue_state_validate_file >/dev/null 2>&1 \
    || queue_publish_binding_error 'queue state validator is unavailable' \
    || return 1
  [[ -n "$expected_run" && -n "$expected_batch" && -n "$expected_branch" ]] \
    || queue_publish_binding_error 'current run/batch/branch identity is incomplete' \
    || return 1
  [[ -n "${run_state_dir:-}" ]] \
    || queue_publish_binding_error 'current run state directory is unavailable' \
    || return 1

  expected_publish_file="${run_state_dir}/batches/${expected_batch}/publish.state"
  expected_batch_file="${run_state_dir}/batches/${expected_batch}/batch.state"
  [[ "$publish_file" == "$expected_publish_file" ]] \
    || queue_publish_binding_error "publish path ${publish_file} does not belong to run ${expected_run} batch ${expected_batch}" \
    || return 1
  [[ "$batch_file" == "$expected_batch_file" ]] \
    || queue_publish_binding_error "batch state path ${batch_file} does not belong to run ${expected_run} batch ${expected_batch}" \
    || return 1
  [[ "$manifest_file" == "${run_state_dir}/manifest.state" ]] \
    || queue_publish_binding_error "manifest path ${manifest_file} does not belong to run ${expected_run}" \
    || return 1

  queue_state_parse_file "$manifest_file" manifest manifest_fields \
    || queue_publish_binding_error "invalid run manifest ${manifest_file}" \
    || return 1
  queue_publish_validate_state_file "$manifest_file" manifest \
    || queue_publish_binding_error "invalid run manifest ${manifest_file}" \
    || return 1
  queue_state_parse_file "$batch_file" batch batch_fields \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_publish_validate_state_file "$batch_file" batch \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_state_parse_file "$publish_file" publish publish_fields \
    || queue_publish_binding_error "invalid publish state ${publish_file}" \
    || return 1
  queue_publish_validate_state_file "$publish_file" publish \
    || queue_publish_binding_error "invalid publish state ${publish_file}" \
    || return 1

  [[ "${manifest_fields[run_id]}" == "$expected_run" ]] \
    || queue_publish_binding_error "manifest run ${manifest_fields[run_id]} does not match current run ${expected_run}" \
    || return 1
  [[ "${batch_fields[run_id]}" == "$expected_run" && "${batch_fields[batch_id]}" == "$expected_batch" ]] \
    || queue_publish_binding_error "batch state does not belong to current run ${expected_run} batch ${expected_batch}" \
    || return 1
  [[ "${batch_fields[branch]}" == "$expected_branch" ]] \
    || queue_publish_binding_error "batch branch ${batch_fields[branch]} does not match current branch identity ${expected_branch}" \
    || return 1
  [[ "${batch_fields[state]}" == publishing || "${batch_fields[state]}" == completed ]] \
    || queue_publish_binding_error "publish state exists while batch ${expected_batch} is ${batch_fields[state]}" \
    || return 1
  [[ "${batch_fields[accepted_head]}" != none ]] \
    || queue_publish_binding_error "batch ${expected_batch} has no accepted head" \
    || return 1

  [[ "${publish_fields[run_id]}" == "$expected_run" ]] \
    || queue_publish_binding_error "publish run ${publish_fields[run_id]} does not match current run ${expected_run}" \
    || return 1
  [[ "${publish_fields[batch_id]}" == "$expected_batch" ]] \
    || queue_publish_binding_error "publish batch ${publish_fields[batch_id]} does not match current batch ${expected_batch}" \
    || return 1
  [[ "${publish_fields[head_branch]}" == "$expected_branch" ]] \
    || queue_publish_binding_error "publish head branch ${publish_fields[head_branch]} does not match batch branch ${expected_branch}" \
    || return 1
  [[ "${publish_fields[base_branch]}" == "${manifest_fields[base_branch]}" ]] \
    || queue_publish_binding_error "publish base branch ${publish_fields[base_branch]} does not match manifest base ${manifest_fields[base_branch]}" \
    || return 1
  [[ "${publish_fields[head_sha]}" == "${batch_fields[accepted_head]}" ]] \
    || queue_publish_binding_error "publish head ${publish_fields[head_sha]} does not match accepted head ${batch_fields[accepted_head]}" \
    || return 1

  if [[ -n "${batch_head_commit:-}" && "$batch_head_commit" != "${batch_fields[accepted_head]}" ]]; then
    queue_publish_binding_error "current publication head ${batch_head_commit} does not match accepted head ${batch_fields[accepted_head]}"
    return 1
  fi
}

queue_validate_publish_state_binding_from_scope() {
  local publish_file="${publish_state_file:-}"
  local expected_batch="${batch_id:-${current_batch_id:-}}"
  local expected_branch="${batch_branch:-}"
  local batch_file="${batch_state_file:-}"

  [[ -n "$publish_file" && -e "$publish_file" ]] || return 0
  [[ -n "${run_id:-}" && -n "${run_state_dir:-}" ]] \
    || queue_publish_binding_error 'publish state is present outside an identified queue run' \
    || return 1
  [[ -n "$expected_batch" && -n "$expected_branch" ]] \
    || queue_publish_binding_error 'publish state is present outside an identified batch' \
    || return 1
  [[ -n "$batch_file" ]] || batch_file="${run_state_dir}/batches/${expected_batch}/batch.state"

  queue_validate_publish_state_binding \
    "$publish_file" \
    "${run_state_dir}/manifest.state" \
    "$batch_file" \
    "$run_id" \
    "$expected_batch" \
    "$expected_branch"
}

queue_pr_reconciliation_error() {
  printf '[queue] PR reconciliation failed: %s\n' "$1" >&2
  return 1
}

queue_reconcile_batch_pr_state() {
  local publish_file="$1" batch_file="$2" expected_run="$3" expected_batch="$4"
  local expected_branch="$5" expected_head="$6" state_output="$7" number_output="$8" url_output="$9"
  local existing=0 lines='' line pr_number pr_url pr_state merged_at head base sha extra resolved_state
  local stored_number='' stored_url='' stored_state=''
  local -a records=()

  if [[ -e "$publish_file" ]]; then
    existing=1
    queue_validate_publish_state_binding "$publish_file" "${run_state_dir}/manifest.state" "$batch_file" \
      "$expected_run" "$expected_batch" "$expected_branch" || return 1
    stored_number="$(queue_state_read_field "$publish_file" publish pr_number)" || return 1
    stored_url="$(queue_state_read_field "$publish_file" publish pr_url)" || return 1
    stored_state="$(queue_state_read_field "$publish_file" publish state)" || return 1
    if ! line="$(command gh pr view "$stored_number" \
      --json state,mergedAt,headRefName,baseRefName,headRefOid \
      --jq '[.state, (.mergedAt // ""), .headRefName, .baseRefName, .headRefOid] | @tsv')"; then
      queue_pr_reconciliation_error "cannot read recorded PR #${stored_number}"
      return 1
    fi
    line="$(printf '%s\n' "$line" | awk -F '\t' 'BEGIN { OFS = "\t" } { if ($2 == "") $2 = "none"; print }')"
    line="${stored_number}"$'\t'"${stored_url}"$'\t'"${line}"
  else
    if ! lines="$(command gh pr list \
      --head "$expected_branch" \
      --base "$CODEX_FLOW_BASE_BRANCH" \
      --state all \
      --json number,url,state,mergedAt,headRefName,baseRefName,headRefOid \
      --jq '.[] | [.number, .url, .state, (.mergedAt // "none"), .headRefName, .baseRefName, .headRefOid] | @tsv')"; then
      queue_pr_reconciliation_error "cannot query PRs for ${expected_branch}"
      return 1
    fi
    if [[ -z "$lines" ]]; then
      printf -v "$state_output" '%s' none
      printf -v "$number_output" '%s' ''
      printf -v "$url_output" '%s' ''
      return 0
    fi
    mapfile -t records <<< "$lines"
    line=''
    local candidate candidate_number candidate_url candidate_state candidate_merged candidate_head candidate_base candidate_sha candidate_extra
    for candidate in "${records[@]}"; do
      IFS=$'\t' read -r candidate_number candidate_url candidate_state candidate_merged candidate_head candidate_base candidate_sha candidate_extra <<< "$candidate"
      [[ -n "$candidate_number" && "$candidate_number" =~ ^[0-9]+$ && -n "$candidate_url" && -z "${candidate_extra:-}" ]] \
        || queue_pr_reconciliation_error "malformed PR identity: ${candidate}" \
        || return 1
      [[ "$candidate_head" == "$expected_branch" && "$candidate_base" == "$CODEX_FLOW_BASE_BRANCH" ]] \
        || queue_pr_reconciliation_error "PR #${candidate_number} does not match expected head/base ${expected_branch}/${CODEX_FLOW_BASE_BRANCH}" \
        || return 1
      if [[ "$candidate_sha" == "$expected_head" ]]; then
        [[ -z "$line" ]] \
          || queue_pr_reconciliation_error "ambiguous PR lookup for ${expected_branch}" \
          || return 1
        line="$candidate"
      elif [[ "$candidate_state" == OPEN ]]; then
        queue_pr_reconciliation_error "open PR #${candidate_number} head ${candidate_sha} does not match accepted head ${expected_head}"
        return 1
      fi
    done
    if [[ -z "$line" ]]; then
      printf -v "$state_output" '%s' none
      printf -v "$number_output" '%s' ''
      printf -v "$url_output" '%s' ''
      return 0
    fi
  fi

  IFS=$'\t' read -r pr_number pr_url pr_state merged_at head base sha extra <<< "$line"
  [[ -n "$pr_number" && "$pr_number" =~ ^[0-9]+$ && -n "$pr_url" && -z "${extra:-}" ]] \
    || queue_pr_reconciliation_error "malformed PR identity: ${line}" \
    || return 1
  [[ "$head" == "$expected_branch" && "$base" == "$CODEX_FLOW_BASE_BRANCH" ]] \
    || queue_pr_reconciliation_error "PR #${pr_number} does not match expected head/base ${expected_branch}/${CODEX_FLOW_BASE_BRANCH}" \
    || return 1
  [[ "$sha" == "$expected_head" ]] \
    || queue_pr_reconciliation_error "PR #${pr_number} head ${sha} does not match accepted head ${expected_head}" \
    || return 1

  if [[ "$pr_state" == MERGED || ( -n "$merged_at" && "$merged_at" != none ) ]]; then
    resolved_state=merged
  elif [[ "$pr_state" == OPEN && ( -z "$merged_at" || "$merged_at" == none ) ]]; then
    resolved_state=open
  elif [[ "$pr_state" == CLOSED && ( -z "$merged_at" || "$merged_at" == none ) ]]; then
    queue_pr_reconciliation_error "PR #${pr_number} is closed without merging"
    return 1
  else
    queue_pr_reconciliation_error "PR #${pr_number} has unsupported state ${pr_state}/${merged_at}"
    return 1
  fi

  if [[ "$existing" -eq 1 ]]; then
    [[ "$pr_number" == "$stored_number" && "$pr_url" == "$stored_url" ]] \
      || queue_pr_reconciliation_error "recorded PR identity changed for ${expected_batch}" \
      || return 1
    case "${stored_state}:${resolved_state}" in
      open:open|merged:merged) ;;
      open:merged)
        queue_state_record_publish "$publish_file" "$expected_run" "$expected_batch" "$pr_number" "$pr_url" \
          "$expected_branch" "$CODEX_FLOW_BASE_BRANCH" "$expected_head" merged || return 1
        ;;
      *)
        queue_pr_reconciliation_error "recorded PR state ${stored_state} contradicts GitHub state ${resolved_state} for #${pr_number}"
        return 1
        ;;
    esac
  else
    queue_state_record_publish "$publish_file" "$expected_run" "$expected_batch" "$pr_number" "$pr_url" \
      "$expected_branch" "$CODEX_FLOW_BASE_BRANCH" "$expected_head" "$resolved_state" || return 1
  fi

  printf -v "$state_output" '%s' "$resolved_state"
  printf -v "$number_output" '%s' "$pr_number"
  printf -v "$url_output" '%s' "$pr_url"
}
queue_validate_publish_state_for_batch_file() {
  local batch_file="$1" publish_file
  local -A batch_fields=()

  [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 && -n "${run_state_dir:-}" ]] || return 0
  publish_file="$(dirname "$batch_file")/publish.state"
  [[ -e "$publish_file" ]] || return 0
  queue_state_parse_file "$batch_file" batch batch_fields \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_validate_publish_state_binding \
    "$publish_file" \
    "${run_state_dir}/manifest.state" \
    "$batch_file" \
    "${batch_fields[run_id]}" \
    "${batch_fields[batch_id]}" \
    "${batch_fields[branch]}"
}

queue_validate_publish_state_file_path() {
  local publish_file="$1" batch_file
  local -A batch_fields=()

  [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 && -n "${run_state_dir:-}" ]] || return 0
  batch_file="$(dirname "$publish_file")/batch.state"
  queue_state_parse_file "$batch_file" batch batch_fields \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_validate_publish_state_binding \
    "$publish_file" \
    "${run_state_dir}/manifest.state" \
    "$batch_file" \
    "${batch_fields[run_id]}" \
    "${batch_fields[batch_id]}" \
    "${batch_fields[branch]}"
}

queue_install_publish_state_validation() {
  local definition

  declare -F queue_state_validate_file >/dev/null 2>&1 || return 0
  declare -F issue_forge_queue_state_validate_file_original >/dev/null 2>&1 && return 0
  definition="$(declare -f queue_state_validate_file)" || return 1
  definition="${definition/#queue_state_validate_file /issue_forge_queue_state_validate_file_original }"
  eval "$definition"

  queue_state_validate_file() {
    local file="$1" schema="$2" name="${1##*/}"
    issue_forge_queue_state_validate_file_original "$@" || return 1
    case "$schema:$name" in
      batch:batch.state) queue_validate_publish_state_for_batch_file "$file" ;;
      publish:publish.state) queue_validate_publish_state_file_path "$file" ;;
    esac
  }
}

queue_install_publish_state_validation || return 1

# Intercept only reads of an already-recorded queue PR. PR creation performs its
# own `gh pr view` before publish.state exists and therefore bypasses this hook.
if type -P gh >/dev/null 2>&1; then
  gh() {
    if [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 && \
          "${1:-}" == pr && "${2:-}" == view && \
          -n "${publish_state_file:-}" && -e "${publish_state_file}" ]]; then
      queue_validate_publish_state_binding_from_scope || return 1
    fi
    command gh "$@"
  }
fi
