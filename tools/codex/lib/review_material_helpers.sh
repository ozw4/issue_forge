#!/usr/bin/env bash

append_untracked_file_diff_to_review_material() {
  local path="$1"
  local diff_file="$2"
  local context_label="$3"
  local status

  set +e
  git diff --no-index -- /dev/null "$path" >> "$diff_file"
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    printf 'Failed to generate %s review material for untracked file: %s\n' "$context_label" "$path" >&2
    exit 1
  fi
}

write_untracked_file_size_summary() {
  local untracked_file="$1"
  local path
  local size
  local has_untracked=0

  printf 'untracked files:\n'
  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_untracked=1
    size="$(wc -c < "$path" | awk '{ print $1 }')"
    printf '%s bytes\t%s\n' "$size" "$path"
  done < "$untracked_file"

  if [[ "$has_untracked" -ne 1 ]]; then
    printf -- '- none\n'
  fi
}

write_binary_change_summary() {
  local name_status_file="$1"
  local numstat_file="$2"
  local binary_paths
  local path
  local status
  local has_binary=0

  binary_paths="$(mktemp)"
  awk -F '\t' '$1 == "-" && $2 == "-" { print $3 }' "$numstat_file" > "$binary_paths"

  printf 'binary files changed:\n'
  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_binary=1
    status="$(awk -v path="$path" -F '\t' '$NF == path { print $1; found = 1; exit } END { if (!found) print "unknown" }' "$name_status_file")"
    printf '%s\t%s\n' "$status" "$path"
  done < "$binary_paths"

  if [[ "$has_binary" -ne 1 ]]; then
    printf -- '- none\n'
  fi

  rm -f "$binary_paths"
}

write_review_material_summary() {
  local base_commit="$1"
  local summary_file="$2"
  local untracked_file="$3"
  local name_status_file
  local numstat_file

  name_status_file="$(mktemp)"
  numstat_file="$(mktemp)"

  git diff --no-ext-diff --name-status "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$name_status_file"
  git diff --no-ext-diff --numstat "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$numstat_file"

  {
    printf 'base commit: %s\n\n' "$base_commit"
    printf 'diff stat:\n'
    git diff --no-ext-diff --stat "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
    printf '\nname status:\n'
    if [[ -s "$name_status_file" ]]; then
      cat "$name_status_file"
    else
      printf -- '- none\n'
    fi
    printf '\nnumstat:\n'
    if [[ -s "$numstat_file" ]]; then
      cat "$numstat_file"
    else
      printf -- '- none\n'
    fi
    printf '\n'
    write_untracked_file_size_summary "$untracked_file"
    printf '\n'
    write_binary_change_summary "$name_status_file" "$numstat_file"
  } > "$summary_file"

  rm -f "$name_status_file" "$numstat_file"
}
