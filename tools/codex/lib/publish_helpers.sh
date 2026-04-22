#!/usr/bin/env bash

require_publish_commands() {
  require_command gh
  require_command git
  require_command mktemp
}

current_pr_url_for_branch() {
  local branch_name="$1"

  gh pr list \
    --head "$branch_name" \
    --base "$CODEX_FLOW_BASE_BRANCH" \
    --state open \
    --json url \
    --jq 'if length == 0 then "" else .[0].url end'
}

stage_issue_flow_changes() {
  local pathspec_file

  pathspec_file="$(mktemp "${TMPDIR:-/tmp}/issue-forge-stage-pathspec.XXXXXX")"
  trap 'rm -f "$pathspec_file"' RETURN

  {
    git diff --name-only -z -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
    git diff --name-only -z --cached -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
    git ls-files --others --exclude-standard -z -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
  } > "$pathspec_file"

  if [[ -s "$pathspec_file" ]]; then
    git add -A --pathspec-from-file="$pathspec_file" --pathspec-file-nul
  fi

  trap - RETURN
  rm -f "$pathspec_file"

  if git diff --cached --quiet; then
    printf 'No staged changes available for commit.\n' >&2
    exit 1
  fi
}

commit_issue_changes() {
  local commit_message="$1"
  local quiet="${2:-0}"
  local empty_message="${3:-}"

  if [[ -n "$empty_message" && -z "$(status_outside_work)" ]]; then
    printf '%s\n' "$empty_message" >&2
    exit 1
  fi

  stage_issue_flow_changes

  if [[ "$quiet" -eq 1 ]]; then
    git commit -m "$commit_message" >/dev/null
    return
  fi

  git commit -m "$commit_message"
}

create_issue_pr_for_branch() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_title="${3:-}"
  local pr_body_file
  local pr_draft_args=()
  local pr_url

  if [[ -z "$issue_title" ]]; then
    issue_title="$(issue_title_for_number "$issue_number")"
  fi

  pr_body_file="$(mktemp)"
  trap 'rm -f "$pr_body_file"' RETURN
  printf 'Closes #%s\n' "$issue_number" > "$pr_body_file"

  if [[ "$CODEX_FLOW_PR_DRAFT_DEFAULT" -eq 1 ]]; then
    pr_draft_args+=(--draft)
  fi

  pr_url="$(
    gh pr create \
      "${pr_draft_args[@]}" \
      --base "$CODEX_FLOW_BASE_BRANCH" \
      --head "$branch_name" \
      --title "$issue_title" \
      --body-file "$pr_body_file"
  )"

  trap - RETURN
  rm -f "$pr_body_file"
  printf '%s\n' "$pr_url"
}

publish_issue_results() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_title
  local existing_pr_url
  local pr_url

  log_info "pushing branch ${branch_name}"
  git push --set-upstream origin "$branch_name" >/dev/null

  issue_title="$(issue_title_for_number "$issue_number")"
  existing_pr_url="$(current_pr_url_for_branch "$branch_name")"

  if [[ -n "$existing_pr_url" ]]; then
    log_info "updated existing PR: $existing_pr_url"
    return 0
  fi

  pr_url="$(create_issue_pr_for_branch "$issue_number" "$branch_name" "$issue_title")"
  log_info "created draft PR: ${pr_url}"
}
