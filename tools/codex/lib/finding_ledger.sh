#!/usr/bin/env bash

update_finding_ledger() {
  local review_output_file="$1"
  local ledger_file="$2"
  local review_round="$3"
  local expected_header=$'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\ttext'
  local existing_header
  local ledger_source='/dev/null'
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
    if ! IFS= read -r existing_header < "$ledger_file" || [[ "$existing_header" != "$expected_header" ]]; then
      printf 'Finding ledger header is invalid: %s\n' "$ledger_file" >&2
      return 1
    fi
    ledger_source="$ledger_file"
  fi

  temporary_file="$(mktemp "${ledger_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary finding ledger file: %s\n' "$ledger_file" >&2
    return 1
  }

  if ! awk -F '\t' -v OFS='\t' -v ledger_source="$ledger_source" -v review_round="$review_round" '
    function severity_rank(value) {
      if (value == "blocker") return 3
      if (value == "major") return 2
      if (value == "minor") return 1
      return 0
    }
    FILENAME == ledger_source {
      if (FNR == 1) next
      number = substr($1, 2) + 0
      id_by_text[$6] = $1
      severity_by_text[$6] = $2
      first_round_by_text[$6] = $3
      last_seen_round_by_text[$6] = $4
      text_by_number[number] = $6
      if (number > maximum_id) maximum_id = number
      next
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == "blocker:" || line == "major:" || line == "minor:") {
        section = substr(line, 1, length(line) - 1)
        next
      }
      if (section != "" && line ~ /^- /) {
        text = substr(line, 3)
        gsub(/\t/, " ", text)
        if (text == "none") next
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
        present[text] = 1
      }

      print "finding_id", "severity", "first_round", "last_seen_round", "status", "text"
      for (number = 1; number <= maximum_id; number++) {
        if (!(number in text_by_number)) continue
        text = text_by_number[number]
        status = (text in present) ? "present" : "not_observed"
        print id_by_text[text], severity_by_text[text], first_round_by_text[text], last_seen_round_by_text[text], status, text
      }
    }
  ' "$ledger_source" "$review_output_file" > "$temporary_file"; then
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
