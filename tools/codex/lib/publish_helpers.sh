#!/usr/bin/env bash

require_publish_commands() {
  require_command awk
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

read_issue_title_from_issue_file() {
  local issue_file="$1"
  local issue_title

  if ! issue_title="$(
    awk '
      /^Title: / {
        sub(/^Title: /, "")
        print
        found = 1
        exit
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$issue_file"
  )"; then
    printf 'Missing issue title in issue context file: %s\n' "$issue_file" >&2
    exit 1
  fi

  if [[ -z "$issue_title" ]]; then
    printf 'Issue title is empty in issue context file: %s\n' "$issue_file" >&2
    exit 1
  fi

  printf '%s\n' "$issue_title"
}

pr_summary_from_issue_title() {
  local issue_title="$1"

  if [[ "${#issue_title}" -le 120 ]]; then
    printf '%s\n' "$issue_title"
    return
  fi

  printf '%s...\n' "${issue_title:0:117}"
}

shorten_pr_body_line() {
  local value="$1"

  if [[ "${#value}" -le 180 ]]; then
    printf '%s\n' "$value"
    return
  fi

  printf '%s...\n' "${value:0:177}"
}

write_pr_changed_files_section() {
  local base_commit="$1"
  local branch_name="$2"
  local changed_files_file
  local path
  local has_changed_files=0

  changed_files_file="$(mktemp)"
  if ! git diff --name-only "$base_commit" "$branch_name" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$changed_files_file"; then
    rm -f "$changed_files_file"
    printf 'Failed to collect changed files for PR body: %s..%s\n' "$base_commit" "$branch_name" >&2
    exit 1
  fi

  printf '## Changed files\n'

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_changed_files=1
    printf -- "- \`%s\`\n" "$path"
  done < "$changed_files_file"

  if [[ "$has_changed_files" -ne 1 ]]; then
    printf -- '- none\n'
  fi

  rm -f "$changed_files_file"
  printf '\n'
}

last_nonempty_file_line() {
  local path="$1"

  awk 'NF { line = $0 } END { if (line != "") print line; else exit 1 }' "$path"
}

write_pr_checks_section() {
  local checks_log="${CODEX_FLOW_CODEX_DIR}/checks.log"
  local checks_summary

  printf '## Checks\n'

  if [[ ! -f "$checks_log" ]]; then
    printf -- '- not available yet\n\n'
    return
  fi

  if [[ ! -s "$checks_log" ]]; then
    printf -- "- \`%s\`: empty\n\n" "$checks_log"
    return
  fi

  if ! checks_summary="$(last_nonempty_file_line "$checks_log")"; then
    printf -- "- \`%s\`: no non-empty output\n\n" "$checks_log"
    return
  fi

  checks_summary="$(shorten_pr_body_line "$checks_summary")"
  printf -- "- \`%s\`: %s\n\n" "$checks_log" "$checks_summary"
}

review_finding_counts() {
  local review_file="$1"

  awk '
    $0 == "blocker:" {
      section = "blocker"
      next
    }
    $0 == "major:" {
      section = "major"
      next
    }
    $0 == "minor:" {
      section = "minor"
      next
    }
    /^- / {
      if (section == "blocker") {
        blocker += 1
      } else if (section == "major") {
        major += 1
      } else if (section == "minor") {
        minor += 1
      }
    }
    END {
      printf "blocker %d, major %d, minor %d\n", blocker + 0, major + 0, minor + 0
    }
  ' "$review_file"
}

write_pr_review_section() {
  local review_file="${CODEX_FLOW_CODEX_DIR}/review.txt"
  local accept_line
  local finding_counts

  printf '## Review\n'

  if [[ ! -f "$review_file" ]]; then
    printf -- '- not available yet\n'
    return
  fi

  if ! IFS= read -r accept_line < "$review_file"; then
    printf 'Review artifact is empty: %s\n' "$review_file" >&2
    exit 1
  fi

  case "$accept_line" in
    'accept: yes'|'accept: no')
      ;;
    *)
      printf 'Invalid review accept line in %s: %s\n' "$review_file" "$accept_line" >&2
      exit 1
      ;;
  esac

  finding_counts="$(review_finding_counts "$review_file")"
  printf -- "- \`%s\`: %s\n" "$review_file" "$accept_line"
  printf -- '- findings: %s\n' "$finding_counts"
}

write_issue_pr_body() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_title="$3"
  local base_commit
  local summary

  base_commit="$(resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first.")"

  if ! git rev-parse --verify "${branch_name}^{commit}" >/dev/null 2>&1; then
    printf 'Missing local branch for PR body generation: %s\n' "$branch_name" >&2
    exit 1
  fi

  summary="$(pr_summary_from_issue_title "$issue_title")"

  printf 'Closes #%s\n\n' "$issue_number"
  printf '## Summary\n'
  printf -- '- %s\n\n' "$summary"
  write_pr_changed_files_section "$base_commit" "$branch_name"
  write_pr_checks_section
  write_pr_review_section
}

write_issue_pr_body_file() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_title="$3"
  local pr_body_file="$4"

  write_issue_pr_body "$issue_number" "$branch_name" "$issue_title" > "$pr_body_file"
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

sync_issue_pr_for_branch() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_title="$3"
  local pr_url_variable="$4"
  local pr_action_variable="$5"
  local existing_pr_url
  local pr_body_file
  local pr_draft_args=()
  local created_pr_url

  pr_body_file="$(mktemp)"
  write_issue_pr_body_file "$issue_number" "$branch_name" "$issue_title" "$pr_body_file"

  existing_pr_url="$(current_pr_url_for_branch "$branch_name")"
  if [[ -n "$existing_pr_url" ]]; then
    gh pr edit "$existing_pr_url" \
      --title "$issue_title" \
      --body-file "$pr_body_file" >/dev/null

    rm -f "$pr_body_file"
    printf -v "$pr_url_variable" '%s' "$existing_pr_url"
    printf -v "$pr_action_variable" '%s' 'updated'
    return 0
  fi

  if [[ "$CODEX_FLOW_PR_DRAFT_DEFAULT" -eq 1 ]]; then
    pr_draft_args+=(--draft)
  fi

  created_pr_url="$(
    gh pr create \
      "${pr_draft_args[@]}" \
      --base "$CODEX_FLOW_BASE_BRANCH" \
      --head "$branch_name" \
      --title "$issue_title" \
      --body-file "$pr_body_file"
  )"

  rm -f "$pr_body_file"
  printf -v "$pr_url_variable" '%s' "$created_pr_url"
  printf -v "$pr_action_variable" '%s' 'created'
}

publish_issue_results() {
  local issue_number="$1"
  local branch_name="$2"
  local issue_file
  local issue_title
  local pr_action
  local pr_url

  log_info "pushing branch ${branch_name}"
  git push --set-upstream origin "$branch_name" >/dev/null

  issue_file="$(require_issue_file "$issue_number")"
  issue_title="$(read_issue_title_from_issue_file "$issue_file")"
  sync_issue_pr_for_branch "$issue_number" "$branch_name" "$issue_title" pr_url pr_action
  log_info "${pr_action} PR: ${pr_url}"
}
