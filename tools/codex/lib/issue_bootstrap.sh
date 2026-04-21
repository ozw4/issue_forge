#!/usr/bin/env bash

require_issue_bootstrap_commands() {
  require_command gh
  require_command git
  require_command sed
  require_command tr
  require_command cut
}

slugify_issue_title() {
  local title="$1"
  local slug

  slug="$(
    printf '%s' "$title" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
      | cut -c1-"$CODEX_FLOW_ISSUE_SLUG_MAX_LENGTH"
  )"

  if [[ -z "$slug" ]]; then
    printf 'issue\n'
    return
  fi

  printf '%s\n' "$slug"
}

issue_title_for_number() {
  gh issue view "$1" --json title --jq '.title'
}

issue_branch_name_for_number() {
  local issue_number="$1"
  local issue_slug

  issue_slug="$(slugify_issue_title "$(issue_title_for_number "$issue_number")")"
  printf '%s%s-%s\n' "$CODEX_FLOW_BRANCH_PREFIX" "$issue_number" "$issue_slug"
}

ensure_issue_branch_available() {
  local branch_name="$1"

  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    printf 'Local branch already exists: %s\n' "$branch_name" >&2
    exit 1
  fi

  if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
    printf 'Remote branch already exists: %s\n' "$branch_name" >&2
    exit 1
  fi
}

write_issue_context_file() {
  local issue_number="$1"

  mkdir -p "$CODEX_FLOW_ISSUES_DIR"

  gh issue view "$issue_number" --json number,title,body,url --template '# Issue #{{.number}}

Title: {{.title}}
URL: {{.url}}

## Body
{{if .body}}{{.body}}{{else}}(no body){{end}}
' > "$(issue_file_path "$issue_number")"
}

write_current_issue_branch_state() {
  local issue_number="$1"
  local branch_name="$2"
  local base_commit="$3"

  printf '%s\n' "$issue_number" > "$CODEX_FLOW_CURRENT_ISSUE_FILE"
  printf '%s\n' "$branch_name" > "$CODEX_FLOW_CURRENT_BRANCH_FILE"
  printf '%s\n' "$base_commit" > "$CODEX_FLOW_BASE_COMMIT_FILE"
}

bootstrap_issue_branch() {
  local issue_number="$1"
  local branch_name
  local base_commit

  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
  require_flow_base_ref

  branch_name="$(issue_branch_name_for_number "$issue_number")"
  ensure_issue_branch_available "$branch_name"
  write_issue_context_file "$issue_number"

  git switch --create "$branch_name" --track "$CODEX_FLOW_BASE_REF"
  base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  write_current_issue_branch_state "$issue_number" "$branch_name" "$base_commit"

  # shellcheck disable=SC2034
  CODEX_FLOW_BOOTSTRAP_BRANCH_NAME="$branch_name"
}
