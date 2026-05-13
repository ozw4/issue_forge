#!/usr/bin/env bash

# shellcheck disable=SC2154

# shellcheck source=tools/codex/lib/review_semantics.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_semantics.sh"

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
  local base_commit

  base_commit="$(resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first.")"

  git diff --no-ext-diff --binary "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$review_diff"
  : > "$review_untracked"

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_material=1
    printf '%s\n' "$path" >> "$review_untracked"
    append_untracked_file_diff "$path"
  done < <(git ls-files --others --exclude-standard -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}")

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
  local base_commit

  checks_run_round=$((checks_run_round + 1))
  round="$checks_run_round"
  base_commit="$(resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first.")"

  set +e
  "$CODEX_FLOW_CHECKS_COMMAND" "$base_commit" > "$checks_log" 2>&1
  status=$?
  set -e

  archive_round_file "$checks_log" "checks" "$round" ".log"

  return "$status"
}

run_fix_from_checks_round() {
  local fix_round="$1"

  fix_checks_round=$((fix_checks_round + 1))
  log_info "codex fix from checks (round ${fix_round})"
  "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" write "$fix_checks_prompt" > "$fix_checks_log" 2>&1
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

extract_structured_review_output_file() {
  local raw_output_file="$1"
  local structured_output_file="$2"
  local sanitized_output
  local candidate_output
  local found_candidate=0
  local line_number

  sanitized_output="$(mktemp)"
  candidate_output="$(mktemp)"

  if ! sanitize_codex_runtime_logs "$raw_output_file" > "$sanitized_output"; then
    rm -f "$sanitized_output" "$candidate_output"
    return 1
  fi

  if head -n 1 "$sanitized_output" | grep -Eq '^accept: (yes|no)$'; then
    cp "$sanitized_output" "$structured_output_file"
    rm -f "$sanitized_output" "$candidate_output"
    return 0
  fi

  if ! is_codex_transcript_output "$sanitized_output"; then
    rm -f "$sanitized_output" "$candidate_output"
    return 1
  fi

  while IFS=: read -r line_number _; do
    if [[ -z "$line_number" ]]; then
      continue
    fi

    if extract_review_candidate_from_line "$sanitized_output" "$line_number" > "$candidate_output" \
      && validate_review_output "$candidate_output" \
      && validate_review_output_semantics "$candidate_output"; then
      cp "$candidate_output" "$structured_output_file"
      found_candidate=1
    fi
  done < <(grep -nE '^accept: (yes|no)$' "$sanitized_output" || true)

  rm -f "$sanitized_output" "$candidate_output"
  [[ "$found_candidate" -eq 1 ]]
}

sanitize_codex_runtime_logs() {
  local raw_output_file="$1"

  awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T.* (ERROR|WARN|INFO|DEBUG|TRACE) codex_core::session:/ {
      next
    }
    {
      print
    }
  ' "$raw_output_file"
}

is_codex_transcript_output() {
  local sanitized_output_file="$1"

  grep -Eq '^(Reading prompt from stdin[.]*|OpenAI Codex)' "$sanitized_output_file"
}

extract_review_candidate_from_line() {
  local sanitized_output_file="$1"
  local start_line="$2"

  awk -v start_line="$start_line" '
    NR < start_line {
      next
    }
    NR == start_line {
      if ($0 !~ /^accept: (yes|no)$/) {
        exit 1
      }
      print
      state = "accept-gap"
      next
    }
    state == "accept-gap" {
      if ($0 != "") {
        exit 1
      }
      print
      state = "blocker-header"
      next
    }
    state == "blocker-header" {
      if ($0 != "blocker:") {
        exit 1
      }
      print
      state = "blocker"
      next
    }
    state == "blocker" {
      if ($0 == "") {
        print
        state = "major-header"
        next
      }
      if ($0 ~ /^- /) {
        print
        next
      }
      exit 1
    }
    state == "major-header" {
      if ($0 != "major:") {
        exit 1
      }
      print
      state = "major"
      next
    }
    state == "major" {
      if ($0 == "") {
        print
        state = "minor-header"
        next
      }
      if ($0 ~ /^- /) {
        print
        next
      }
      exit 1
    }
    state == "minor-header" {
      if ($0 != "minor:") {
        exit 1
      }
      print
      state = "minor"
      next
    }
    state == "minor" {
      if ($0 == "" || $0 ~ /^- /) {
        print
        next
      }
      exit 0
    }
    {
      exit 1
    }
    END {
      if (state != "minor") {
        exit 1
      }
    }
  ' "$sanitized_output_file" | awk '
    {
      lines[NR] = $0
    }
    END {
      end = NR
      while (end > 0 && lines[end] == "") {
        end -= 1
      }
      for (i = 1; i <= end; i++) {
        print lines[i]
      }
    }
  '
}

extract_review_output() {
  extract_structured_review_output_file "$review_raw_output" "$review_output"

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
  "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" read "$review_prompt" > "$review_raw_output"
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

validate_review_output_semantics() {
  local file="$1"
  local accept_line

  if ! IFS= read -r accept_line < "$file"; then
    return 1
  fi
  if [[ "$accept_line" == 'accept: yes' ]] && review_has_blocker_or_major_findings "$file"; then
    return 1
  fi
}

ensure_valid_review_output() {
  if ! validate_review_output "$review_output"; then
    log_fail_with_path "review output format is invalid" "$review_raw_output"
    exit 1
  fi

  if ! validate_review_output_semantics "$review_output"; then
    log_fail_with_path "review output is inconsistent with acceptance" "$review_raw_output"
    exit 1
  fi
}

review_output_accepted() {
  local file="$1"
  local accept_value

  accept_value="$(sed -n '1s/^accept: //p' "$file")"
  case "$accept_value" in
    yes)
      return 0
      ;;
    no)
      return 1
      ;;
    *)
      printf 'Invalid review accept value in %s\n' "$file" >&2
      exit 1
      ;;
  esac
}

review_accepted() {
  review_output_accepted "$review_output"
}

run_fix_from_review_round() {
  local review_fix_round="$1"

  fix_review_round=$((fix_review_round + 1))
  log_info "codex fix from review (round ${review_fix_round})"
  "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" write "$fix_review_prompt" > "$fix_review_log" 2>&1
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
