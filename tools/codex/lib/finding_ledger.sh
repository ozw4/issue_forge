#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_FINDING_LEDGER_LOADED:-}" ]]; then
  return 0
fi

readonly FINDING_LEDGER_HEADER=$'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext'
readonly PENDING_FINDINGS_HEADER=$'finding_id\tseverity\ttext'
readonly FIX_RESOLUTION_HEADER=$'finding_id\taction\tnote'
readonly REVIEW_VERIFICATION_HEADER=$'finding_id\tresolution\tnote'

require_tsv_header() {
  local file="$1"
  local expected_header="$2"
  local description="$3"
  local actual_header

  if ! IFS= read -r actual_header < "$file" || [[ "$actual_header" != "$expected_header" ]]; then
    printf '%s header is invalid: %s\n' "$description" "$file" >&2
    return 1
  fi
}

write_pending_findings() {
  local ledger_file="$1"
  local output_file="$2"
  local temporary_file

  if [[ ! -f "$ledger_file" ]]; then
    printf 'Finding ledger does not exist: %s\n' "$ledger_file" >&2
    return 1
  fi
  require_tsv_header "$ledger_file" "$FINDING_LEDGER_HEADER" 'Finding ledger' || return 1

  temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary pending findings file: %s\n' "$output_file" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' '
    BEGIN { print "finding_id", "severity", "text" }
    FNR == 1 { next }
    $5 == "present" && $6 == "unresolved" { print $1, $2, $7 }
  ' "$ledger_file" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to build pending findings file: %s\n' "$output_file" >&2
    return 1
  fi

  if ! mv -T -f -- "$temporary_file" "$output_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish pending findings file: %s\n' "$output_file" >&2
    return 1
  fi
}

extract_fix_resolution_report() {
  local fix_log="$1"
  local pending_findings_file="$2"
  local output_tsv="$3"
  local parser_input="$fix_log"
  local sanitized_log=''
  local temporary_file

  if [[ ! -f "$fix_log" ]]; then
    printf 'Fix log does not exist: %s\n' "$fix_log" >&2
    return 1
  fi
  if [[ ! -f "$pending_findings_file" ]]; then
    printf 'Pending findings file does not exist: %s\n' "$pending_findings_file" >&2
    return 1
  fi
  require_tsv_header "$pending_findings_file" "$PENDING_FINDINGS_HEADER" 'Pending findings' || return 1

  if declare -F sanitize_codex_runtime_logs >/dev/null; then
    sanitized_log="$(mktemp)" || {
      printf 'Failed to create temporary sanitized fix log.\n' >&2
      return 1
    }
    if ! sanitize_codex_runtime_logs "$fix_log" > "$sanitized_log"; then
      rm -f -- "$sanitized_log"
      return 1
    fi
    parser_input="$sanitized_log"
  fi

  temporary_file="$(mktemp "${output_tsv}.tmp.XXXXXX")" || {
    rm -f -- "$sanitized_log"
    printf 'Failed to create temporary fix resolution file: %s\n' "$output_tsv" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' -v pending_file="$pending_findings_file" -v fix_log="$parser_input" '
    FILENAME == pending_file {
      if (FNR == 1) next
      pending_order[++pending_count] = $1
      pending[$1] = 1
      next
    }
    FILENAME == fix_log {
      log_lines[++log_count] = $0
      next
    }
    END {
      for (i = log_count; i >= 1; i--) {
        if (log_lines[i] == "resolution:") {
          start = i + 1
          break
        }
      }
      if (start == 0) exit 1

      for (i = start; i <= log_count; i++) {
        line = log_lines[i]
        sub(/\r$/, "", line)
        if (line == "") {
          if (report_count > 0) {
            trailing_blank = 1
            continue
          }
          exit 1
        }
        if (trailing_blank) exit 1
        if (line !~ /^- /) exit 1
        body = substr(line, 3)
        # A note cannot contain the literal delimiter, so exactly three parts are required.
        part_count = split(body, parts, / \| /)
        if (part_count != 3) exit 1
        id = parts[1]
        action = parts[2]
        note = parts[3]
        if (id !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !(id in pending) || id in seen) exit 1
        if (action != "fixed" && action != "false_positive" && action != "cannot_fix") exit 1
        if (note == "" || note ~ /\t/) exit 1
        seen[id] = 1
        action_by_id[id] = action
        note_by_id[id] = note
        report_count += 1
      }

      if (report_count != pending_count) exit 1
      print "finding_id", "action", "note"
      for (i = 1; i <= pending_count; i++) {
        id = pending_order[i]
        if (!(id in seen)) exit 1
        print id, action_by_id[id], note_by_id[id]
      }
    }
  ' "$pending_findings_file" "$parser_input" > "$temporary_file"; then
    rm -f -- "$temporary_file" "$sanitized_log"
    printf 'Fix resolution report is invalid: %s\n' "$fix_log" >&2
    return 1
  fi

  if ! mv -T -f -- "$temporary_file" "$output_tsv"; then
    rm -f -- "$temporary_file" "$sanitized_log"
    printf 'Failed to publish fix resolution report: %s\n' "$output_tsv" >&2
    return 1
  fi
  rm -f -- "$sanitized_log"
}

extract_review_verification() {
  local review_output_file="$1"
  local ledger_file="$2"
  local fix_resolution_file="$3"
  local output_tsv="$4"
  local ledger_source='/dev/null'
  local fix_source='/dev/null'
  local temporary_file

  if [[ ! -f "$review_output_file" ]]; then
    printf 'Review output file does not exist: %s\n' "$review_output_file" >&2
    return 1
  fi
  if [[ -f "$ledger_file" ]]; then
    require_tsv_header "$ledger_file" "$FINDING_LEDGER_HEADER" 'Finding ledger' || return 1
    ledger_source="$ledger_file"
  fi
  if [[ -n "$fix_resolution_file" && -f "$fix_resolution_file" ]]; then
    require_tsv_header "$fix_resolution_file" "$FIX_RESOLUTION_HEADER" 'Fix resolution report' || return 1
    fix_source="$fix_resolution_file"
    if [[ "$ledger_source" == '/dev/null' ]]; then
      printf 'Finding ledger is required for review verification: %s\n' "$ledger_file" >&2
      return 1
    fi
  fi

  temporary_file="$(mktemp "${output_tsv}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary review verification file: %s\n' "$output_tsv" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' -v ledger_source="$ledger_source" -v fix_source="$fix_source" -v review_file="$review_output_file" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_placeholder_item(value, normalized) {
      normalized = tolower(trim(value))
      return normalized == "none" || normalized == "n/a" || normalized == "no issues" || normalized == "nothing"
    }
    FILENAME == ledger_source {
      if (FNR == 1) next
      ledger_text[$1] = $7
      next
    }
    FILENAME == fix_source {
      if (FNR == 1) next
      expected_order[++expected_count] = $1
      expected[$1] = 1
      next
    }
    FILENAME == review_file {
      line = $0
      sub(/\r$/, "", line)
      if (line == "blocker:" || line == "major:" || line == "minor:") {
        section = substr(line, 1, length(line) - 1)
        next
      }
      if (line == "details:") {
        section = "details"
        next
      }
      if (line == "verification:") {
        section = "verification"
        next
      }
      if (line !~ /^- /) next
      body = substr(line, 3)
      if (section == "blocker" || section == "major" || section == "minor") {
        gsub(/\t/, " ", body)
        if (!is_placeholder_item(body)) current[body] = 1
        next
      }
      if (section != "verification") next
      if (body == "none") {
        none_count += 1
        next
      }
      # A note cannot contain the literal delimiter, so exactly three parts are required.
      part_count = split(body, parts, / \| /)
      if (part_count != 3) exit 1
      id = parts[1]
      resolution = parts[2]
      note = parts[3]
      if (id !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/ || !(id in expected) || id in seen) exit 1
      if (resolution != "resolved" && resolution != "invalid" && resolution != "unresolved") exit 1
      if (note == "" || note ~ /\t/) exit 1
      seen[id] = 1
      resolution_by_id[id] = resolution
      note_by_id[id] = note
      verification_count += 1
      next
    }
    END {
      if (fix_source == "/dev/null") {
        if (none_count != 1 || verification_count != 0) exit 1
        print "finding_id", "resolution", "note"
        exit 0
      }
      if (none_count != 0 || verification_count != expected_count) exit 1
      print "finding_id", "resolution", "note"
      for (i = 1; i <= expected_count; i++) {
        id = expected_order[i]
        if (!(id in seen) || !(id in ledger_text)) exit 1
        resolution = resolution_by_id[id]
        text = ledger_text[id]
        if (resolution == "unresolved" && !(text in current)) exit 1
        if ((resolution == "resolved" || resolution == "invalid") && text in current) exit 1
        print id, resolution, note_by_id[id]
      }
    }
  ' "$ledger_source" "$fix_source" "$review_output_file" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Review verification is invalid: %s\n' "$review_output_file" >&2
    return 1
  fi

  if ! mv -T -f -- "$temporary_file" "$output_tsv"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish review verification: %s\n' "$output_tsv" >&2
    return 1
  fi
}

update_finding_ledger() {
  local review_output_file="$1"
  local ledger_file="$2"
  local review_round="$3"
  local verification_tsv="${4:-}"
  local existing_header
  local ledger_source='/dev/null'
  local verification_source='/dev/null'
  local temporary_file

  if [[ ! -f "$review_output_file" ]]; then
    printf 'Review output file does not exist: %s\n' "$review_output_file" >&2
    return 1
  fi
  if [[ ! "$review_round" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Review round must be a positive integer: %s\n' "$review_round" >&2
    return 1
  fi
  if [[ -f "$ledger_file" ]]; then
    if ! IFS= read -r existing_header < "$ledger_file" || [[ "$existing_header" != "$FINDING_LEDGER_HEADER" ]]; then
      printf 'Finding ledger header is invalid: %s\n' "$ledger_file" >&2
      return 1
    fi
    ledger_source="$ledger_file"
  fi
  if [[ -n "$verification_tsv" ]]; then
    if [[ ! -f "$verification_tsv" ]]; then
      printf 'Review verification file does not exist: %s\n' "$verification_tsv" >&2
      return 1
    fi
    require_tsv_header "$verification_tsv" "$REVIEW_VERIFICATION_HEADER" 'Review verification' || return 1
    verification_source="$verification_tsv"
  fi

  temporary_file="$(mktemp "${ledger_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary finding ledger file: %s\n' "$ledger_file" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' -v ledger_source="$ledger_source" -v verification_source="$verification_source" -v review_file="$review_output_file" -v review_round="$review_round" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_placeholder_item(value, normalized) {
      normalized = tolower(trim(value))
      return normalized == "none" || normalized == "n/a" || normalized == "no issues" || normalized == "nothing"
    }
    function severity_rank(value) {
      if (value == "blocker") return 3
      if (value == "major") return 2
      if (value == "minor") return 1
      return 0
    }
    FILENAME == ledger_source {
      if (FNR == 1) next
      number = substr($1, 2) + 0
      id_by_text[$7] = $1
      text_by_id[$1] = $7
      severity_by_text[$7] = $2
      first_round_by_text[$7] = $3
      last_seen_round_by_text[$7] = $4
      resolution_by_text[$7] = $6
      text_by_number[number] = $7
      if (number > maximum_id) maximum_id = number
      next
    }
    FILENAME == verification_source {
      if (FNR == 1) next
      if (!($1 in text_by_id)) exit 1
      if ($2 != "resolved" && $2 != "invalid" && $2 != "unresolved") exit 1
      resolution_by_text[text_by_id[$1]] = $2
      next
    }
    FILENAME == review_file {
      line = $0
      sub(/\r$/, "", line)
      if (line == "blocker:" || line == "major:" || line == "minor:") {
        section = substr(line, 1, length(line) - 1)
        next
      }
      if (line == "details:") {
        section = ""
        next
      }
      if (line == "verification:") {
        section = ""
        next
      }
      if (section != "" && line ~ /^- /) {
        text = substr(line, 3)
        gsub(/\t/, " ", text)
        if (is_placeholder_item(text)) next
        if (!(text in current_severity)) {
          current_order[++current_count] = text
          current_severity[text] = section
        } else if (severity_rank(section) > severity_rank(current_severity[text])) {
          current_severity[text] = section
        }
      }
    }
    END {
      for (order_index = 1; order_index <= current_count; order_index++) {
        text = current_order[order_index]
        if (!(text in id_by_text)) {
          maximum_id += 1
          id_by_text[text] = sprintf("F%04d", maximum_id)
          first_round_by_text[text] = review_round
          text_by_number[maximum_id] = text
        }
        severity_by_text[text] = current_severity[text]
        last_seen_round_by_text[text] = review_round
        resolution_by_text[text] = "unresolved"
        present[text] = 1
      }

      print "finding_id", "severity", "first_round", "last_seen_round", "status", "resolution", "text"
      for (number = 1; number <= maximum_id; number++) {
        if (!(number in text_by_number)) continue
        text = text_by_number[number]
        status = (text in present) ? "present" : "not_observed"
        print id_by_text[text], severity_by_text[text], first_round_by_text[text], last_seen_round_by_text[text], status, resolution_by_text[text], text
      }
    }
  ' "$ledger_source" "$verification_source" "$review_output_file" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to build finding ledger: %s\n' "$ledger_file" >&2
    return 1
  fi

  if ! mv -T -f -- "$temporary_file" "$ledger_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish finding ledger: %s\n' "$ledger_file" >&2
    return 1
  fi
}

readonly ISSUE_FORGE_FINDING_LEDGER_LOADED=1
