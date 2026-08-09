# shellcheck shell=bash
# shellcheck disable=SC2154

readonly CODEX_FLOW_REVIEW_RETRY_LIMIT_DEFAULT=3

review_repository_fingerprint() {
  local snapshot_file
  local untracked_file
  local path
  local executable
  local file_hash
  local diff_status
  local status=0
  local -a review_pathspec=(.)

  if declare -p CODEX_FLOW_WORKTREE_EXCLUDE_PATHS >/dev/null 2>&1; then
    review_pathspec+=("${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}")
  fi

  snapshot_file="$(mktemp)" || return 1
  untracked_file="$(mktemp)" || {
    rm -f -- "$snapshot_file"
    return 1
  }

  git ls-files --others --exclude-standard -z -- "${review_pathspec[@]}" > "$untracked_file" \
    || status=$?

  if [[ "$status" -eq 0 ]]; then
    {
      printf 'HEAD\0'
      git rev-parse --verify 'HEAD^{commit}' || status=$?
      if [[ "$status" -eq 0 ]]; then
        printf '\0INDEX\0'
        git diff --cached --binary --no-ext-diff -- "${review_pathspec[@]}" || status=$?
      fi
      if [[ "$status" -eq 0 ]]; then
        printf '\0WORKTREE\0'
        git diff --binary --no-ext-diff -- "${review_pathspec[@]}" || status=$?
      fi
      if [[ "$status" -eq 0 ]]; then
        printf '\0UNTRACKED\0'
        while IFS= read -r -d '' path; do
          printf 'PATH\0%s\0' "$path"
          if [[ -L "$path" ]]; then
            printf 'SYMLINK\0'
            if git diff --no-index --binary -- /dev/null "$path"; then
              :
            else
              diff_status=$?
              if [[ "$diff_status" -ne 1 ]]; then
                status="$diff_status"
                break
              fi
            fi
            printf '\0'
          elif [[ -f "$path" ]]; then
            if [[ -x "$path" ]]; then executable=1; else executable=0; fi
            if ! file_hash="$(git hash-object --no-filters -- "$path")"; then
              status=1
              break
            fi
            printf 'FILE\0%s\0%s\0' "$executable" "$file_hash"
          elif [[ -p "$path" ]]; then
            printf 'FIFO\0'
          elif [[ -S "$path" ]]; then
            printf 'SOCKET\0'
          elif [[ -b "$path" ]]; then
            printf 'BLOCK\0'
          elif [[ -c "$path" ]]; then
            printf 'CHAR\0'
          else
            printf 'OTHER\0'
          fi
        done < "$untracked_file"
      fi
    } > "$snapshot_file"
  fi

  if [[ "$status" -eq 0 ]]; then
    sha256sum -- "$snapshot_file" | awk '{ print $1 }' || status=$?
  fi
  rm -f -- "$snapshot_file" "$untracked_file"
  return "$status"
}

review_refresh_material_after_change() {
  local phase="$1"
  local round="$2"

  case "$phase" in
    review)
      generate_review_material
      archive_round_file "$review_diff" 'review-diff' "$round" '.txt'
      archive_round_file "$review_untracked" 'review-untracked' "$round" '.txt'
      archive_round_file "$review_summary" 'review-summary' "$round" '.txt'
      ;;
    batch-review)
      generate_batch_review_material "$base_commit" "$batch_diff" "$batch_untracked" "$batch_summary"
      archive_round_file "$batch_diff" 'batch-diff' "$round" '.txt'
      archive_round_file "$batch_untracked" 'batch-untracked' "$round" '.txt'
      archive_round_file "$batch_summary" 'batch-summary' "$round" '.txt'
      write_batch_review_prompt_file \
        "$issues_file" "$batch_diff" "$batch_untracked" "$batch_summary" "$batch_review_prompt"
      ;;
    *)
      attempt_store_error "Unsupported review retry phase: ${phase}"
      return 1
      ;;
  esac
}

review_update_outer_status_baseline() {
  if declare -p before_status >/dev/null 2>&1 \
    && declare -F status_outside_work >/dev/null 2>&1; then
    before_status="$(status_outside_work)" || return 1
  fi
}
