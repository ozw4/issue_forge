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

max_history_round() {
  local stem="$1"
  local extension="$2"
  local path
  local filename
  local round_text
  local round
  local maximum=0

  require_history_dir

  for path in "$history_dir/$stem.round-"*"$extension"; do
    [[ -e "$path" ]] || continue
    filename="${path##*/}"
    round_text="${filename#"$stem.round-"}"
    round_text="${round_text%"$extension"}"
    [[ "$round_text" =~ ^[0-9]+$ ]] || continue
    round=$((10#$round_text))
    if [[ "$round" -gt "$maximum" ]]; then
      maximum="$round"
    fi
  done

  printf '%s\n' "$maximum"
}

archive_round_file() {
  local source_path="$1"
  local stem="$2"
  local round="$3"
  local extension="$4"

  local destination

  destination="$(history_round_path "$stem" "$round" "$extension")"
  if [[ -e "$destination" && "${history_allow_overwrite:-0}" -ne 1 ]]; then
    printf 'Refusing to overwrite existing history file: %s\n' "$destination" >&2
    return 1
  fi

  cp "$source_path" "$destination"
}
