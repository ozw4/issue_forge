#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=tools/codex/lib/attempt_store.sh
source "${SCRIPT_DIR}/lib/attempt_store.sh"
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "${SCRIPT_DIR}/lib/token_usage_helpers.sh"

fail() {
  printf '[smoke] attempt store: %s\n' "$1" >&2
  exit 1
}

read_field() {
  awk -F '\t' -v key="$2" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "$1"
}

assert_field() {
  local file="$1" key="$2" expected="$3"
  local actual
  actual="$(read_field "$file" "$key")" || fail "missing ${key} in ${file}"
  [[ "$actual" == "$expected" ]] || fail "${file} ${key}: expected ${expected}, found ${actual}"
}

extract_structured_review_output_file() {
  local raw="$1" parsed="$2"
  grep -Fxq 'valid review' "$raw" || return 1
  printf 'accept: yes\n\nblocker:\n- none\n\nmajor:\n- none\n\nminor:\n- none\n' > "$parsed"
}

temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

issue_root="${temp_root}/.work/codex"
issue_attempts="${issue_root}/attempts"
issue_number=40
issue_attempt=''
issue_log=''
run_logged_attempt issue_attempt issue_log \
  "$issue_attempts" review 1 read medium none "${issue_root}/review.raw.txt" combined -- \
  bash -c 'printf "valid review\ntokens used\n123\n"'
append_codex_token_usage \
  "${issue_root}/token-usage.tsv" \
  $'phase\tissue\tround\treasoning\ttokens\tlog' \
  review "$issue_number" 1 medium "$issue_log"

assert_field "${issue_attempt}/input.state" scope issue
assert_field "${issue_attempt}/input.state" scope_id "$issue_number"
assert_field "${issue_attempt}/result.state" status succeeded
assert_field "${issue_attempt}/result.state" parser_status succeeded
[[ -f "${issue_attempt}/parsed-review.txt" ]] || fail 'missing parsed review artifact'
[[ -f "${issue_root}/review.raw.txt" && -f "${issue_root}/review.txt" ]] \
  || fail 'missing review compatibility views'
grep -Fq $'review\t40\t1\tmedium\t123\t./attempts/' "${issue_root}/token-usage.tsv" \
  || fail 'token usage does not use an archive-stable relative attempt path'

issue_archive="${temp_root}/issue-archive"
cp -a "$issue_root" "$issue_archive"
rm -rf -- "$issue_root"
archived_log="$(awk -F '\t' 'NR == 2 { print $6 }' "${issue_archive}/token-usage.tsv")"
[[ -f "${issue_archive}/${archived_log#./}" ]] \
  || fail 'token usage log path did not survive archive relocation'

retry_repo="${temp_root}/retry-repo"
mkdir -p "$retry_repo"
(
  cd "$retry_repo"
  git init -q
  git config user.name smoke
  git config user.email smoke@example.com
  printf 'base\n' > code.txt
  git add code.txt
  git commit -qm base
  printf 'implementation\n' > code.txt
  mkdir -p .work/history
  CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(':(exclude).work')
  CODEX_FLOW_REVIEW_RETRY_LIMIT=2
  review_diff=.work/review.diff
  review_untracked=.work/review.untracked.txt
  review_summary=.work/review.summary.txt
  review_prompt=.work/review.prompt.md
  review_raw_output=.work/review.raw.txt
  review_output=.work/review.txt
  history_dir=.work/history
  printf 'review\n' > "$review_prompt"
  generate_review_material() {
    git diff --binary > "$review_diff"
    : > "$review_untracked"
    printf 'summary\n' > "$review_summary"
  }
  archive_round_file() { :; }
  status_outside_work() {
    git status --porcelain --untracked-files=all -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
  }
  reviewer=.work/reviewer.sh
  counter=.work/reviewer-count
  cat > "$reviewer" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
counter="$1"
count=0
[[ ! -f "$counter" ]] || count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" > "$counter"
if [[ "$count" == 1 ]]; then printf 'reviewer change\n' >> code.txt; fi
printf 'valid review\n'
SCRIPT
  chmod +x "$reviewer"
  generate_review_material
  before_status="$(status_outside_work)"
  retry_attempt=''
  retry_log=''
  run_logged_attempt retry_attempt retry_log .work/attempts review 1 read medium \
    "$review_prompt" "$review_raw_output" combined -- "$reviewer" "$counter"
  [[ "$(cat "$counter")" == 2 ]] || fail 'review was not rerun after repository change'
  [[ "$before_status" == "$(status_outside_work)" ]] \
    || fail 'outer review status baseline was not refreshed'
  [[ "$(find .work/attempts -maxdepth 1 -type d -name 'review.*' | wc -l)" == 2 ]] \
    || fail 'review retry did not preserve both attempts'
  grep -R -l $'status\tinvalid' .work/attempts/review.*/result.state >/dev/null \
    || fail 'changed review attempt was not recorded as invalid'
)

queue_root="${temp_root}/.work/queue"
compatibility_attempts="${queue_root}/batches/batch-10-12/attempts"
compatibility_log="${queue_root}/batches/batch-10-12/checks.log"
for run_id in run-a run-b; do
  run_state_dir="${queue_root}/runs/${run_id}"
  current_batch_id='batch-10-12'
  mkdir -p "${run_state_dir}/batches/${current_batch_id}"
  batch_attempt=''
  batch_log=''
  run_logged_attempt batch_attempt batch_log \
    "$compatibility_attempts" batch-checks 1 check none none "$compatibility_log" combined -- \
    bash -c 'printf "checks passed\n"'
  expected_root="${run_state_dir}/batches/${current_batch_id}/attempts"
  [[ "$batch_attempt" == "${expected_root}/"* ]] || fail "batch attempt escaped run-owned root: ${batch_attempt}"
  assert_field "${batch_attempt}/input.state" run_id "$run_id"
  assert_field "${batch_attempt}/input.state" scope batch
  assert_field "${batch_attempt}/input.state" scope_id "$current_batch_id"
  assert_field "${expected_root}/latest/batch-checks.state" attempt_id "${batch_attempt##*/}"
done
[[ ! -e "$compatibility_attempts" ]] || fail 'compatibility batch path contains authoritative attempts'

printf '[smoke] attempt store contract passed\n'
