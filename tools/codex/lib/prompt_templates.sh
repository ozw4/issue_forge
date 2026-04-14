#!/usr/bin/env bash

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

prompt_template_path() {
  local template_name="$1"
  local template_path="${CODEX_FLOW_PROMPTS_DIR}/${template_name}.prompt.md.tmpl"

  if [[ ! -f "$template_path" ]]; then
    printf 'Missing prompt template: %s\n' "$template_path" >&2
    exit 1
  fi

  printf '%s\n' "$template_path"
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
  local review_output="${10}"

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
    "$(prompt_template_path review)" \
    "$review_prompt" \
    ISSUE_FILE "$issue_file" \
    REVIEW_DIFF "$review_diff" \
    REVIEW_UNTRACKED "$review_untracked" \
    ISSUE_NUMBER "$issue_number"

  render_prompt_template \
    "$(prompt_template_path fix-from-review)" \
    "$fix_review_prompt" \
    ISSUE_FILE "$issue_file" \
    REVIEW_OUTPUT "$review_output" \
    ISSUE_NUMBER "$issue_number"
}
