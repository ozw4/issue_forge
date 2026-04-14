#!/usr/bin/env bash

append_untracked_file_diff() {
  local path="$1"
  local status

  set +e
  git diff --no-index -- /dev/null "$path" >> "$review_diff"
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    printf 'Failed to generate review material for untracked file: %s\n' "$path" >&2
    exit 1
  fi
}

generate_review_material() {
  local has_material=0
  local path

  git diff --no-ext-diff --binary "$CODEX_FLOW_BASE_REF" -- . "$CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC" > "$review_diff"
  : > "$review_untracked"

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_material=1
    printf '%s\n' "$path" >> "$review_untracked"
    append_untracked_file_diff "$path"
  done < <(git ls-files --others --exclude-standard -- . "$CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC")

  if [[ -s "$review_diff" ]]; then
    has_material=1
  fi

  if [[ "$has_material" -ne 1 ]]; then
    printf 'Review material is empty: %s\n' "$review_diff" >&2
    exit 1
  fi
}

run_checks_round() {
  local status
  local round

  checks_run_round=$((checks_run_round + 1))
  round="$checks_run_round"

  set +e
  ./tools/checks/run_changed.sh "$CODEX_FLOW_BASE_REF" > "$checks_log" 2>&1
  status=$?
  set -e

  archive_round_file "$checks_log" "checks" "$round" ".log"

  return "$status"
}

run_fix_from_checks_round() {
  local fix_round="$1"

  fix_checks_round=$((fix_checks_round + 1))
  log_info "codex fix from checks (round ${fix_round})"
  ./tools/codex/run_codex.sh write "$fix_checks_prompt" > "$fix_checks_log" 2>&1
  archive_round_file "$fix_checks_log" "fix-from-checks" "$fix_checks_round" ".log"
}

ensure_checks_pass() {
  local fix_round=0

  while true; do
    log_info "running local checks"

    if run_checks_round; then
      log_info "checks passed"
      return 0
    fi

    if [[ "$fix_round" -ge "$CODEX_FLOW_MAX_CHECK_FIX_ROUNDS" ]]; then
      log_fail_with_path "checks failed after ${CODEX_FLOW_MAX_CHECK_FIX_ROUNDS} fix rounds" "$checks_log"
      return 1
    fi

    fix_round=$((fix_round + 1))
    run_fix_from_checks_round "$fix_round"
  done
}

extract_review_output() {
  awk '
    /^accept: (yes|no)$/ { start = NR }
    { lines[NR] = $0 }
    END {
      if (!start) {
        exit 1
      }
      for (i = start; i <= NR; i++) {
        print lines[i]
      }
    }
  ' "$review_raw_output" > "$review_output"

  archive_round_file "$review_output" "review" "$review_run_round" ".txt"
}

run_review_round() {
  local before_status
  local after_status

  review_run_round=$((review_run_round + 1))
  generate_review_material
  archive_round_file "$review_diff" "review-diff" "$review_run_round" ".txt"
  archive_round_file "$review_untracked" "review-untracked" "$review_run_round" ".txt"
  before_status="$(status_outside_work)"
  log_info "codex review"
  ./tools/codex/run_codex.sh read "$review_prompt" > "$review_raw_output" 2>&1
  archive_round_file "$review_raw_output" "review-raw" "$review_run_round" ".txt"
  after_status="$(status_outside_work)"

  if [[ "$before_status" != "$after_status" ]]; then
    printf 'Review session modified repository files.\n' >&2
    printf 'Review raw log: %s\n' "$review_raw_output" >&2
    exit 1
  fi

  if ! extract_review_output; then
    printf 'Failed to extract structured review output.\n' >&2
    printf 'Review raw log: %s\n' "$review_raw_output" >&2
    exit 1
  fi
}

validate_review_output() {
  local file="$1"

  awk '
    NR == 1 {
      if ($0 != "accept: yes" && $0 != "accept: no") {
        exit 1
      }
      next
    }
    NR == 2 {
      if ($0 != "") {
        exit 1
      }
      next
    }
    state == "" {
      if ($0 != "blocker:") {
        exit 1
      }
      state = "blocker"
      next
    }
    state == "blocker" {
      if ($0 == "") {
        state = "blocker-gap"
        next
      }
      if ($0 !~ /^- /) {
        exit 1
      }
      next
    }
    state == "blocker-gap" {
      if ($0 != "major:") {
        exit 1
      }
      state = "major"
      next
    }
    state == "major" {
      if ($0 == "") {
        state = "major-gap"
        next
      }
      if ($0 !~ /^- /) {
        exit 1
      }
      next
    }
    state == "major-gap" {
      if ($0 != "minor:") {
        exit 1
      }
      state = "minor"
      next
    }
    state == "minor" {
      if ($0 != "" && $0 !~ /^- /) {
        exit 1
      }
      next
    }
    {
      exit 1
    }
    END {
      if (state != "minor") {
        exit 1
      }
    }
  ' "$file"
}

ensure_valid_review_output() {
  if ! validate_review_output "$review_output"; then
    log_fail_with_path "review output format is invalid" "$review_raw_output"
    exit 1
  fi
}

review_accepted() {
  local accept_value

  accept_value="$(sed -n '1s/^accept: //p' "$review_output")"
  case "$accept_value" in
    yes)
      return 0
      ;;
    no)
      return 1
      ;;
    *)
      printf 'Invalid review accept value in %s\n' "$review_output" >&2
      exit 1
      ;;
  esac
}

run_fix_from_review_round() {
  local review_fix_round="$1"

  fix_review_round=$((fix_review_round + 1))
  log_info "codex fix from review (round ${review_fix_round})"
  ./tools/codex/run_codex.sh write "$fix_review_prompt" > "$fix_review_log" 2>&1
  archive_round_file "$fix_review_log" "fix-from-review" "$fix_review_round" ".log"
}

ensure_review_accepted() {
  local review_fix_round=0

  run_review_round
  ensure_valid_review_output

  while ! review_accepted; do
    if [[ "$review_fix_round" -ge "$CODEX_FLOW_MAX_REVIEW_FIX_ROUNDS" ]]; then
      log_fail_with_path "review did not reach acceptance after ${CODEX_FLOW_MAX_REVIEW_FIX_ROUNDS} fix rounds" "$review_output"
      exit 1
    fi

    review_fix_round=$((review_fix_round + 1))
    run_fix_from_review_round "$review_fix_round"
    ensure_checks_pass
    run_review_round
    ensure_valid_review_output
  done
}
