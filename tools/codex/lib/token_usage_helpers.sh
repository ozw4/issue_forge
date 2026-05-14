#!/usr/bin/env bash

extract_codex_token_usage() {
  local log_file="$1"

  [[ -f "$log_file" ]] || return 0

  awk '
    /^[[:space:]]*tokens used[[:space:]]*$/ {
      pending = 1
      next
    }
    pending {
      value = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^[0-9][0-9,]*$/) {
        gsub(/,/, "", value)
        final = value
      }
      pending = 0
    }
    END {
      if (final != "") {
        print final
      }
    }
  ' "$log_file"
}

relative_token_usage_path() {
  local path="$1"
  local repo_root

  case "$path" in
    /*)
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "$repo_root" && "$path" == "$repo_root/"* ]]; then
        printf '%s\n' "${path#"$repo_root"/}"
      else
        printf '%s\n' "$path"
      fi
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

ensure_token_usage_tsv() {
  local output_file="$1"
  local header="$2"

  mkdir -p "$(dirname "$output_file")"
  if [[ ! -f "$output_file" ]]; then
    printf '%s\n' "$header" > "$output_file"
  fi
}

append_codex_token_usage() {
  local output_file="$1"
  local header="$2"
  local phase="$3"
  local subject="$4"
  local round="$5"
  local reasoning="$6"
  local log_file="$7"
  local tokens
  local log_path

  ensure_token_usage_tsv "$output_file" "$header"

  tokens="$(extract_codex_token_usage "$log_file" || true)"
  if [[ -z "$tokens" ]]; then
    return 0
  fi

  log_path="$(relative_token_usage_path "$log_file")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$subject" "$round" "$reasoning" "$tokens" "$log_path" >> "$output_file"
}

ensure_issue_token_usage_tsv() {
  append_codex_token_usage "${CODEX_FLOW_CODEX_DIR}/token-usage.tsv" \
    $'phase\tissue\tround\treasoning\ttokens\tlog' \
    "$@"
}

initialize_issue_token_usage_tsv() {
  ensure_token_usage_tsv "${CODEX_FLOW_CODEX_DIR}/token-usage.tsv" \
    $'phase\tissue\tround\treasoning\ttokens\tlog'
}

ensure_batch_token_usage_tsv() {
  local batch_dir="$1"
  shift

  append_codex_token_usage "${batch_dir}/token-usage.tsv" \
    $'phase\tissues\tround\treasoning\ttokens\tlog' \
    "$@"
}

initialize_batch_token_usage_tsv() {
  local batch_dir="$1"

  ensure_token_usage_tsv "${batch_dir}/token-usage.tsv" \
    $'phase\tissues\tround\treasoning\ttokens\tlog'
}
