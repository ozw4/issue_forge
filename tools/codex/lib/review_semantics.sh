#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_REVIEW_SEMANTICS_LOADED:-}" ]]; then
  return 0
fi

review_finding_count_numbers() {
  local review_file="$1"

  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_placeholder_item(value, normalized) {
      normalized = tolower(trim(value))
      return normalized == "none" || normalized == "n/a" || normalized == "no issues" || normalized == "nothing"
    }
    $0 == "blocker:" {
      section = "blocker"
      next
    }
    $0 == "major:" {
      section = "major"
      next
    }
    $0 == "minor:" {
      section = "minor"
      next
    }
    /^- / {
      item = substr($0, 3)
      if (is_placeholder_item(item)) {
        next
      }
      if (section == "blocker") {
        blocker += 1
      } else if (section == "major") {
        major += 1
      } else if (section == "minor") {
        minor += 1
      }
    }
    END {
      printf "%d %d %d\n", blocker + 0, major + 0, minor + 0
    }
  ' "$review_file"
}

review_finding_counts() {
  local review_file="$1"
  local count_numbers
  local blocker_count
  local major_count
  local minor_count

  count_numbers="$(review_finding_count_numbers "$review_file")"
  read -r blocker_count major_count minor_count <<< "$count_numbers"
  printf 'blocker %d, major %d, minor %d\n' "$blocker_count" "$major_count" "$minor_count"
}

review_has_blocker_or_major_findings() {
  local review_file="$1"
  local count_numbers
  local blocker_count
  local major_count
  local minor_count

  count_numbers="$(review_finding_count_numbers "$review_file")"
  read -r blocker_count major_count minor_count <<< "$count_numbers"
  [[ "$blocker_count" -gt 0 || "$major_count" -gt 0 ]]
}

readonly ISSUE_FORGE_REVIEW_SEMANTICS_LOADED=1
