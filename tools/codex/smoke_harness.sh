#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REAL_GIT="$(command -v git)"
readonly ISSUE_NUMBER=40
readonly ISSUE_TITLE='Regression Harness Issue'
readonly ISSUE_URL='https://example.test/issues/40'

log() {
  printf '[smoke] %s\n' "$1"
}

fail() {
  printf '[smoke] %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf '[smoke] assert_equals failed: %s\n' "$message" >&2
    printf '[smoke] expected: %s\n' "$expected" >&2
    printf '[smoke] actual: %s\n' "$actual" >&2
    exit 1
  fi
}

assert_file_exists() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    fail "expected file to exist: $path"
  fi
}

assert_file_contains() {
  local path="$1"
  local pattern="$2"

  if ! grep -Fq "$pattern" "$path"; then
    printf '[smoke] expected %s to contain: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

assert_files_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if ! cmp -s "$expected" "$actual"; then
    printf '[smoke] file comparison failed: %s\n' "$message" >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
  fi
}

copy_flow_scripts() {
  mkdir -p "${repo_dir}/tools/codex/lib" "${repo_dir}/tools/codex/prompts" "${repo_dir}/tools/issue" "${repo_dir}/tools/checks" "${repo_dir}/.issue_forge"
  cp "${REPO_ROOT}/tools/codex/lib/checks_review_helpers.sh" "${repo_dir}/tools/codex/lib/checks_review_helpers.sh"
  cp "${REPO_ROOT}/tools/codex/lib/engine_defaults.sh" "${repo_dir}/tools/codex/lib/engine_defaults.sh"
  cp "${REPO_ROOT}/tools/codex/lib/consumer_config.sh" "${repo_dir}/tools/codex/lib/consumer_config.sh"
  cp "${REPO_ROOT}/tools/codex/lib/codex_profiles.sh" "${repo_dir}/tools/codex/lib/codex_profiles.sh"
  cp "${REPO_ROOT}/tools/codex/lib/flow_state.sh" "${repo_dir}/tools/codex/lib/flow_state.sh"
  cp "${REPO_ROOT}/tools/codex/lib/history_helpers.sh" "${repo_dir}/tools/codex/lib/history_helpers.sh"
  cp "${REPO_ROOT}/tools/codex/lib/issue_bootstrap.sh" "${repo_dir}/tools/codex/lib/issue_bootstrap.sh"
  cp "${REPO_ROOT}/tools/codex/lib/prompt_templates.sh" "${repo_dir}/tools/codex/lib/prompt_templates.sh"
  cp "${REPO_ROOT}/tools/codex/lib/publish_helpers.sh" "${repo_dir}/tools/codex/lib/publish_helpers.sh"
  cp "${REPO_ROOT}/tools/codex/prompts/implementation.prompt.md.tmpl" "${repo_dir}/tools/codex/prompts/implementation.prompt.md.tmpl"
  cp "${REPO_ROOT}/tools/codex/prompts/fix-from-checks.prompt.md.tmpl" "${repo_dir}/tools/codex/prompts/fix-from-checks.prompt.md.tmpl"
  cp "${REPO_ROOT}/tools/codex/prompts/review.prompt.md.tmpl" "${repo_dir}/tools/codex/prompts/review.prompt.md.tmpl"
  cp "${REPO_ROOT}/tools/codex/prompts/fix-from-review.prompt.md.tmpl" "${repo_dir}/tools/codex/prompts/fix-from-review.prompt.md.tmpl"
  cp "${REPO_ROOT}/tools/codex/continue_after_review.sh" "${repo_dir}/tools/codex/continue_after_review.sh"
  cp "${REPO_ROOT}/tools/codex/make_pr_only.sh" "${repo_dir}/tools/codex/make_pr_only.sh"
  cp "${REPO_ROOT}/tools/codex/restart_issue_flow.sh" "${repo_dir}/tools/codex/restart_issue_flow.sh"
  cp "${REPO_ROOT}/tools/codex/run_codex.sh" "${repo_dir}/tools/codex/run_codex.sh"
  cp "${REPO_ROOT}/tools/codex/run_issue_flow.sh" "${repo_dir}/tools/codex/run_issue_flow.sh"
  cp "${REPO_ROOT}/tools/issue/start_from_issue.sh" "${repo_dir}/tools/issue/start_from_issue.sh"
  chmod +x \
    "${repo_dir}/tools/codex/lib/checks_review_helpers.sh" \
    "${repo_dir}/tools/codex/lib/engine_defaults.sh" \
    "${repo_dir}/tools/codex/lib/consumer_config.sh" \
    "${repo_dir}/tools/codex/lib/codex_profiles.sh" \
    "${repo_dir}/tools/codex/lib/flow_state.sh" \
    "${repo_dir}/tools/codex/lib/history_helpers.sh" \
    "${repo_dir}/tools/codex/lib/issue_bootstrap.sh" \
    "${repo_dir}/tools/codex/lib/prompt_templates.sh" \
    "${repo_dir}/tools/codex/lib/publish_helpers.sh" \
    "${repo_dir}/tools/codex/continue_after_review.sh" \
    "${repo_dir}/tools/codex/make_pr_only.sh" \
    "${repo_dir}/tools/codex/restart_issue_flow.sh" \
    "${repo_dir}/tools/codex/run_codex.sh" \
    "${repo_dir}/tools/codex/run_issue_flow.sh" \
    "${repo_dir}/tools/issue/start_from_issue.sh"
}

clear_command_logs() {
  : > "${state_dir}/git.log"
  : > "${state_dir}/gh.log"
  : > "${state_dir}/codex.log"
}

reset_flow_counters() {
  rm -f \
    "${state_dir}/checks-count.txt" \
    "${state_dir}/fix-checks-count.txt" \
    "${state_dir}/fix-review-count.txt" \
    "${state_dir}/implementation-count.txt" \
    "${state_dir}/review-count.txt" \
    "${state_dir}/run-changed-args.txt"
}

write_fixture_files() {
  mkdir -p "${repo_dir}/docs"

  cat > "${repo_dir}/AGENTS.md" <<'EOF'
# Smoke Fixture
EOF

  cat > "${repo_dir}/docs/README.md" <<'EOF'
# Smoke Fixture Docs
EOF

  cat > "${repo_dir}/.gitignore" <<'EOF'
.work/
EOF

  cat > "${repo_dir}/smoke-target.txt" <<'EOF'
baseline
EOF

  cat > "${repo_dir}/.issue_forge/project.sh" <<'EOF'
CODEX_FLOW_BASE_REF='origin/main'
CODEX_FLOW_BASE_BRANCH='main'
CODEX_FLOW_BRANCH_PREFIX='issue/'
CODEX_FLOW_CHECKS_COMMAND='./tools/checks/run_changed.sh'
CODEX_FLOW_PROMPTS_DIR='tools/codex/prompts'
CODEX_FLOW_PR_DRAFT_DEFAULT=1
CODEX_FLOW_WRITE_PROFILE='write'
CODEX_FLOW_READ_PROFILE='read'
CODEX_FLOW_PROFILE_WRITE_SANDBOX='danger-full-access'
CODEX_FLOW_PROFILE_WRITE_REASONING='xhigh'
CODEX_FLOW_PROFILE_READ_SANDBOX='danger-full-access'
CODEX_FLOW_PROFILE_READ_REASONING='medium'
EOF

  cat > "${repo_dir}/tools/checks/run_changed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_file="${SMOKE_CHECKS_COUNT_FILE:?}"
args_file="${SMOKE_RUN_CHANGED_ARGS_FILE:-}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(< "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

if [[ -n "$args_file" ]]; then
  printf '%s\n' "$*" > "$args_file"
fi

if [[ "$count" -eq 1 ]]; then
  printf 'simulated check failure\n' >&2
  exit 1
fi

printf 'simulated checks pass on round %s\n' "$count"
EOF

  chmod +x "${repo_dir}/tools/checks/run_changed.sh"
}

write_stub_binaries() {
  cat > "${stub_dir}/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${state_dir}/git.log"
exec "${REAL_GIT}" "\$@"
EOF

  cat > "${stub_dir}/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${state_dir}/gh.log"

if [[ "\$#" -ge 3 && "\$1" == "issue" && "\$2" == "view" ]]; then
  if [[ " \$* " == *" --jq .title "* ]]; then
    printf '%s\n' "${ISSUE_TITLE}"
    exit 0
  fi

  cat <<OUT
# Issue #${ISSUE_NUMBER}

Title: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

## Body
**Kind**
- refactor

**Problem / Goal**
Smoke harness fixture issue body.
OUT
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "list" ]]; then
  printf '\n'
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "create" ]]; then
  printf 'https://example.test/pr/${ISSUE_NUMBER}\n'
  exit 0
fi

printf 'Unsupported gh invocation: %s\n' "\$*" >&2
exit 1
EOF

  cat > "${stub_dir}/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail

increment_counter() {
  local path="\$1"
  local current=0
  if [[ -f "\$path" ]]; then
    current="\$(< "\$path")"
  fi
  current=\$((current + 1))
  printf '%s\n' "\$current" > "\$path"
  printf '%s\n' "\$current"
}

prompt="\$(cat)"
printf 'args: %s\n' "\$*" >> "${state_dir}/codex.log"
printf '%s\n' '--- prompt ---' >> "${state_dir}/codex.log"
printf '%s\n' "\$prompt" >> "${state_dir}/codex.log"
printf '%s\n' '--- end prompt ---' >> "${state_dir}/codex.log"

if [[ "\$#" -lt 1 || "\$1" != "exec" ]]; then
  printf 'Unsupported codex invocation: %s\n' "\$*" >&2
  exit 1
fi

case "\$prompt" in
  *"Return exactly this format:"*)
    review_count="\$(increment_counter "${state_dir}/review-count.txt")"
    if [[ "\$review_count" -eq 1 ]]; then
      cat <<'OUT'
accept: no

blocker:

major:
- smoke harness forces one review fix round

minor:
OUT
      exit 0
    fi

    cat <<'OUT'
accept: yes

blocker:

major:

minor:
OUT
    exit 0
    ;;
  *".work/codex/checks.log"*)
    fix_checks_count="\$(increment_counter "${state_dir}/fix-checks-count.txt")"
    printf 'fix checks round %s\n' "\$fix_checks_count" >> smoke-target.txt
    printf 'applied checks fix round %s\n' "\$fix_checks_count"
    exit 0
    ;;
  *".work/codex/review.txt"*)
    fix_review_count="\$(increment_counter "${state_dir}/fix-review-count.txt")"
    printf 'fix review round %s\n' "\$fix_review_count" >> smoke-target.txt
    printf 'applied review fix round %s\n' "\$fix_review_count"
    exit 0
    ;;
  *"Make the required changes, then stop."*)
    implementation_count="\$(increment_counter "${state_dir}/implementation-count.txt")"
    printf 'implementation round %s\n' "\$implementation_count" >> smoke-target.txt
    printf 'applied implementation round %s\n' "\$implementation_count"
    exit 0
    ;;
  *)
    printf 'stub codex ok\n'
    exit 0
    ;;
esac
EOF

  chmod +x "${stub_dir}/git" "${stub_dir}/gh" "${stub_dir}/codex"
}

create_fixture_repo() {
  temp_root="$(mktemp -d)"
  repo_dir="${temp_root}/repo"
  remote_dir="${temp_root}/remote.git"
  stub_dir="${temp_root}/bin"
  state_dir="${temp_root}/state"
  prompt_dir="${temp_root}/prompts"

  mkdir -p "${repo_dir}" "${stub_dir}" "${state_dir}" "${prompt_dir}"

  "${REAL_GIT}" init --bare --initial-branch=main "${remote_dir}" >/dev/null
  "${REAL_GIT}" init --initial-branch=main "${repo_dir}" >/dev/null
  "${REAL_GIT}" -C "${repo_dir}" config user.name 'Smoke Harness'
  "${REAL_GIT}" -C "${repo_dir}" config user.email 'smoke@example.test'
  "${REAL_GIT}" -C "${repo_dir}" remote add origin "${remote_dir}"

  copy_flow_scripts
  write_fixture_files
  write_stub_binaries

  "${REAL_GIT}" -C "${repo_dir}" add .
  "${REAL_GIT}" -C "${repo_dir}" commit -m 'fixture: baseline' >/dev/null
  "${REAL_GIT}" -C "${repo_dir}" push -u origin main >/dev/null
  "${REAL_GIT}" -C "${repo_dir}" fetch origin main >/dev/null
}

run_start_from_issue_smoke() {
  log 'running start_from_issue.sh smoke'

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" ./tools/issue/start_from_issue.sh "${ISSUE_NUMBER}"
  )

  assert_equals "${ISSUE_NUMBER}" "$(< "${repo_dir}/.work/current_issue")" 'current issue file'
  assert_equals "issue/${ISSUE_NUMBER}-regression-harness-issue" "$(< "${repo_dir}/.work/current_branch")" 'current branch file'
  assert_equals "issue/${ISSUE_NUMBER}-regression-harness-issue" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'checked-out branch'
  assert_file_exists "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "# Issue #${ISSUE_NUMBER}"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "Title: ${ISSUE_TITLE}"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "URL: ${ISSUE_URL}"
}

run_make_pr_only_smoke() {
  local pr_url

  log 'running make_pr_only.sh smoke'
  clear_command_logs

  pr_url="$({
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" ./tools/codex/make_pr_only.sh "${ISSUE_NUMBER}"
  })"

  assert_equals "https://example.test/pr/${ISSUE_NUMBER}" "${pr_url}" 'make_pr_only output'
  assert_file_contains "${state_dir}/gh.log" "pr list --head issue/${ISSUE_NUMBER}-regression-harness-issue --base main --state open --json url --jq"
  assert_file_contains "${state_dir}/gh.log" "issue view ${ISSUE_NUMBER} --json title --jq .title"
  assert_file_contains "${state_dir}/gh.log" "pr create --draft --base main --head issue/${ISSUE_NUMBER}-regression-harness-issue"

  if grep -Fq 'push --set-upstream origin issue/' "${state_dir}/git.log"; then
    fail 'make_pr_only.sh should not push the issue branch'
  fi
}

run_run_codex_smoke() {
  log 'running run_codex.sh mode smoke'

  write_prompt="${prompt_dir}/write.prompt.md"
  read_prompt="${prompt_dir}/read.prompt.md"
  printf 'write prompt\n' > "${write_prompt}"
  printf 'read prompt\n' > "${read_prompt}"

  write_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/tools/codex/run_codex.sh" write "${write_prompt}"
  )"
  read_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/tools/codex/run_codex.sh" read "${read_prompt}"
  )"

  assert_equals 'stub codex ok' "${write_output}" 'write mode stdout'
  assert_equals 'stub codex ok' "${read_output}" 'read mode stdout'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=xhigh'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=medium'

  invalid_mode_log="${state_dir}/invalid-mode.log"
  if PATH="${stub_dir}:$PATH" "${repo_dir}/tools/codex/run_codex.sh" invalid "${write_prompt}" > "${invalid_mode_log}" 2>&1; then
    fail 'expected invalid run_codex.sh mode to fail'
  fi
  assert_file_contains "${invalid_mode_log}" 'Invalid mode: invalid'
}

run_codex_profile_smoke() {
  log 'running codex profile smoke'

  profile_report="$(
    (
      cd "${repo_dir}"
      bash -lc 'set -euo pipefail
source tools/codex/lib/engine_defaults.sh
source tools/codex/lib/consumer_config.sh
issue_forge_load_consumer_config "$(pwd)"
source tools/codex/lib/codex_profiles.sh
printf "write-profile=%s\n" "$(resolve_codex_profile_for_mode write)"
printf "write-sandbox=%s\n" "$(resolve_codex_profile_sandbox "$CODEX_FLOW_WRITE_PROFILE")"
printf "write-reasoning=%s\n" "$(resolve_codex_profile_reasoning "$CODEX_FLOW_WRITE_PROFILE")"
printf "read-profile=%s\n" "$(resolve_codex_profile_for_mode read)"
printf "read-sandbox=%s\n" "$(resolve_codex_profile_sandbox "$CODEX_FLOW_READ_PROFILE")"
printf "read-reasoning=%s\n" "$(resolve_codex_profile_reasoning "$CODEX_FLOW_READ_PROFILE")"
'
    )
  )"

  assert_equals $'write-profile=write\nwrite-sandbox=danger-full-access\nwrite-reasoning=xhigh\nread-profile=read\nread-sandbox=danger-full-access\nread-reasoning=medium' "${profile_report}" 'profile resolution output'

  invalid_profile_log="${state_dir}/invalid-profile.log"
  if (
    cd "${repo_dir}"
    bash -lc 'set -euo pipefail
source tools/codex/lib/engine_defaults.sh
source tools/codex/lib/consumer_config.sh
issue_forge_load_consumer_config "$(pwd)"
source tools/codex/lib/codex_profiles.sh
resolve_codex_profile_sandbox invalid-profile
'
  ) > "${invalid_profile_log}" 2>&1; then
    fail 'expected invalid execution profile to fail'
  fi
  assert_file_contains "${invalid_profile_log}" 'Invalid Codex execution profile: invalid-profile'

  missing_profile_log="${state_dir}/missing-profile.log"
  if (
    cd "${repo_dir}"
    bash -lc 'set -euo pipefail
readonly CODEX_FLOW_PROFILE_WRITE=write
readonly CODEX_FLOW_PROFILE_READ=read
readonly CODEX_FLOW_WRITE_PROFILE=
readonly CODEX_FLOW_READ_PROFILE=read
readonly CODEX_FLOW_PROFILE_WRITE_SANDBOX=danger-full-access
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=xhigh
readonly CODEX_FLOW_PROFILE_READ_SANDBOX=danger-full-access
readonly CODEX_FLOW_PROFILE_READ_REASONING=medium
source tools/codex/lib/codex_profiles.sh
resolve_codex_profile_for_mode write
'
  ) > "${missing_profile_log}" 2>&1; then
    fail 'expected missing mode profile mapping to fail'
  fi
  assert_file_contains "${missing_profile_log}" 'Missing Codex profile setting: mode write profile'

  incomplete_profile_log="${state_dir}/incomplete-profile.log"
  if (
    cd "${repo_dir}"
    bash -lc 'set -euo pipefail
readonly CODEX_FLOW_PROFILE_WRITE=write
readonly CODEX_FLOW_PROFILE_READ=read
readonly CODEX_FLOW_WRITE_PROFILE=write
readonly CODEX_FLOW_READ_PROFILE=read
readonly CODEX_FLOW_PROFILE_WRITE_SANDBOX=
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=xhigh
readonly CODEX_FLOW_PROFILE_READ_SANDBOX=danger-full-access
readonly CODEX_FLOW_PROFILE_READ_REASONING=medium
source tools/codex/lib/codex_profiles.sh
resolve_codex_profile_sandbox write
'
  ) > "${incomplete_profile_log}" 2>&1; then
    fail 'expected incomplete execution profile settings to fail'
  fi
  assert_file_contains "${incomplete_profile_log}" 'Missing Codex profile setting: profile write sandbox'
}

write_expected_issue_flow_prompts() {
  expected_prompt_dir="${prompt_dir}/expected"
  mkdir -p "${expected_prompt_dir}"

  cat > "${expected_prompt_dir}/implementation.prompt.md" <<EOF
Read AGENTS.md and docs/README.md first.
Then read .work/issues/${ISSUE_NUMBER}.md.

You are the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md
2. docs/README.md and source-of-truth docs
3. the GitHub issue body
4. this prompt

Rules:
- Stay within issue scope as long as it does not conflict with AGENTS.md or source-of-truth docs.
- If the issue conflicts with AGENTS.md or source-of-truth docs, follow the docs.
- Treat the issue as intent, but treat docs as normative.
- Reuse existing code first.
- Keep changes minimal.
- Do not add fallback or compatibility layers.
- Do not change docs just to match the issue unless the issue is explicitly a docs-update issue.
- If a conflict is material, implement the closest valid change that remains consistent with docs.

Make the required changes, then stop.
EOF

  cat > "${expected_prompt_dir}/fix-from-checks.prompt.md" <<EOF
Read AGENTS.md and docs/README.md first.
Then read .work/issues/${ISSUE_NUMBER}.md and .work/codex/checks.log.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md
2. docs/README.md and source-of-truth docs
3. the GitHub issue body
4. this prompt

Rules:
- Stay within issue scope as long as it does not conflict with AGENTS.md or source-of-truth docs.
- If the issue conflicts with AGENTS.md or source-of-truth docs, follow the docs.
- Treat the issue as intent, but treat docs as normative.
- Reuse existing code first.
- Keep changes minimal.
- Do not add fallback or compatibility layers.
- Fix only the concrete check failures shown in the log.
- Do not broaden scope while fixing checks.
EOF

  cat > "${expected_prompt_dir}/review.prompt.md" <<EOF
Read AGENTS.md and docs/README.md first.
Then read .work/issues/${ISSUE_NUMBER}.md, .work/codex/review.diff, and .work/codex/review.untracked.txt.

You are the review session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md
2. docs/README.md and source-of-truth docs
3. the GitHub issue body
4. this prompt

Review only the provided review material.

Rules:
- Do not edit code.
- Do not shell out to git to discover the diff.
- Do not rely on a remote branch or PR.
- Stay within issue scope unless the issue conflicts with AGENTS.md or source-of-truth docs.
- If issue and docs conflict, docs win.
- Reject changes that satisfy the issue but violate AGENTS.md or source-of-truth docs.
- Accept changes that remain consistent with docs even if the issue wording is slightly broader.
- Focus on correctness, scope, regressions, repository rules, and doc consistency.

Return exactly this format:
accept: yes/no

blocker:
- ...

major:
- ...

minor:
- ...
EOF

  cat > "${expected_prompt_dir}/fix-from-review.prompt.md" <<EOF
Read AGENTS.md and docs/README.md first.
Then read .work/issues/${ISSUE_NUMBER}.md and .work/codex/review.txt.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md
2. docs/README.md and source-of-truth docs
3. the GitHub issue body
4. this prompt

Rules:
- Stay within issue scope as long as it does not conflict with AGENTS.md or source-of-truth docs.
- If the issue conflicts with AGENTS.md or source-of-truth docs, follow the docs.
- Treat the issue as intent, but treat docs as normative.
- Reuse existing code first.
- Keep changes minimal.
- Do not add fallback or compatibility layers.
- Fix blocker and major review findings first.
- Fix only the concrete accepted review findings.
- Do not change implementation to satisfy the issue if doing so would violate docs.
EOF
}

run_issue_flow_smoke() {
  log 'running run_issue_flow.sh smoke'
  clear_command_logs

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      ./tools/codex/run_issue_flow.sh "${ISSUE_NUMBER}"
  )

  write_expected_issue_flow_prompts

  assert_file_exists "${repo_dir}/.work/codex/implementation.prompt.md"
  assert_file_exists "${repo_dir}/.work/codex/fix-from-checks.prompt.md"
  assert_file_exists "${repo_dir}/.work/codex/review.prompt.md"
  assert_file_exists "${repo_dir}/.work/codex/fix-from-review.prompt.md"
  assert_file_exists "${repo_dir}/.work/codex/checks.log"
  assert_file_exists "${repo_dir}/.work/codex/implementation.log"
  assert_file_exists "${repo_dir}/.work/codex/fix-from-checks.log"
  assert_file_exists "${repo_dir}/.work/codex/review.diff"
  assert_file_exists "${repo_dir}/.work/codex/review.untracked.txt"
  assert_file_exists "${repo_dir}/.work/codex/review.raw.txt"
  assert_file_exists "${repo_dir}/.work/codex/review.txt"
  assert_file_exists "${repo_dir}/.work/codex/fix-from-review.log"

  assert_file_exists "${repo_dir}/.work/codex/history/implementation.round-00.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-01.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-02.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-03.log"
  assert_file_exists "${repo_dir}/.work/codex/history/fix-from-checks.round-01.log"
  assert_file_exists "${repo_dir}/.work/codex/history/review-diff.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-diff.round-02.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-untracked.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-untracked.round-02.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-raw.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-raw.round-02.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/fix-from-review.round-01.log"
  assert_file_exists "${repo_dir}/.work/codex/history/review.round-02.txt"

  assert_files_equal "${expected_prompt_dir}/implementation.prompt.md" "${repo_dir}/.work/codex/implementation.prompt.md" 'implementation prompt'
  assert_files_equal "${expected_prompt_dir}/fix-from-checks.prompt.md" "${repo_dir}/.work/codex/fix-from-checks.prompt.md" 'fix-from-checks prompt'
  assert_files_equal "${expected_prompt_dir}/review.prompt.md" "${repo_dir}/.work/codex/review.prompt.md" 'review prompt'
  assert_files_equal "${expected_prompt_dir}/fix-from-review.prompt.md" "${repo_dir}/.work/codex/fix-from-review.prompt.md" 'fix-from-review prompt'

  assert_file_contains "${repo_dir}/.work/codex/history/review-raw.round-01.txt" 'accept: no'
  assert_file_contains "${repo_dir}/.work/codex/history/review-raw.round-02.txt" 'accept: yes'
  assert_file_contains "${repo_dir}/.work/codex/history/review.round-01.txt" 'accept: no'
  assert_file_contains "${repo_dir}/.work/codex/history/review.round-02.txt" 'accept: yes'
  assert_file_contains "${repo_dir}/.work/codex/history/checks.round-03.log" 'simulated checks pass on round 3'
  assert_file_contains "${repo_dir}/.work/codex/review.txt" 'accept: yes'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'implementation round 1'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'fix checks round 1'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'fix review round 1'
  assert_equals 'chore: address issue #40' "$("${REAL_GIT}" -C "${repo_dir}" log -1 --pretty=%s)" 'commit message'
  assert_equals 'origin/main' "$(< "${state_dir}/run-changed-args.txt")" 'run_changed base ref'
  assert_file_contains "${state_dir}/gh.log" 'pr create --draft --base main --head issue/40-regression-harness-issue'
}

run_restart_issue_flow_smoke() {
  local previous_head
  local current_head

  log 'running restart_issue_flow.sh smoke'
  printf 'restart dirty change\n' >> "${repo_dir}/smoke-target.txt"
  clear_command_logs
  reset_flow_counters
  previous_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      ./tools/codex/restart_issue_flow.sh --hard
  )

  current_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"
  if [[ "${current_head}" == "${previous_head}" ]]; then
    fail 'restart_issue_flow.sh should create a new commit when rerunning the flow'
  fi

  if grep -Fq 'restart dirty change' "${repo_dir}/smoke-target.txt"; then
    fail 'restart_issue_flow.sh should discard dirty tracked changes outside .work'
  fi

  assert_file_exists "${repo_dir}/.work/codex/review.txt"
  assert_file_contains "${state_dir}/git.log" 'reset --hard HEAD'
  assert_file_contains "${state_dir}/git.log" 'clean -fd -- . :(exclude).work'
  assert_file_contains "${state_dir}/gh.log" 'pr create --draft --base main --head issue/40-regression-harness-issue'
}

run_continue_after_review_smoke() {
  local previous_head
  local current_head
  local recent_commits

  log 'running continue_after_review.sh smoke'
  printf 'continue dirty change\n' >> "${repo_dir}/smoke-target.txt"
  clear_command_logs
  reset_flow_counters
  previous_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      ./tools/codex/continue_after_review.sh
  )

  current_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"
  if [[ "${current_head}" == "${previous_head}" ]]; then
    fail 'continue_after_review.sh should create new commits when continuing the flow'
  fi

  assert_file_exists "${repo_dir}/.work/codex/review.txt"
  assert_file_contains "${repo_dir}/smoke-target.txt" 'continue dirty change'
  assert_equals 'chore: address issue #40' "$("${REAL_GIT}" -C "${repo_dir}" log -1 --pretty=%s)" 'continue latest commit'

  recent_commits="$("${REAL_GIT}" -C "${repo_dir}" log --pretty=%s -5)"
  if [[ "${recent_commits}" != *'wip: address review feedback for issue #40'* ]]; then
    fail 'continue_after_review.sh should create the intermediate review-feedback commit'
  fi

  assert_file_contains "${state_dir}/gh.log" 'pr create --draft --base main --head issue/40-regression-harness-issue'
}

cleanup() {
  if [[ -n "${temp_root:-}" && -d "${temp_root}" ]]; then
    rm -rf "${temp_root}"
  fi
}

main() {
  trap cleanup EXIT
  create_fixture_repo
  run_start_from_issue_smoke
  run_make_pr_only_smoke
  run_run_codex_smoke
  run_codex_profile_smoke
  run_issue_flow_smoke
  run_restart_issue_flow_smoke
  run_continue_after_review_smoke
  log 'all smoke scenarios passed'
}

main "$@"
