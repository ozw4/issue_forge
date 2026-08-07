#!/usr/bin/env bash

queue_publish_binding_error() {
  printf '[queue] Publish state binding validation failed: %s\n' "$1" >&2
  return 1
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
  queue_state_validate_file "$manifest_file" manifest \
    || queue_publish_binding_error "invalid run manifest ${manifest_file}" \
    || return 1
  queue_state_parse_file "$batch_file" batch batch_fields \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_state_validate_file "$batch_file" batch \
    || queue_publish_binding_error "invalid batch state ${batch_file}" \
    || return 1
  queue_state_parse_file "$publish_file" publish publish_fields \
    || queue_publish_binding_error "invalid publish state ${publish_file}" \
    || return 1
  queue_state_validate_file "$publish_file" publish \
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
