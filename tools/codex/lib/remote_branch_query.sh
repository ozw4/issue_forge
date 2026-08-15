#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_REMOTE_BRANCH_QUERY_LOADED:-}" ]]; then
  return 0
fi

remote_branch_query_error() {
  printf 'Remote branch query failed: %s\n' "$1" >&2
  return 1
}

issue_forge_remote_branch_query_run_git() {
  if declare -F issue_forge_remote_branch_query_git_original >/dev/null 2>&1; then
    issue_forge_remote_branch_query_git_original "$@"
    return $?
  fi
  command git "$@"
}

query_remote_branch_head() {
  local remote="$1"
  local branch_name="$2"
  local output_name="$3"
  local boundary="${4:-remote branch query}"
  local output status sha ref extra expected_ref

  expected_ref="refs/heads/${branch_name}"
  if output="$(issue_forge_remote_branch_query_run_git ls-remote --heads "$remote" "$expected_ref")"; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne 0 ]]; then
    remote_branch_query_error \
      "git ls-remote exited ${status} for ${remote} ${expected_ref} during ${boundary}"
    return 1
  fi

  if [[ -z "$output" ]]; then
    printf -v "$output_name" '%s' ''
    return 0
  fi

  if [[ "$output" == *$'\n'* ]]; then
    remote_branch_query_error \
      "multiple refs were returned for ${remote} ${expected_ref} during ${boundary}"
    return 1
  fi

  IFS=$'\t ' read -r sha ref extra <<< "$output"
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40,64}$ || "$ref" != "$expected_ref" || -n "${extra:-}" ]]; then
    remote_branch_query_error \
      "malformed response for ${remote} ${expected_ref} during ${boundary}: ${output}"
    return 1
  fi

  printf -v "$output_name" '%s' "$sha"
}

issue_forge_install_queue_ls_remote_fail_closed() {
  local definition

  [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 ]] || return 0
  declare -F issue_forge_remote_branch_query_git_original >/dev/null 2>&1 && return 0

  if declare -F git >/dev/null 2>&1; then
    definition="$(declare -f git)" || return 1
    definition="${definition/#git /issue_forge_remote_branch_query_git_original }"
    eval "$definition"
  else
    issue_forge_remote_branch_query_git_original() {
      command git "$@"
    }
  fi

  if ! unset ISSUE_FORGE_INTERNAL_QUEUE_REMOTE_QUERY_ERROR_FD 2>/dev/null; then
    remote_branch_query_error \
      'private remote-query diagnostic descriptor is readonly and cannot be initialized'
    return 1
  fi
  exec {ISSUE_FORGE_INTERNAL_QUEUE_REMOTE_QUERY_ERROR_FD}>&2 || return 1
  readonly ISSUE_FORGE_INTERNAL_QUEUE_REMOTE_QUERY_ERROR_FD

  git() {
    local output status rendered caller

    if [[ "${1:-}" != ls-remote ]]; then
      issue_forge_remote_branch_query_git_original "$@"
      return $?
    fi

    if output="$(issue_forge_remote_branch_query_git_original "$@")"; then
      printf '%s' "$output"
      return 0
    else
      status=$?
    fi

    printf -v rendered '%q ' "$@"
    caller="${FUNCNAME[1]:-queue}"
    printf 'Remote branch query failed: git %sexited %s during %s; refusing to treat the remote branch as absent\n' \
      "$rendered" "$status" "$caller" >&"$ISSUE_FORGE_INTERNAL_QUEUE_REMOTE_QUERY_ERROR_FD"
    printf '__ISSUE_FORGE_REMOTE_QUERY_FAILED_EXIT_%s__\n' "$status"
    return "$status"
  }
}

issue_forge_install_queue_ls_remote_fail_closed || return 1
readonly ISSUE_FORGE_REMOTE_BRANCH_QUERY_LOADED=1
