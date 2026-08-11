#!/usr/bin/env bash

_review_snapshot_cleanup_temporary_index() {
  local temporary_directory="$1"
  local temporary_index="$2"
  local cleanup_status=0

  rm -f -- \
    "$temporary_index" \
    "${temporary_index}.lock" \
    "${temporary_directory}/paths" || cleanup_status=1
  rmdir -- "$temporary_directory" || cleanup_status=1
  return "$cleanup_status"
}

_review_snapshot_current_state() {
  local head_commit
  local temporary_directory
  local temporary_index
  local pathspec_file
  local worktree_tree

  if ! head_commit="$(git rev-parse --verify 'HEAD^{commit}')"; then
    printf 'Failed to resolve HEAD commit for review snapshot.\n' >&2
    return 1
  fi

  if ! temporary_directory="$(mktemp -d)"; then
    printf 'Failed to create temporary directory for review snapshot.\n' >&2
    return 1
  fi
  temporary_index="${temporary_directory}/index"
  pathspec_file="${temporary_directory}/paths"

  if ! GIT_INDEX_FILE="$temporary_index" git read-tree "$head_commit"; then
    _review_snapshot_cleanup_temporary_index "$temporary_directory" "$temporary_index" || true
    printf 'Failed to initialize temporary Git index for review snapshot.\n' >&2
    return 1
  fi
  if ! {
    GIT_INDEX_FILE="$temporary_index" \
      git ls-files -z -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
    git ls-files -z -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
    git ls-files --others --exclude-standard -z -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
  } > "$pathspec_file"; then
    _review_snapshot_cleanup_temporary_index "$temporary_directory" "$temporary_index" || true
    printf 'Failed to collect worktree paths for review snapshot.\n' >&2
    return 1
  fi
  if ! GIT_INDEX_FILE="$temporary_index" git add -A \
    --pathspec-from-file="$pathspec_file" --pathspec-file-nul; then
    _review_snapshot_cleanup_temporary_index "$temporary_directory" "$temporary_index" || true
    printf 'Failed to add current worktree to temporary Git index for review snapshot.\n' >&2
    return 1
  fi
  if ! worktree_tree="$(GIT_INDEX_FILE="$temporary_index" git write-tree)"; then
    _review_snapshot_cleanup_temporary_index "$temporary_directory" "$temporary_index" || true
    printf 'Failed to write Git tree for review snapshot.\n' >&2
    return 1
  fi
  if ! _review_snapshot_cleanup_temporary_index "$temporary_directory" "$temporary_index"; then
    printf 'Failed to remove temporary Git index for review snapshot: %s\n' "$temporary_directory" >&2
    return 1
  fi

  printf '%s\t%s\n' "$head_commit" "$worktree_tree"
}

_review_snapshot_read_expected_state() {
  local snapshot_file="$1"

  if [[ ! -f "$snapshot_file" ]]; then
    printf 'Review snapshot file does not exist: %s\n' "$snapshot_file" >&2
    return 1
  fi

  awk -F '\t' '
    $1 == "schema_version" { schema_version = $2 }
    $1 == "head_commit" { head_commit = $2 }
    $1 == "worktree_tree" { worktree_tree = $2 }
    END {
      if (schema_version != "1" || head_commit == "" || worktree_tree == "") {
        exit 1
      }
      printf "%s\t%s\n", head_commit, worktree_tree
    }
  ' "$snapshot_file"
}

capture_review_snapshot() {
  local snapshot_file="$1"
  local snapshot_directory
  local temporary_file
  local current_state
  local head_commit
  local worktree_tree
  local created_at

  if ! current_state="$(_review_snapshot_current_state)"; then
    return 1
  fi
  IFS=$'\t' read -r head_commit worktree_tree <<< "$current_state"
  if ! created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; then
    printf 'Failed to create review snapshot timestamp.\n' >&2
    return 1
  fi

  snapshot_directory="$(dirname "$snapshot_file")"
  if ! mkdir -p "$snapshot_directory"; then
    printf 'Failed to create review snapshot directory: %s\n' "$snapshot_directory" >&2
    return 1
  fi
  temporary_file="$(mktemp "${snapshot_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary review snapshot file: %s\n' "$snapshot_file" >&2
    return 1
  }
  if ! printf '%s\t%s\n' \
    schema_version 1 \
    head_commit "$head_commit" \
    worktree_tree "$worktree_tree" \
    created_at "$created_at" > "$temporary_file"; then
    rm -f -- "$temporary_file" || true
    printf 'Failed to write review snapshot: %s\n' "$snapshot_file" >&2
    return 1
  fi
  if ! mv -T -f -- "$temporary_file" "$snapshot_file"; then
    rm -f -- "$temporary_file" || true
    printf 'Failed to publish review snapshot: %s\n' "$snapshot_file" >&2
    return 1
  fi
}

assert_review_snapshot_matches() {
  local snapshot_file="$1"
  local context_label="$2"
  local expected_state
  local expected_head
  local expected_tree
  local current_state
  local current_head
  local current_tree

  if ! expected_state="$(_review_snapshot_read_expected_state "$snapshot_file")"; then
    printf 'Invalid review snapshot file: %s\n' "$snapshot_file" >&2
    return 1
  fi
  IFS=$'\t' read -r expected_head expected_tree <<< "$expected_state"

  if ! current_state="$(_review_snapshot_current_state)"; then
    return 1
  fi
  IFS=$'\t' read -r current_head current_tree <<< "$current_state"

  if [[ "$expected_head" != "$current_head" ]]; then
    printf 'Review snapshot mismatch %s: expected HEAD %s, current HEAD %s\n' \
      "$context_label" "$expected_head" "$current_head" >&2
    return 1
  fi
  if [[ "$expected_tree" != "$current_tree" ]]; then
    printf 'Review snapshot mismatch %s: expected tree %s, current tree %s\n' \
      "$context_label" "$expected_tree" "$current_tree" >&2
    return 1
  fi
}
