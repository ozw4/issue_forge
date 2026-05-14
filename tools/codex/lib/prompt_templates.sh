#!/usr/bin/env bash

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

required_prompt_template_names() {
  printf '%s\n' \
    'implementation' \
    'fix-from-checks' \
    'review' \
    'fix-from-review'
}

required_batch_prompt_template_names() {
  printf '%s\n' \
    'batch-review' \
    'fix-from-batch-review' \
    'fix-from-batch-checks'
}

required_queue_prompt_template_names() {
  required_batch_prompt_template_names

  if [[ "${CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW:-0}" -ne 0 ]]; then
    printf '%s\n' 'review-light'
  fi
}

prompt_template_file_path() {
  local template_name="$1"

  printf '%s/%s.prompt.md.tmpl\n' "$CODEX_FLOW_PROMPTS_DIR" "$template_name"
}

prompt_template_path() {
  local template_name="$1"
  local template_path

  template_path="$(prompt_template_file_path "$template_name")"

  if [[ ! -f "$template_path" ]]; then
    printf 'Missing prompt template: %s\n' "$template_path" >&2
    exit 1
  fi

  printf '%s\n' "$template_path"
}

require_prompt_template_names() {
  local template_name

  for template_name in "$@"; do
    prompt_template_path "$template_name" >/dev/null
  done
}

require_batch_prompt_templates() {
  local -a template_names=()

  mapfile -t template_names < <(required_batch_prompt_template_names)
  require_prompt_template_names "${template_names[@]}"
}

require_queue_prompt_templates() {
  local -a template_names=()

  mapfile -t template_names < <(required_queue_prompt_template_names)
  require_prompt_template_names "${template_names[@]}"
}

render_prompt_template() {
  local template_path="$1"
  local output_path="$2"
  local temp_output
  local sed_args=()
  local key
  local value

  shift 2

  if (( $# % 2 != 0 )); then
    printf 'render_prompt_template requires key/value pairs.\n' >&2
    exit 1
  fi

  if [[ ! -f "$template_path" ]]; then
    printf 'Missing prompt template: %s\n' "$template_path" >&2
    exit 1
  fi

  while [[ "$#" -gt 0 ]]; do
    key="$1"
    value="$2"
    shift 2
    sed_args+=(-e "s|{{${key}}}|$(escape_sed_replacement "$value")|g")
  done

  temp_output="$(mktemp)"

  if ! sed "${sed_args[@]}" "$template_path" > "$temp_output"; then
    rm -f "$temp_output"
    printf 'Failed to render prompt template: %s\n' "$template_path" >&2
    exit 1
  fi

  if ! awk '!match($0, /\{\{[A-Z0-9_]+\}\}/) { next } { exit 1 }' "$temp_output"; then
    rm -f "$temp_output"
    printf 'Unresolved prompt template placeholders in %s\n' "$template_path" >&2
    exit 1
  fi

  if ! mv "$temp_output" "$output_path"; then
    rm -f "$temp_output"
    printf 'Failed to write rendered prompt: %s\n' "$output_path" >&2
    exit 1
  fi
}

write_issue_flow_prompt_files() {
  local issue_number="$1"
  local issue_file="$2"
  local implement_prompt="$3"
  local fix_checks_prompt="$4"
  local review_prompt="$5"
  local fix_review_prompt="$6"
  local checks_log="$7"
  local review_diff="$8"
  local review_untracked="$9"
  local review_summary="${10}"
  local review_output="${11}"
  local light_issue_review="${CODEX_FLOW_LIGHT_ISSUE_REVIEW:-0}"
  local review_template='review'

  if [[ ! "$light_issue_review" =~ ^[0-9]+$ ]]; then
    printf 'CODEX_FLOW_LIGHT_ISSUE_REVIEW must be a non-negative integer: %s\n' "$light_issue_review" >&2
    exit 1
  fi

  if [[ "$light_issue_review" -ne 0 ]]; then
    review_template='review-light'
  fi

  render_prompt_template \
    "$(prompt_template_path implementation)" \
    "$implement_prompt" \
    ISSUE_FILE "$issue_file" \
    ISSUE_NUMBER "$issue_number"

  render_prompt_template \
    "$(prompt_template_path fix-from-checks)" \
    "$fix_checks_prompt" \
    ISSUE_FILE "$issue_file" \
    CHECKS_LOG "$checks_log" \
    ISSUE_NUMBER "$issue_number"

  render_prompt_template \
    "$(prompt_template_path "$review_template")" \
    "$review_prompt" \
    ISSUE_FILE "$issue_file" \
    REVIEW_DIFF "$review_diff" \
    REVIEW_UNTRACKED "$review_untracked" \
    REVIEW_SUMMARY "$review_summary" \
    ISSUE_NUMBER "$issue_number"

  render_prompt_template \
    "$(prompt_template_path fix-from-review)" \
    "$fix_review_prompt" \
    ISSUE_FILE "$issue_file" \
    REVIEW_OUTPUT "$review_output" \
    ISSUE_NUMBER "$issue_number"
}

write_batch_review_prompt_file() {
  local issues_file="$1"
  local batch_diff="$2"
  local batch_untracked="$3"
  local batch_summary="$4"
  local output_path="$5"

  render_prompt_template \
    "$(prompt_template_path batch-review)" \
    "$output_path" \
    BATCH_ISSUES_FILE "$issues_file" \
    BATCH_DIFF "$batch_diff" \
    BATCH_UNTRACKED "$batch_untracked" \
    BATCH_SUMMARY "$batch_summary"
}

write_fix_from_batch_review_prompt_file() {
  local issues_file="$1"
  local batch_review_output="$2"
  local output_path="$3"

  render_prompt_template \
    "$(prompt_template_path fix-from-batch-review)" \
    "$output_path" \
    BATCH_ISSUES_FILE "$issues_file" \
    BATCH_REVIEW_OUTPUT "$batch_review_output"
}

write_fix_from_batch_checks_prompt_file() {
  local issues_file="$1"
  local batch_checks_log="$2"
  local output_path="$3"

  render_prompt_template \
    "$(prompt_template_path fix-from-batch-checks)" \
    "$output_path" \
    BATCH_ISSUES_FILE "$issues_file" \
    BATCH_CHECKS_LOG "$batch_checks_log"
}
