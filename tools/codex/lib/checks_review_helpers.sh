#!/usr/bin/env bash

# shellcheck disable=SC2154

# shellcheck source=tools/codex/lib/review_semantics.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_semantics.sh"
# shellcheck source=tools/codex/lib/review_material_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_material_helpers.sh"
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token_usage_helpers.sh"
# shellcheck source=tools/codex/lib/finding_ledger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finding_ledger.sh"
# shellcheck source=tools/codex/lib/review_details.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_details.sh"
# shellcheck source=tools/codex/lib/finding_scheduler.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finding_scheduler.sh"
# shellcheck source=tools/codex/lib/check_attempts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_attempts.sh"

generate_review_material() {
  local has_material=0
  local path
  local base_commit

  base_commit="$(resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first.")"

  git diff --no-ext-diff "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$review_diff"
  : > "$review_untracked"

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_material=1
    printf '%s\n' "$path" >> "$review_untracked"
    append_untracked_file_diff_to_review_material "$path" "$review_diff" 'single-issue'
  done < <(git ls-files --others --exclude-standard -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}")

  write_review_material_summary "$base_commit" "$review_summary" "$review_untracked"

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

  if run_check_attempt \
    "$CODEX_FLOW_CHECK_ATTEMPTS_ROOT" \
    "$CODEX_FLOW_CHECKS_MANIFEST" \
    "$checks_log" \
    issue \
    "$issue_number" \
    issue-checks \
    "$round" \
    "$base_commit" \
    "$CODEX_FLOW_CHECKS_COMMAND" \
    "$base_commit"; then
    status=0
  else
    status=$?
  fi

  if [[ -n "${CHECK_ATTEMPT_LAST_LOG:-}" && -f "$CHECK_ATTEMPT_LAST_LOG" ]]; then
    archive_round_file "$CHECK_ATTEMPT_LAST_LOG" "checks" "$round" ".log"
  fi

  return "$status"
}

run_fix_from_checks_round() {
  local fix_round="$1"

  fix_checks_round=$((fix_checks_round + 1))
  log_info "codex fix from checks (round ${fix_round})"
  run_codex_phase fix-from-checks "$fix_checks_round" write "$fix_checks_prompt" "$fix_checks_log" "$CODEX_FLOW_CHECK_FIX_REASONING"
  archive_round_file "$fix_checks_log" "fix-from-checks" "$fix_checks_round" ".log"
  ensure_issue_token_usage_tsv 'fix-from-checks' "$issue_number" "$fix_checks_round" "$CODEX_FLOW_CHECK_FIX_REASONING" "$fix_checks_log"
}

ensure_checks_pass() {
  local fix_round=0

  while true; do
    log_info "running local checks"

    if run_checks_round; then
      log_info "checks passed"
      return 0
    fi

    if [[ "${CHECK_ATTEMPT_LAST_PUBLISH_ERROR:-0}" -eq 1 ]]; then
      log_fail_with_path 'checks completed but legacy log publication failed' "$CHECK_ATTEMPT_LAST_DIR"
      return 1
    fi

    case "${CHECK_ATTEMPT_LAST_STATUS:-}" in
      invalid)
        log_fail_with_path 'checks changed the repository and were recorded as invalid' "$CHECK_ATTEMPT_LAST_DIR"
        return 1
        ;;
      interrupted)
        log_fail_with_path 'checks were interrupted' "$CHECK_ATTEMPT_LAST_DIR"
        return "${CHECK_ATTEMPT_LAST_EXIT_STATUS:-1}"
        ;;
    esac

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
  local line_number

  sanitized_output="$(mktemp)"
  candidate_output="$(mktemp)"

  if ! sanitize_codex_runtime_logs "$raw_output_file" > "$sanitized_output"; then
    rm -f "$sanitized_output" "$candidate_output"
    return 1
  fi

  if head -n 1 "$sanitized_output" | grep -Eq '^accept: (yes|no)$'; then
    if ! extract_review_candidate_from_line "$sanitized_output" 1 > "$candidate_output" \
      || ! review_output_has_allowed_tail "$sanitized_output" "$candidate_output" 1 \
      || ! validate_review_output "$candidate_output" \
      || ! validate_review_output_semantics "$candidate_output"; then
      rm -f "$sanitized_output" "$candidate_output"
      return 1
    fi
    cp "$candidate_output" "$structured_output_file"
    rm -f "$sanitized_output" "$candidate_output"
    return 0
  fi

  if ! is_codex_transcript_output "$sanitized_output"; then
    rm -f "$sanitized_output" "$candidate_output"
    return 1
  fi

  line_number="$(awk '/^accept: (yes|no)$/ { line_number = NR } END { if (line_number) print line_number }' "$sanitized_output")"
  if [[ -z "$line_number" ]] \
    || ! extract_review_candidate_from_line "$sanitized_output" "$line_number" > "$candidate_output" \
    || ! review_output_has_allowed_tail "$sanitized_output" "$candidate_output" "$line_number" \
    || ! validate_review_output "$candidate_output" \
    || ! validate_review_output_semantics "$candidate_output"; then
    rm -f "$sanitized_output" "$candidate_output"
    return 1
  fi

  cp "$candidate_output" "$structured_output_file"
  rm -f "$sanitized_output" "$candidate_output"
}

sanitize_codex_runtime_logs() {
  local raw_output_file="$1"

  awk '
    /^\[codex\] starting attempt [1-9][0-9]*$/ {
      next
    }
    /^\[codex\] transient Codex failure detected; retrying attempt [1-9][0-9]*\/[1-9][0-9]* after [0-9]+ seconds$/ {
      next
    }
    /^\[codex\] transient Codex failure persisted after [1-9][0-9]* attempts; giving up$/ {
      next
    }
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

review_output_has_allowed_tail() {
  local sanitized_output_file="$1"
  local candidate_output_file="$2"
  local start_line="${3:-1}"

  awk -v start_line="$start_line" '
    FNR == NR {
      candidate[++candidate_count] = $0
      next
    }
    FNR < start_line {
      next
    }
    {
      relative_line = FNR - start_line + 1
    }
    relative_line <= candidate_count {
      if ($0 != candidate[relative_line]) {
        exit 1
      }
      next
    }
    state == "" {
      if ($0 == "") {
        next
      }
      if ($0 == "tokens used") {
        state = "token-count"
        next
      }
      exit 1
    }
    state == "token-count" {
      if ($0 !~ /^([0-9]+|[0-9][0-9]?[0-9]?(,[0-9][0-9][0-9])*)$/) {
        exit 1
      }
      state = "token-tail"
      next
    }
    state == "token-tail" {
      if ($0 != "") {
        exit 1
      }
      next
    }
    END {
      observed_count = FNR - start_line + 1
      if (candidate_count == 0 || observed_count < candidate_count || state == "token-count") {
        exit 1
      }
    }
  ' "$candidate_output_file" "$sanitized_output_file"
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
      if ($0 == "") {
        print
        state = "details-header"
        next
      }
      if ($0 ~ /^- /) {
        print
        next
      }
      exit 1
    }
    state == "details-header" {
      if ($0 != "details:") {
        exit 1
      }
      print
      state = "details"
      next
    }
    state == "details" {
      if ($0 == "") {
        print
        state = "verification-header"
        next
      }
      if ($0 == "- none" || $0 ~ /^- finding: / || $0 ~ /^  (severity|evidence|impact|required_outcome|constraints|validation): /) {
        print
        next
      }
      exit 1
    }
    state == "verification-header" {
      if ($0 != "verification:") {
        exit 1
      }
      print
      state = "verification"
      next
    }
    state == "verification" {
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
      if (state != "verification") {
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
  review_run_round=$((review_run_round + 1))
  generate_review_material
  archive_round_file "$review_diff" "review-diff" "$review_run_round" ".txt"
  archive_round_file "$review_untracked" "review-untracked" "$review_run_round" ".txt"
  archive_round_file "$review_summary" "review-summary" "$review_run_round" ".txt"
  capture_review_snapshot "$review_snapshot"
  log_info "codex review"
  run_codex_phase \
    review "$review_run_round" read "$review_prompt" "$review_raw_output" \
    "$CODEX_FLOW_REVIEW_REASONING" stdout "$review_snapshot"
  assert_review_snapshot_matches "$review_snapshot" "after issue review"
  archive_round_file "$review_raw_output" "review-raw" "$review_run_round" ".txt"
  ensure_issue_token_usage_tsv 'review' "$issue_number" "$review_run_round" "$CODEX_FLOW_REVIEW_REASONING" "$review_raw_output"

  if ! extract_review_output; then
    printf 'Failed to extract structured review output.\n' >&2
    printf 'Review raw log: %s\n' "$review_raw_output" >&2
    exit 1
  fi

  ensure_valid_review_output
  record_issue_review_findings
}

validate_review_output() {
  local file="$1"

  validate_review_details_output "$file"
}

validate_review_output_semantics() {
  local file="$1"
  local accept_line
  local count_numbers
  local blocker_count
  local major_count
  local minor_count

  if ! IFS= read -r accept_line < "$file"; then
    return 1
  fi
  count_numbers="$(review_finding_count_numbers "$file")"
  read -r blocker_count major_count minor_count <<< "$count_numbers"

  if [[ "$accept_line" == 'accept: yes' ]] \
    && [[ "$blocker_count" -gt 0 || "$major_count" -gt 0 ]]; then
    return 1
  fi
  if [[ "$accept_line" == 'accept: no' ]] \
    && [[ $((blocker_count + major_count + minor_count)) -eq 0 ]]; then
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

record_issue_review_findings() {
  local fix_resolution_input=''

  write_review_details_artifact "$review_output" "$review_details"
  archive_round_file "$review_details" "review-details" "$review_run_round" ".tsv"
  if [[ -f "$fix_resolution_report" ]]; then
    fix_resolution_input="$fix_resolution_report"
  fi
  extract_review_verification \
    "$review_output" \
    "$review_findings_ledger" \
    "$fix_resolution_input" \
    "$review_verification"
  update_finding_ledger \
    "$review_output" \
    "$review_findings_ledger" \
    "$review_run_round" \
    "$review_verification"
  archive_round_file "$review_findings_ledger" "findings" "$review_run_round" ".tsv"
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
  local active_id
  local active_status
  local active_artifact_digest
  local one_row_resolution

  write_pending_findings "$review_findings_ledger" "$pending_findings"
  write_pending_finding_details \
    "$review_findings_ledger" \
    "$pending_findings" \
    "$review_details" \
    "$pending_finding_details"
  assert_review_snapshot_matches "$review_snapshot" "before issue review fix"
  initialize_fix_resolution_report "$fix_resolution_report"

  while true; do
    write_next_active_finding \
      "$pending_findings" \
      "$pending_finding_details" \
      "$fix_resolution_report" \
      "$active_finding" \
      "$active_finding_details"
    if active_id="$(active_finding_id "$active_finding")"; then
      active_status=0
    else
      active_status=$?
    fi
    if [[ "$active_status" -eq 2 ]]; then
      break
    fi
    if [[ "$active_status" -ne 0 ]]; then
      return "$active_status"
    fi

    active_artifact_digest="$(
      active_finding_artifact_digest "$active_finding" "$active_finding_details"
    )" || return 1
    fix_review_round=$((fix_review_round + 1))
    log_info "codex fix from review (cycle ${review_fix_round}, finding ${active_id})"
    capture_review_snapshot "$fix_review_snapshot"
    run_codex_phase \
      fix-from-review "$fix_review_round" write "$fix_review_prompt" "$fix_review_log" \
      "$CODEX_FLOW_REVIEW_FIX_REASONING" combined "$fix_review_snapshot"
    assert_active_finding_artifacts_match \
      "$active_finding" "$active_finding_details" "$active_artifact_digest" || return 1
    archive_round_file "$fix_review_log" "fix-from-review" "$fix_review_round" ".log"
    ensure_issue_token_usage_tsv \
      'fix-from-review' "$issue_number" "$fix_review_round" \
      "$CODEX_FLOW_REVIEW_FIX_REASONING" "$fix_review_log"

    one_row_resolution="$(mktemp "${fix_resolution_report}.row.XXXXXX")" || {
      printf 'Failed to create temporary one-finding resolution report.\n' >&2
      return 1
    }
    if ! extract_fix_resolution_report "$fix_review_log" "$active_finding" "$one_row_resolution" \
      || ! append_fix_resolution_report "$fix_resolution_report" "$one_row_resolution"; then
      rm -f -- "$one_row_resolution"
      return 1
    fi
    rm -f -- "$one_row_resolution"
  done

  archive_round_file "$fix_resolution_report" "fix-resolution" "$review_fix_round" ".tsv"
}

ensure_review_accepted() {
  local review_fix_round=0

  run_review_round

  while ! review_accepted; do
    if [[ "$review_fix_round" -ge "$CODEX_FLOW_MAX_REVIEW_FIX_ROUNDS" ]]; then
      log_fail_with_path "review did not reach acceptance after ${CODEX_FLOW_MAX_REVIEW_FIX_ROUNDS} fix rounds" "$review_output"
      exit 1
    fi

    review_fix_round=$((review_fix_round + 1))
    run_fix_from_review_round "$review_fix_round"
    ensure_checks_pass
    run_review_round
  done
}
