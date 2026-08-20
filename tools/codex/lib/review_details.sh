#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_REVIEW_DETAILS_LOADED:-}" ]]; then
  return 0
fi

# shellcheck source=tools/codex/lib/finding_ledger.sh
if ! declare -F require_tsv_header >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finding_ledger.sh"
fi

readonly REVIEW_DETAILS_HEADER=$'severity\tfinding\tevidence\timpact\trequired_outcome\tconstraints\tvalidation'
readonly PENDING_FINDING_DETAILS_HEADER=$'finding_id\tseverity\ttext\tevidence\timpact\trequired_outcome\tconstraints\tvalidation'

validate_review_details_output() {
  local review_file="$1"

  [[ -f "$review_file" ]] || return 1

  awk '
    function invalid() {
      failed = 1
      exit 1
    }
    function nonempty(value) {
      return value !~ /^ *$/
    }
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_placeholder_item(value, normalized) {
      normalized = tolower(trim(value))
      return normalized == "none" || normalized == "n/a" || normalized == "no issues" || normalized == "nothing"
    }
    function start_detail(line) {
      if (line !~ /^- finding: /) invalid()
      detail_finding = substr(line, 12)
      if (!nonempty(detail_finding)) invalid()
      state = "detail-severity"
    }
    function finish_detail() {
      if (detail_finding in detail_seen) invalid()
      detail_seen[detail_finding] = 1
      detail_severity_by_finding[detail_finding] = detail_severity
      detail_count += 1
      state = "details-next"
    }
    index($0, "\t") || index($0, "\r") {
      invalid()
    }
    NR == 1 {
      if ($0 != "accept: yes" && $0 != "accept: no") invalid()
      next
    }
    NR == 2 {
      if ($0 != "") invalid()
      state = "blocker-header"
      next
    }
    state == "blocker-header" {
      if ($0 != "blocker:") invalid()
      state = "blocker"
      next
    }
    state == "blocker" || state == "major" || state == "minor" {
      if ($0 == "") {
        if (state == "blocker") state = "major-header"
        else if (state == "major") state = "minor-header"
        else state = "details-header"
        next
      }
      if ($0 !~ /^- /) invalid()
      finding = substr($0, 3)
      if (!nonempty(finding)) invalid()
      if (!is_placeholder_item(finding)) {
        if (finding in current_severity) invalid()
        current_order[++current_count] = finding
        current_severity[finding] = state
      }
      next
    }
    state == "major-header" {
      if ($0 != "major:") invalid()
      state = "major"
      next
    }
    state == "minor-header" {
      if ($0 != "minor:") invalid()
      state = "minor"
      next
    }
    state == "details-header" {
      if ($0 != "details:") invalid()
      state = "details-first"
      next
    }
    state == "details-first" {
      if ($0 == "- none") {
        details_none = 1
        state = "details-after-none"
        next
      }
      start_detail($0)
      next
    }
    state == "details-after-none" {
      if ($0 != "") invalid()
      state = "verification-header"
      next
    }
    state == "detail-severity" {
      if ($0 !~ /^  severity: /) invalid()
      detail_severity = substr($0, 13)
      if (detail_severity != "blocker" && detail_severity != "major" && detail_severity != "minor") invalid()
      state = "detail-evidence"
      next
    }
    state == "detail-evidence" {
      if ($0 !~ /^  evidence: /) invalid()
      detail_evidence = substr($0, 13)
      if (!nonempty(detail_evidence)) invalid()
      state = "detail-impact"
      next
    }
    state == "detail-impact" {
      if ($0 !~ /^  impact: /) invalid()
      detail_impact = substr($0, 11)
      if (!nonempty(detail_impact)) invalid()
      state = "detail-required-outcome"
      next
    }
    state == "detail-required-outcome" {
      if ($0 !~ /^  required_outcome: /) invalid()
      detail_required_outcome = substr($0, 21)
      if (!nonempty(detail_required_outcome)) invalid()
      state = "detail-constraints"
      next
    }
    state == "detail-constraints" {
      if ($0 !~ /^  constraints: /) invalid()
      detail_constraints = substr($0, 16)
      if (!nonempty(detail_constraints)) invalid()
      state = "detail-validation"
      next
    }
    state == "detail-validation" {
      if ($0 !~ /^  validation: /) invalid()
      detail_validation = substr($0, 15)
      if (!nonempty(detail_validation)) invalid()
      finish_detail()
      next
    }
    state == "details-next" {
      if ($0 == "") {
        state = "verification-header"
        next
      }
      start_detail($0)
      next
    }
    state == "verification-header" {
      if ($0 != "verification:") invalid()
      state = "verification"
      next
    }
    state == "verification" {
      if ($0 == "") next
      if ($0 == "- none") {
        verification_none += 1
        verification_items += 1
        next
      }
      if ($0 !~ /^- F[0-9][0-9][0-9][0-9][0-9]* \| (resolved|invalid|unresolved) \| .+$/) invalid()
      verification_body = substr($0, 3)
      if (split(verification_body, verification_parts, / \| /) != 3) invalid()
      verification_records += 1
      verification_items += 1
      next
    }
    {
      invalid()
    }
    END {
      if (failed) exit 1
      if (state != "verification" || verification_items == 0 || (verification_none > 0 && verification_records > 0)) invalid()
      if (current_count == 0) {
        if (details_none != 1 || detail_count != 0) invalid()
      } else {
        if (details_none != 0 || detail_count != current_count) invalid()
        for (i = 1; i <= current_count; i++) {
          finding = current_order[i]
          if (!(finding in detail_seen)) invalid()
          if (detail_severity_by_finding[finding] != current_severity[finding]) invalid()
        }
        for (finding in detail_seen) {
          if (!(finding in current_severity)) invalid()
        }
      }
    }
  ' "$review_file"
}

write_review_details_artifact() {
  local review_file="$1"
  local output_file="$2"
  local temporary_file

  if [[ ! -f "$review_file" ]]; then
    printf 'Review output file does not exist: %s\n' "$review_file" >&2
    return 1
  fi
  if ! validate_review_details_output "$review_file"; then
    printf 'Review details are invalid: %s\n' "$review_file" >&2
    return 1
  fi

  temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary review details file: %s\n' "$output_file" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' '
    BEGIN {
      print "severity", "finding", "evidence", "impact", "required_outcome", "constraints", "validation"
    }
    $0 == "details:" {
      in_details = 1
      next
    }
    !in_details { next }
    $0 == "" { exit 0 }
    $0 == "- none" { next }
    /^- finding: / {
      finding = substr($0, 12)
      next
    }
    /^  severity: / {
      severity = substr($0, 13)
      next
    }
    /^  evidence: / {
      evidence = substr($0, 13)
      next
    }
    /^  impact: / {
      impact = substr($0, 11)
      next
    }
    /^  required_outcome: / {
      required_outcome = substr($0, 21)
      next
    }
    /^  constraints: / {
      constraints = substr($0, 16)
      next
    }
    /^  validation: / {
      validation = substr($0, 15)
      print severity, finding, evidence, impact, required_outcome, constraints, validation
      next
    }
  ' "$review_file" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to build review details file: %s\n' "$output_file" >&2
    return 1
  fi

  if ! mv -T -f -- "$temporary_file" "$output_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish review details file: %s\n' "$output_file" >&2
    return 1
  fi
}

_build_pending_finding_details_file() {
  local ledger_file="$1"
  local pending_findings_file="$2"
  local review_details_file="$3"
  local output_file="$4"

  awk -F '\t' -v OFS='\t' \
    -v ledger_file="$ledger_file" \
    -v pending_file="$pending_findings_file" \
    -v details_file="$review_details_file" '
    function valid_severity(value) {
      return value == "blocker" || value == "major" || value == "minor"
    }
    function invalid() {
      failed = 1
      exit 1
    }
    index($0, "\r") { invalid() }
    FILENAME == ledger_file {
      if (FNR == 1) next
      if (NF != 7 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !valid_severity($2)) invalid()
      if ($3 !~ /^[1-9][0-9]*$/ || $4 !~ /^[1-9][0-9]*$/ || ($5 != "present" && $5 != "not_observed")) invalid()
      if ($6 != "unresolved" && $6 != "resolved" && $6 != "invalid") invalid()
      if ($7 == "" || $1 in ledger_id_seen || $7 in ledger_text_seen) invalid()
      ledger_id_seen[$1] = 1
      ledger_text_seen[$7] = 1
      ledger_severity[$1] = $2
      ledger_status[$1] = $5
      ledger_resolution[$1] = $6
      ledger_text[$1] = $7
      next
    }
    FILENAME == pending_file {
      if (FNR == 1) next
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !valid_severity($2) || $3 == "") invalid()
      if ($1 in pending_id_seen || $3 in pending_text_seen || !($1 in ledger_id_seen)) invalid()
      if (ledger_severity[$1] != $2 || ledger_text[$1] != $3) invalid()
      if (ledger_status[$1] != "present" || ledger_resolution[$1] != "unresolved") invalid()
      pending_order[++pending_count] = $1
      pending_id_seen[$1] = 1
      pending_text_seen[$3] = 1
      pending_id_by_text[$3] = $1
      pending_severity[$1] = $2
      pending_text[$1] = $3
      next
    }
    FILENAME == details_file {
      if (FNR == 1) next
      if (NF != 7 || !valid_severity($1)) invalid()
      if ($2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "") invalid()
      if ($2 in detail_seen || !($2 in pending_id_by_text)) invalid()
      id = pending_id_by_text[$2]
      if (pending_severity[id] != $1) invalid()
      detail_seen[$2] = 1
      detail_count += 1
      evidence[id] = $3
      impact[id] = $4
      required_outcome[id] = $5
      constraints[id] = $6
      validation[id] = $7
      next
    }
    END {
      if (failed || detail_count != pending_count) exit 1
      print "finding_id", "severity", "text", "evidence", "impact", "required_outcome", "constraints", "validation"
      for (i = 1; i <= pending_count; i++) {
        id = pending_order[i]
        text = pending_text[id]
        if (!(text in detail_seen)) exit 1
        print id, pending_severity[id], text, evidence[id], impact[id], required_outcome[id], constraints[id], validation[id]
      }
    }
  ' "$ledger_file" "$pending_findings_file" "$review_details_file" > "$output_file"
}

write_pending_finding_details() {
  local ledger_file="$1"
  local pending_findings_file="$2"
  local review_details_file="$3"
  local output_file="$4"
  local temporary_file

  if [[ ! -f "$ledger_file" ]]; then
    printf 'Finding ledger does not exist: %s\n' "$ledger_file" >&2
    return 1
  fi
  if [[ ! -f "$pending_findings_file" ]]; then
    printf 'Pending findings file does not exist: %s\n' "$pending_findings_file" >&2
    return 1
  fi
  if [[ ! -f "$review_details_file" ]]; then
    printf 'Review details file does not exist: %s\n' "$review_details_file" >&2
    return 1
  fi
  require_tsv_header "$ledger_file" "$FINDING_LEDGER_HEADER" 'Finding ledger' || return 1
  require_tsv_header "$pending_findings_file" "$PENDING_FINDINGS_HEADER" 'Pending findings' || return 1
  require_tsv_header "$review_details_file" "$REVIEW_DETAILS_HEADER" 'Review details' || return 1

  temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary pending finding details file: %s\n' "$output_file" >&2
    return 1
  }
  if ! _build_pending_finding_details_file \
    "$ledger_file" "$pending_findings_file" "$review_details_file" "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Pending finding details mapping is invalid: %s\n' "$output_file" >&2
    return 1
  fi
  if ! mv -T -f -- "$temporary_file" "$output_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish pending finding details file: %s\n' "$output_file" >&2
    return 1
  fi
}

validate_pending_finding_details_artifact() {
  local ledger_file="$1"
  local pending_findings_file="$2"
  local review_details_file="$3"
  local artifact_file="$4"
  local expected_file

  if [[ ! -f "$artifact_file" ]]; then
    printf 'Pending finding details file does not exist: %s\n' "$artifact_file" >&2
    return 1
  fi
  require_tsv_header "$artifact_file" "$PENDING_FINDING_DETAILS_HEADER" 'Pending finding details' || return 1

  expected_file="$(mktemp)" || {
    printf 'Failed to create temporary pending finding details validation file.\n' >&2
    return 1
  }
  if ! write_pending_finding_details \
    "$ledger_file" "$pending_findings_file" "$review_details_file" "$expected_file"; then
    rm -f -- "$expected_file"
    return 1
  fi
  if ! cmp -s -- "$expected_file" "$artifact_file"; then
    rm -f -- "$expected_file"
    printf 'Pending finding details artifact does not match current review details: %s\n' "$artifact_file" >&2
    return 1
  fi
  rm -f -- "$expected_file"
}

readonly ISSUE_FORGE_REVIEW_DETAILS_LOADED=1
