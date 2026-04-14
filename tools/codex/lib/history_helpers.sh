#!/usr/bin/env bash

require_history_dir() {
  if [[ -z "${history_dir:-}" ]]; then
    printf 'Missing required history directory.\n' >&2
    exit 1
  fi
}

history_round_path() {
  local stem="$1"
  local round="$2"
  local extension="$3"

  require_history_dir
  printf '%s/%s.round-%02d%s\n' "$history_dir" "$stem" "$round" "$extension"
}

archive_round_file() {
  local source_path="$1"
  local stem="$2"
  local round="$3"
  local extension="$4"

  cp "$source_path" "$(history_round_path "$stem" "$round" "$extension")"
}
