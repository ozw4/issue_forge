#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "${SCRIPT_DIR}/lib/token_usage_helpers.sh"

readonly FINDING_HEADER=$'finding_id\tseverity\tfirst_round\tlast_seen_round\tstatus\tresolution\ttext'
readonly FIX_HEADER=$'finding_id\taction\tnote'
readonly CHECK_HEADER=$'check_id\tscope\tscope_id\toperation\tround\tattempt_id\tkind\trequirement_id\tbase_commit\tsnapshot_head\tsnapshot_tree\tstatus\texit_status\tsignal\tstarted_at\tfinished_at\tduration_ms\tlog_path\tlog_sha256'
readonly OUTPUT_HEADER=$'run_id\tstate\tcreated_at\tissues\tbatches\tfindings\tblocker\tmajor\tminor\tresolved\tinvalid\tunresolved\tfixer_claims\tfixed_claims\tfalse_positive_claims\tcannot_fix_claims\tlatest_fixed\tlatest_fixed_resolved\tlatest_fixed_resolved_rate\treview_attempts\tfixer_attempts\tagent_attempts\tagent_failures\ttokens\tfull_checks\tcheck_failures\tcheck_duration_ms'

fail() {
  printf '[run-summary] %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--no-header] <queue-run-directory>\n' "$0"
}

state_value() {
  local file="$1"
  local key="$2"

  [[ -f "$file" && ! -L "$file" ]] || fail "State file is missing or invalid: ${file}"
  awk -F '\t' -v requested="$key" '
    NF != 2 || index($0, "\r") { exit 1 }
    $1 == requested {
      if (found || $2 == "") exit 1
      value = $2
      found = 1
    }
    END {
      if (!found) exit 1
      print value
    }
  ' "$file" || fail "State key ${key} is missing or invalid in: ${file}"
}

require_header() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual

  [[ -f "$file" && ! -L "$file" ]] || fail "${label} is missing or invalid: ${file}"
  IFS= read -r actual < "$file" || fail "${label} is empty: ${file}"
  [[ "$actual" == "$expected" ]] || fail "${label} header is invalid: ${file}"
}

extract_tokens() {
  local log_file="$1"
  local tokens

  [[ -f "$log_file" && ! -L "$log_file" ]] || {
    printf '0\n'
    return 0
  }
  tokens="$(extract_codex_token_usage "$log_file" || true)"
  printf '%s\n' "${tokens:-0}"
}

append_findings() {
  local prefix="$1"
  local ledger="$2"
  local output="$3"

  require_header "$ledger" "$FINDING_HEADER" 'Finding ledger'
  awk -F '\t' -v OFS='\t' -v prefix="$prefix" '
    NR == 1 { next }
    {
      if (NF != 7 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) exit 1
      if ($2 != "blocker" && $2 != "major" && $2 != "minor") exit 1
      if ($6 != "resolved" && $6 != "invalid" && $6 != "unresolved") exit 1
      print prefix $1, $2, $6
    }
  ' "$ledger" >> "$output" || fail "Finding ledger rows are invalid: ${ledger}"
}

append_claims_file() {
  local prefix="$1"
  local rank="$2"
  local report="$3"
  local output="$4"

  require_header "$report" "$FIX_HEADER" 'Fix resolution report'
  awk -F '\t' -v OFS='\t' -v prefix="$prefix" -v rank="$rank" '
    NR == 1 { next }
    {
      if (NF != 3 || $1 !~ /^F[0-9][0-9][0-9][0-9][0-9]*$/) exit 1
      if ($2 != "fixed" && $2 != "false_positive" && $2 != "cannot_fix") exit 1
      if ($3 == "" || seen[$1]++) exit 1
      print prefix $1, rank, $2
    }
  ' "$report" >> "$output" || fail "Fix resolution rows are invalid: ${report}"
}

append_claim_history() {
  local prefix="$1"
  local root="$2"
  local output="$3"
  local history_file
  local name
  local rank
  local last_history=''
  local current_report="${root}/fix-resolution.tsv"

  if [[ -e "${root}/history" || -L "${root}/history" ]]; then
    [[ -d "${root}/history" && ! -L "${root}/history" ]] \
      || fail "Fix resolution history directory is invalid: ${root}/history"
    while IFS= read -r -d '' history_file; do
      name="${history_file##*/}"
      [[ "$name" =~ ^fix-resolution\.round-([0-9]+)\.tsv$ ]] \
        || fail "Unexpected fix resolution history name: ${history_file}"
      rank=$((10#${BASH_REMATCH[1]}))
      append_claims_file "$prefix" "$rank" "$history_file" "$output"
      last_history="$history_file"
    done < <(
      find "${root}/history" -mindepth 1 -maxdepth 1 -type f \
        -name 'fix-resolution.round-*.tsv' -print0 | sort -z -V
    )
  fi

  if [[ -e "$current_report" || -L "$current_report" ]]; then
    require_header "$current_report" "$FIX_HEADER" 'Fix resolution report'
  fi
  if [[ -f "$current_report" && ! -L "$current_report" ]] \
    && [[ "$(awk 'END { print NR }' "$current_report")" -gt 1 ]] \
    && { [[ -z "$last_history" ]] || ! cmp -s -- "$current_report" "$last_history"; }; then
    append_claims_file "$prefix" 999999999 "$current_report" "$output"
  fi
}

no_header=0
if [[ "${1:-}" == '--no-header' ]]; then
  no_header=1
  shift
fi
[[ "$#" -eq 1 ]] || {
  usage >&2
  exit 1
}

run_dir="${1%/}"
[[ -d "$run_dir" && ! -L "$run_dir" ]] || fail "Queue run directory is invalid: ${run_dir}"
[[ -d "${run_dir}/batches" && ! -L "${run_dir}/batches" ]] \
  || fail "Queue run batches directory is invalid: ${run_dir}/batches"

manifest="${run_dir}/manifest.state"
run_state_file="${run_dir}/run.state"
[[ "$(state_value "$manifest" schema_version)" == 3 ]] || fail 'Unsupported manifest schema.'
[[ "$(state_value "$run_state_file" schema_version)" == 3 ]] || fail 'Unsupported run schema.'
run_id="$(state_value "$manifest" run_id)"
[[ "$(state_value "$run_state_file" run_id)" == "$run_id" ]] \
  || fail 'Manifest and run state have different run IDs.'
state="$(state_value "$run_state_file" state)"
created_at="$(state_value "$manifest" created_at)"
issues="$(state_value "$manifest" issues)"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'Run ID is invalid.'
[[ "$state" =~ ^(planned|running|interrupted|failed|manual_review_required|completed)$ ]] \
  || fail 'Run state is invalid.'
[[ "$issues" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || fail 'Manifest Issue list is invalid.'

tmp="$(mktemp -d)"
findings_file="${tmp}/findings.tsv"
claims_file="${tmp}/claims.tsv"
trap 'rm -f -- "$findings_file" "$claims_file"; rmdir -- "$tmp"' EXIT
: > "$findings_file"
: > "$claims_file"

batches=0
while IFS= read -r -d '' batch_state; do
  batch_id="$(state_value "$batch_state" batch_id)"
  batch_root="${batch_state%/batch.state}"
  [[ "$batch_id" =~ ^batch-[1-9][0-9]*-[1-9][0-9]*$ \
    && "${batch_root##*/}" == "$batch_id" ]] \
    || fail "Batch state identity is invalid: ${batch_state}"
  batches=$((batches + 1))
  if [[ -f "${batch_root}/findings.tsv" && ! -L "${batch_root}/findings.tsv" ]]; then
    prefix="batch:${batch_id}:${batch_id}:"
    append_findings "$prefix" "${batch_root}/findings.tsv" "$findings_file"
    append_claim_history "$prefix" "$batch_root" "$claims_file"
  fi
done < <(
  find "${run_dir}/batches" -mindepth 2 -maxdepth 2 -type f -name batch.state -print0 | sort -z
)

if [[ -d "${run_dir}/archives" && ! -L "${run_dir}/archives" ]]; then
  while IFS= read -r -d '' ledger; do
    relative="${ledger#"${run_dir}/archives/"}"
    IFS='/' read -r batch_id issues_segment issue_number _commit codex_segment file_name extra <<< "$relative"
    [[ "$issues_segment" == issues && "$codex_segment" == codex \
      && "$file_name" == findings.tsv && -z "${extra:-}" \
      && "$batch_id" =~ ^batch-[1-9][0-9]*-[1-9][0-9]*$ \
      && "$issue_number" =~ ^[1-9][0-9]*$ && "$_commit" =~ ^[0-9a-f]{40}$ ]] \
      || fail "Unexpected Issue archive path: ${ledger}"
    prefix="issue:${issue_number}:${batch_id}:"
    append_findings "$prefix" "$ledger" "$findings_file"
    append_claim_history "$prefix" "${ledger%/findings.tsv}" "$claims_file"
  done < <(
    find "${run_dir}/archives" -type f -path '*/issues/*/*/codex/findings.tsv' -print0 | sort -z
  )
fi

metrics="$(awk -F '\t' '
  FILENAME == ARGV[1] {
    key = $1
    rank = $2 + 0
    claims += 1
    action_count[$3] += 1
    if (!(key in latest_rank) || rank >= latest_rank[key]) {
      latest_rank[key] = rank
      latest_action[key] = $3
    }
    next
  }
  FILENAME == ARGV[2] {
    key = $1
    if (seen[key]++) exit 2
    findings += 1
    severity[$2] += 1
    resolution[$3] += 1
    if (latest_action[key] == "fixed") {
      latest_fixed += 1
      if ($3 == "resolved") latest_fixed_resolved += 1
    }
  }
  END {
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      findings, severity["blocker"], severity["major"], severity["minor"], \
      resolution["resolved"], resolution["invalid"], resolution["unresolved"], \
      claims, action_count["fixed"], action_count["false_positive"], \
      action_count["cannot_fix"], latest_fixed
    printf "%d\n", latest_fixed_resolved
  }
' "$claims_file" "$findings_file")" || fail 'Finding summary could not be calculated.'
IFS=$'\t' read -r \
  findings blocker major minor resolved invalid unresolved fixer_claims fixed_claims \
  false_positive_claims cannot_fix_claims latest_fixed <<< "$(printf '%s\n' "$metrics" | sed -n '1p')"
latest_fixed_resolved="$(printf '%s\n' "$metrics" | sed -n '2p')"
latest_fixed_resolved_rate="$(awk -v numerator="$latest_fixed_resolved" -v denominator="$latest_fixed" 'BEGIN {
  if (denominator == 0) print "n/a"
  else printf "%.1f%%", 100 * numerator / denominator
}')"

agent_attempts=0
agent_failures=0
review_attempts=0
fixer_attempts=0
tokens=0
while IFS= read -r -d '' request; do
  attempt_dir="${request%/request.state}"
  operation="$(state_value "$request" operation)"
  agent_attempts=$((agent_attempts + 1))
  case "$operation" in
    review|review-light|batch-review) review_attempts=$((review_attempts + 1)) ;;
    fix-from-review|batch-fix-from-review) fixer_attempts=$((fixer_attempts + 1)) ;;
  esac
  result_state="${attempt_dir}/result.state"
  if [[ ! -e "$result_state" && ! -L "$result_state" ]]; then
    agent_failures=$((agent_failures + 1))
  else
    result_status="$(state_value "$result_state" status)" \
      || fail "Agent result state is invalid: ${result_state}"
    if [[ "$result_status" != completed ]]; then
      agent_failures=$((agent_failures + 1))
    fi
  fi
  attempt_tokens="$(extract_tokens "${attempt_dir}/agent.log")"
  tokens=$((tokens + attempt_tokens))
done < <(
  find "${run_dir}/batches" -type f \
    \( -path '*/attempts/*/*/attempt-*/request.state' \
       -o -path '*/attempts/*/*/attempt-*.running/request.state' \) \
    -print0 | sort -z
)

full_checks=0
check_failures=0
check_duration_ms=0
while IFS= read -r -d '' check_manifest; do
  require_header "$check_manifest" "$CHECK_HEADER" 'Check manifest'
  check_metrics="$(awk -F '\t' '
      NR == 1 { next }
      {
        if (NF != 19 || $12 !~ /^(passed|failed|interrupted|invalid)$/ || $17 !~ /^[0-9]+$/) exit 1
        checks += 1
        if ($12 != "passed") failures += 1
        duration += $17
      }
      END { print checks + 0, failures + 0, duration + 0 }
    ' "$check_manifest")" || fail "Check manifest rows are invalid: ${check_manifest}"
  read -r manifest_checks manifest_failures manifest_duration <<< "$check_metrics" \
    || fail "Check manifest metrics are invalid: ${check_manifest}"
  full_checks=$((full_checks + manifest_checks))
  check_failures=$((check_failures + manifest_failures))
  check_duration_ms=$((check_duration_ms + manifest_duration))
done < <(
  find "${run_dir}/batches" -type f -path '*/checks/*.manifest.tsv' -print0 | sort -z
)

if [[ "$no_header" -eq 0 ]]; then
  printf '%s\n' "$OUTPUT_HEADER"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$run_id" "$state" "$created_at" "$issues" "$batches" \
  "$findings" "$blocker" "$major" "$minor" "$resolved" "$invalid" "$unresolved" \
  "$fixer_claims" "$fixed_claims" "$false_positive_claims" "$cannot_fix_claims" \
  "$latest_fixed" "$latest_fixed_resolved" "$latest_fixed_resolved_rate" \
  "$review_attempts" "$fixer_attempts" "$agent_attempts" "$agent_failures" "$tokens" \
  "$full_checks" "$check_failures" "$check_duration_ms"
