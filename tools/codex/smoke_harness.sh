#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
REAL_GIT="$(command -v git)"
readonly REAL_GIT
readonly ISSUE_NUMBER=40
readonly ISSUE_TITLE='Regression Harness Issue'
readonly ISSUE_URL='https://example.test/issues/40'
readonly QUEUE_ISSUE_NUMBER=41
readonly QUEUE_ISSUE_TITLE='Queue Follow-up Issue'
readonly QUEUE_ISSUE_URL='https://example.test/issues/41'
readonly UTF8_PR_BODY_TITLE='Regression Harness Issue 🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀'
readonly UTF8_CHECKS_LINE='checks passed with emoji 🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪'
readonly CODEX_RUNTIME_SESSION_LOG_LINE='2026-05-13T09:31:45.338857Z ERROR codex_core::session: failed to record rollout items: thread 019e20ac-2a2b-70f0-bf23-77ae5017250a not found'
readonly FIXTURE_ENGINE_PATH='vendor/issue_forge'
readonly FIXTURE_ENGINE_CODEX_PATH="${FIXTURE_ENGINE_PATH}/tools/codex"
readonly FIXTURE_ENGINE_ISSUE_PATH="${FIXTURE_ENGINE_PATH}/tools/issue"

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

assert_file_executable() {
  local path="$1"

  if [[ ! -x "$path" ]]; then
    fail "expected file to be executable: $path"
  fi
}

assert_file_ends_with_newline() {
  local path="$1"

  assert_file_exists "$path"

  if [[ -s "$path" && -n "$(tail -c 1 "$path")" ]]; then
    fail "expected file to end with newline: $path"
  fi
}

assert_path_not_exists() {
  local path="$1"

  if [[ -e "$path" ]]; then
    fail "expected path to not exist: $path"
  fi
}

assert_file_contains() {
  local path="$1"
  local pattern="$2"

  if ! grep -Fq -- "$pattern" "$path"; then
    printf '[smoke] expected %s to contain: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local path="$1"
  local pattern="$2"

  if [[ ! -f "$path" ]]; then
    fail "expected file to exist: $path"
  fi

  if grep -Fq -- "$pattern" "$path"; then
    printf '[smoke] expected %s to not contain: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

queue_tree_snapshot() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  {
    find "$root" -type d -printf 'directory %P\n'
    find "$root" -type f -printf 'file %P ' -exec cksum {} \;
  } | LC_ALL=C sort
}

assert_file_order() {
  local path="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local first_line
  local second_line

  first_line="$(grep -Fn -- "$first_pattern" "$path" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -Fn -- "$second_pattern" "$path" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    printf '[smoke] expected %s to contain %s before %s\n' "$path" "$first_pattern" "$second_pattern" >&2
    exit 1
  fi
}

assert_fixed_line_count() {
  local path="$1"
  local pattern="$2"
  local expected_count="$3"
  local message="$4"
  local actual_count

  actual_count="$(grep -Fxc -- "$pattern" "$path" || true)"
  assert_equals "${expected_count}" "${actual_count}" "${message}"
}

assert_commit_excludes_internal_paths() {
  local commit_ref="$1"
  local changed_paths

  changed_paths="$("${REAL_GIT}" -C "${repo_dir}" show --pretty= --name-only "$commit_ref")"
  if printf '%s\n' "$changed_paths" | grep -Eq '^\.work(/|$)'; then
    printf '[smoke] expected commit %s to exclude .work paths\n' "$commit_ref" >&2
    printf '%s\n' "$changed_paths" >&2
    exit 1
  fi

  if printf '%s\n' "$changed_paths" | grep -Eq '^vendor/issue_forge(/|$)'; then
    printf '[smoke] expected commit %s to exclude vendor/issue_forge paths\n' "$commit_ref" >&2
    printf '%s\n' "$changed_paths" >&2
    exit 1
  fi
}

assert_commit_includes_path() {
  local commit_ref="$1"
  local expected_path="$2"
  local changed_paths

  changed_paths="$("${REAL_GIT}" -C "${repo_dir}" show --pretty= --name-only "$commit_ref")"
  if ! printf '%s\n' "$changed_paths" | grep -Fxq "$expected_path"; then
    printf '[smoke] expected commit %s to include %s\n' "$commit_ref" "$expected_path" >&2
    printf '%s\n' "$changed_paths" >&2
    exit 1
  fi
}

assert_diff_file_excludes_path_regex() {
  local path="$1"
  local path_regex="$2"
  local label="$3"

  if grep -Eq "^(diff --git a/${path_regex}(/| )|--- a/${path_regex}(/|$)|\\+\\+\\+ b/${path_regex}(/|$))" "$path"; then
    printf '[smoke] expected %s to exclude diff entries for %s\n' "$path" "$label" >&2
    exit 1
  fi
}

assert_path_list_excludes_path_regex() {
  local path="$1"
  local path_regex="$2"
  local label="$3"

  if grep -Eq "^${path_regex}(/|$)" "$path"; then
    printf '[smoke] expected %s to exclude path entries for %s\n' "$path" "$label" >&2
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

assert_init_gitignore_configured() {
  local path="$1"

  assert_file_exists "${path}"
  assert_fixed_line_count "${path}" '.work' '1' "${path} .work entry count"
  assert_fixed_line_count "${path}" '.work/' '1' "${path} .work/ entry count"
  assert_fixed_line_count "${path}" 'vendor/issue_forge' '1' "${path} vendor/issue_forge entry count"
  assert_fixed_line_count "${path}" 'vendor/issue_forge/' '1' "${path} vendor/issue_forge/ entry count"
}

assert_default_consumer_project_file() {
  local path="$1"
  local expected_contents

  expected_contents="$(mktemp)"
  cat > "${expected_contents}" <<'EOF'
# issue_forge consumer config.
# Defaults are supplied by vendor/issue_forge.
EOF
  assert_files_equal "${expected_contents}" "${path}" 'default consumer project config'
  rm -f "${expected_contents}"
}

write_expected_consumer_checks_starter() {
  local path="$1"

  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

readonly WORK_EXCLUDE_PATHSPEC=':(exclude).work'
readonly VENDOR_EXCLUDE_PATHSPEC=':(exclude)vendor/issue_forge'

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required check command: $1"
}

collect_changed_files() {
  local base_ref="$1"

  {
    git diff --name-only "$base_ref" -- . "$WORK_EXCLUDE_PATHSPEC" "$VENDOR_EXCLUDE_PATHSPEC"
    git diff --name-only --cached -- . "$WORK_EXCLUDE_PATHSPEC" "$VENDOR_EXCLUDE_PATHSPEC"
    git diff --name-only -- . "$WORK_EXCLUDE_PATHSPEC" "$VENDOR_EXCLUDE_PATHSPEC"
    git ls-files --others --exclude-standard -- . "$WORK_EXCLUDE_PATHSPEC" "$VENDOR_EXCLUDE_PATHSPEC"
  } | awk 'NF && !seen[$0]++'
}

run_shellcheck_if_needed() {
  local -a shell_targets=("$@")

  if [[ "${#shell_targets[@]}" -eq 0 ]]; then
    printf 'shellcheck: skipped (no shell targets changed)\n'
    return 0
  fi

  require_command shellcheck
  printf 'shellcheck: %s target(s)\n' "${#shell_targets[@]}"
  shellcheck -x "${shell_targets[@]}"
}

run_pytest_if_needed() {
  local should_run="$1"

  if [[ "$should_run" -ne 1 ]]; then
    printf 'pytest: skipped (no Python-related changes)\n'
    return 0
  fi

  require_command pytest
  printf 'pytest: pytest -q\n'
  pytest -q
}

main() {
  local base_ref
  local path
  local run_pytest=0
  local -a changed_files=()
  local -a shell_targets=()

  if [[ "$#" -ne 1 ]]; then
    fail "Usage: $0 <base-ref>"
  fi

  base_ref="$1"

  git rev-parse --verify "$base_ref" >/dev/null 2>&1 || fail "Missing base ref for checks: $base_ref"

  mapfile -t changed_files < <(collect_changed_files "$base_ref")

  if [[ "${#changed_files[@]}" -eq 0 ]]; then
    printf 'No changes detected relative to %s\n' "$base_ref"
    return 0
  fi

  printf 'Changed files relative to %s:\n' "$base_ref"
  printf ' - %s\n' "${changed_files[@]}"

  for path in "${changed_files[@]}"; do
    case "$path" in
      *.sh)
        [[ -f "$path" ]] && shell_targets+=("$path")
        ;;
    esac

    case "$path" in
      *.py|conftest.py|tests/*|pytest.ini|pyproject.toml|setup.cfg|tox.ini|requirements*.txt|Pipfile|Pipfile.lock|poetry.lock|uv.lock)
        run_pytest=1
        ;;
    esac
  done

  run_shellcheck_if_needed "${shell_targets[@]}"
  run_pytest_if_needed "$run_pytest"
}

main "$@"
EOF
}

write_expected_consumer_run_wrapper() {
  local path="$1"

  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s <issue-number>\n' "$0"
}

log() {
  printf '[run_issue] %s\n' "$1"
}

main() {
  local issue
  local script_dir
  local repo_root
  local config_script
  local flow_state_script
  local start_script
  local flow_script

  if [[ "$#" -ne 1 ]]; then
    usage >&2
    exit 1
  fi

  issue="$1"

  command -v git >/dev/null 2>&1 || fail 'Missing required command: git'

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "Failed to resolve repo root from ${script_dir}"

  config_script="${repo_root}/vendor/issue_forge/tools/codex/lib/config.sh"
  flow_state_script="${repo_root}/vendor/issue_forge/tools/codex/lib/flow_state.sh"
  start_script="${repo_root}/vendor/issue_forge/tools/issue/start_from_issue.sh"
  flow_script="${repo_root}/vendor/issue_forge/tools/codex/run_issue_flow.sh"

  [[ -f "${repo_root}/.issue_forge/project.sh" ]] \
    || fail "Missing consumer config: ${repo_root}/.issue_forge/project.sh"
  [[ -f "${config_script}" ]] \
    || fail "Missing issue_forge runtime: ${config_script}"
  [[ -f "${flow_state_script}" ]] \
    || fail "Missing issue_forge runtime: ${flow_state_script}"
  [[ -x "${start_script}" ]] \
    || fail "Missing executable bootstrap entrypoint: ${start_script}"
  [[ -x "${flow_script}" ]] \
    || fail "Missing executable flow entrypoint: ${flow_script}"

  cd "${repo_root}" || exit 1

  # shellcheck source=/dev/null
  source "${config_script}"
  # shellcheck source=/dev/null
  source "${flow_state_script}"

  require_numeric_issue_number "${issue}"
  enter_repo_root
  ensure_clean_worktree 'Working tree must be clean before running tools/run_issue.sh.'

  log "switching to base branch ${CODEX_FLOW_BASE_BRANCH}"
  git switch "${CODEX_FLOW_BASE_BRANCH}"

  log "fetching origin/${CODEX_FLOW_BASE_BRANCH}"
  git fetch origin "${CODEX_FLOW_BASE_BRANCH}"

  log "pulling origin/${CODEX_FLOW_BASE_BRANCH}"
  git pull --ff-only origin "${CODEX_FLOW_BASE_BRANCH}"

  log "bootstrapping issue ${issue}"
  "${start_script}" "${issue}"

  log "running issue flow for issue ${issue}"
  "${flow_script}" "${issue}"
}

main "$@"
EOF
}

write_expected_consumer_shell_snippet() {
  local path="$1"

  cat > "${path}" <<'EOF'
# shellcheck shell=bash
run() {
  local root

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'Not inside a git worktree.\n' >&2
    return 1
  }

  [[ -x "${root}/tools/run_issue.sh" ]] || {
    printf 'Missing executable wrapper: %s/tools/run_issue.sh\n' "$root" >&2
    return 1
  }

  "${root}/tools/run_issue.sh" "$@"
}
EOF
}

assert_source_checks_command_executable() {
  if [[ ! -x "${REPO_ROOT}/tools/checks/run_changed.sh" ]]; then
    fail 'tools/checks/run_changed.sh must be executable'
  fi
}

assert_vendor_engine_symlink_present() {
  if [[ ! -L "${repo_dir}/${FIXTURE_ENGINE_PATH}" ]]; then
    fail "expected vendor engine symlink to exist: ${repo_dir}/${FIXTURE_ENGINE_PATH}"
  fi
}

assert_review_material_excludes_engine_path() {
  assert_diff_file_excludes_path_regex "${repo_dir}/.work/codex/review.diff" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_path_list_excludes_path_regex "${repo_dir}/.work/codex/review.untracked.txt" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_diff_file_excludes_path_regex "${repo_dir}/.work/codex/history/review-diff.round-01.txt" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_diff_file_excludes_path_regex "${repo_dir}/.work/codex/history/review-diff.round-02.txt" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_path_list_excludes_path_regex "${repo_dir}/.work/codex/history/review-untracked.round-01.txt" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_path_list_excludes_path_regex "${repo_dir}/.work/codex/history/review-untracked.round-02.txt" 'vendor/issue_forge' 'vendor/issue_forge'
}

assert_staging_uses_concrete_pathspecs() {
  local command_log="$1"

  assert_file_contains "${command_log}" 'diff --name-only -z -- . :(exclude).work :(exclude)vendor/issue_forge'
  assert_file_contains "${command_log}" 'diff --name-only -z --cached -- . :(exclude).work :(exclude)vendor/issue_forge'
  assert_file_contains "${command_log}" 'ls-files --others --exclude-standard -z -- . :(exclude).work :(exclude)vendor/issue_forge'
  assert_file_contains "${command_log}" 'add -A --pathspec-from-file='
  assert_file_contains "${command_log}" '--pathspec-file-nul'
  assert_file_not_contains "${command_log}" 'add -A -- . :(exclude).work :(exclude)vendor/issue_forge'
}

assert_pr_body_common_sections() {
  local path="$1"

  assert_file_contains "${path}" "Closes #${ISSUE_NUMBER}"
  assert_file_contains "${path}" '## Summary'
  assert_file_contains "${path}" "${ISSUE_TITLE}"
  assert_file_contains "${path}" '## Changed files'
  assert_file_contains "${path}" '## Checks'
  assert_file_contains "${path}" '## Review'
  assert_file_not_contains "${path}" '.work/current_issue'
  assert_file_not_contains "${path}" 'vendor/issue_forge'
}

write_review_output_fixture() {
  local path="$1"
  local accept_value="$2"
  local blocker_items="$3"
  local major_items="$4"
  local minor_items="$5"

  {
    printf 'accept: %s\n\n' "$accept_value"
    printf 'blocker:\n'
    if [[ -n "$blocker_items" ]]; then
      printf '%s\n' "$blocker_items"
    fi
    printf '\nmajor:\n'
    if [[ -n "$major_items" ]]; then
      printf '%s\n' "$major_items"
    fi
    printf '\nminor:\n'
    if [[ -n "$minor_items" ]]; then
      printf '%s\n' "$minor_items"
    fi
  } > "$path"
}

run_review_validation_command() {
  local review_output_path="$1"
  local review_raw_path="$2"
  local expected_accept_state="$3"

  (
    set -euo pipefail
    cd "${repo_dir}"
    # shellcheck disable=SC1091
    source vendor/issue_forge/tools/codex/lib/config.sh
    # shellcheck disable=SC1091
    source vendor/issue_forge/tools/codex/lib/checks_review_helpers.sh
    # shellcheck disable=SC2317
    log_fail_with_path() {
      printf '[flow] %s\n' "$1" >&2
      printf '[flow] see log: %s\n' "$2" >&2
    }
    # shellcheck disable=SC2034
    review_output="${review_output_path}"
    # shellcheck disable=SC2034
    review_raw_output="${review_raw_path}"

    ensure_valid_review_output

    case "${expected_accept_state}" in
      yes)
        review_accepted
        ;;
      no)
        if review_accepted; then
          printf 'Expected review_accepted to return false for %s\n' "${review_output}" >&2
          exit 1
        fi
        ;;
      *)
        printf 'Invalid expected accept state: %s\n' "${expected_accept_state}" >&2
        exit 1
        ;;
    esac
  )
}

run_review_extraction_validation_command() {
  local review_raw_path="$1"
  local review_output_path="$2"
  local expected_accept_state="$3"

  (
    set -euo pipefail
    cd "${repo_dir}"
    # shellcheck disable=SC1091
    source vendor/issue_forge/tools/codex/lib/config.sh
    # shellcheck disable=SC1091
    source vendor/issue_forge/tools/codex/lib/checks_review_helpers.sh
    # shellcheck disable=SC2317
    log_fail_with_path() {
      printf '[flow] %s\n' "$1" >&2
      printf '[flow] see log: %s\n' "$2" >&2
    }
    # shellcheck disable=SC2034
    review_output="${review_output_path}"
    # shellcheck disable=SC2034
    review_raw_output="${review_raw_path}"

    extract_structured_review_output_file "$review_raw_output" "$review_output"
    ensure_valid_review_output

    case "${expected_accept_state}" in
      yes)
        review_accepted
        ;;
      no)
        if review_accepted; then
          printf 'Expected review_accepted to return false for %s\n' "${review_output}" >&2
          exit 1
        fi
        ;;
      *)
        printf 'Invalid expected accept state: %s\n' "${expected_accept_state}" >&2
        exit 1
        ;;
    esac
  )
}

copy_flow_scripts() {
  mkdir -p "${repo_dir}/docs" "${repo_dir}/.issue_forge/checks" "${repo_dir}/vendor"

  cp "${REPO_ROOT}/tools/checks/run_changed.sh" "${repo_dir}/.issue_forge/checks/run_changed.sh"
  chmod +x "${repo_dir}/.issue_forge/checks/run_changed.sh"

  cat > "${repo_dir}/AGENTS.md" <<'EOF'
# Fixture AGENTS

Use the consumer repo docs first.
EOF

  cat > "${repo_dir}/README.md" <<'EOF'
# Smoke Fixture Consumer

This fixture exercises issue_forge through `vendor/issue_forge`.
EOF

  cat > "${repo_dir}/docs/README.md" <<'EOF'
# Fixture Docs

Read `AGENTS.md` first.
EOF

  cat > "${repo_dir}/.issue_forge/project.sh" <<'EOF'
# Intentionally empty.
# External consumers rely on issue_forge defaults for base ref, prompts, and checks.
EOF

  cat > "${repo_dir}/.gitignore" <<'EOF'
# Intentionally empty for smoke coverage.
EOF
}

create_fixture_vendor_symlink() {
  ln -s "${REPO_ROOT}" "${repo_dir}/${FIXTURE_ENGINE_PATH}"
  assert_vendor_engine_symlink_present

  if "${REAL_GIT}" -C "${repo_dir}" ls-files --error-unmatch "${FIXTURE_ENGINE_PATH}" >/dev/null 2>&1; then
    fail 'vendor/issue_forge should remain untracked in the fixture consumer repo'
  fi
}

configure_fixture_gitignore_for_managed_paths() {
  cat > "${repo_dir}/.gitignore" <<'EOF'
.work
.work/
vendor/issue_forge
vendor/issue_forge/
EOF
}

create_init_fixture_repo() {
  local fixture_repo="$1"

  mkdir -p "${fixture_repo}/vendor"
  "${REAL_GIT}" init --initial-branch=main "${fixture_repo}" >/dev/null
  "${REAL_GIT}" -C "${fixture_repo}" config user.name 'Smoke Harness'
  "${REAL_GIT}" -C "${fixture_repo}" config user.email 'smoke@example.test'
  ln -s "${REPO_ROOT}" "${fixture_repo}/${FIXTURE_ENGINE_PATH}"

  if [[ ! -L "${fixture_repo}/${FIXTURE_ENGINE_PATH}" ]]; then
    fail "expected vendor engine symlink to exist: ${fixture_repo}/${FIXTURE_ENGINE_PATH}"
  fi
}

clear_command_logs() {
  : > "${state_dir}/git.log"
  : > "${state_dir}/gh.log"
  : > "${state_dir}/codex.log"
}

reset_flow_counters() {
  rm -f \
    "${state_dir}/checks-count.txt" \
    "${state_dir}/batch-review-count.txt" \
    "${state_dir}/fix-checks-count.txt" \
    "${state_dir}/fix-batch-review-count.txt" \
    "${state_dir}/fix-review-count.txt" \
    "${state_dir}/implementation-count.txt" \
    "${state_dir}/review-count.txt" \
    "${state_dir}/run-changed-args.txt"
}

queue_side_effect_snapshot() {
  local implementation=0
  [[ ! -f "${state_dir}/implementation-count.txt" ]] || implementation="$(< "${state_dir}/implementation-count.txt")"
  printf 'issue_fetch\t%s\n' "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  printf 'implementation\t%s\n' "$implementation"
  printf 'branch_switch\t%s\n' "$(awk '$1 == "switch" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  printf 'push\t%s\n' "$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  printf 'pr_mutation\t%s\n' "$(awk '$1 == "pr" && ($2 == "create" || $2 == "edit") { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  printf 'merge\t%s\n' "$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
}

write_completion_cleanup_fixture() {
  local path="$1" run="$2" token="$3" generation="$4" lease_required="$5" batch="$6" phase="$7"
  printf 'schema_version\t3\nrun_id\t%s\nowner_token\t%s\nlease_generation\t%s\nlease_required\t%s\nbatch_pointer\t%s\nphase\t%s\nupdated_at\t2026-08-07T00:00:00Z\n' \
    "$run" "$token" "$generation" "$lease_required" "$batch" "$phase" > "$path"
}

write_queue_pointer_fixture() {
  local path="$1" run="$2" token="$3" generation="$4"
  printf 'schema_version\t3\nrun_id\t%s\nowner_token\t%s\nlease_generation\t%s\nupdated_at\t2026-08-07T00:00:00Z\n' \
    "$run" "$token" "$generation" > "$path"
}

write_fixture_files() {
  cat > "${repo_dir}/smoke-target.txt" <<'EOF'
baseline
EOF

  cat > "${repo_dir}/vendor/tracked.txt" <<'EOF'
tracked baseline
EOF

  printf 'binary baseline\0content\n' > "${repo_dir}/binary-target.dat"
}

set_work_ignore_fixture_state() {
  local desired_state="$1"
  local exclude_file="${repo_dir}/.git/info/exclude"
  local filtered_exclude

  filtered_exclude="$(mktemp)"
  if [[ -f "${exclude_file}" ]]; then
    grep -vx '.work/' "${exclude_file}" > "${filtered_exclude}" || true
  fi

  if [[ "${desired_state}" == 'enabled' ]]; then
    printf '.work/\n' >> "${filtered_exclude}"
  fi

  mv "${filtered_exclude}" "${exclude_file}"
}

advance_origin_main_after_bootstrap() {
  local upstream_repo_dir="${temp_root}/upstream-main"

  log 'advancing origin/main after bootstrap'
  "${REAL_GIT}" clone --branch main "${remote_dir}" "${upstream_repo_dir}" >/dev/null
  "${REAL_GIT}" -C "${upstream_repo_dir}" config user.name 'Smoke Harness'
  "${REAL_GIT}" -C "${upstream_repo_dir}" config user.email 'smoke@example.test'
  printf 'upstream only after bootstrap\n' > "${upstream_repo_dir}/upstream-only.txt"
  "${REAL_GIT}" -C "${upstream_repo_dir}" add upstream-only.txt
  "${REAL_GIT}" -C "${upstream_repo_dir}" commit -m 'fixture: advance main after bootstrap' >/dev/null
  "${REAL_GIT}" -C "${upstream_repo_dir}" push origin main >/dev/null
  "${REAL_GIT}" -C "${repo_dir}" fetch origin main >/dev/null

  advanced_origin_main="$("${REAL_GIT}" -C "${repo_dir}" rev-parse origin/main)"
  if [[ "${advanced_origin_main}" == "${bootstrap_base_commit}" ]]; then
    fail 'origin/main should move after bootstrap'
  fi
}

assert_fixed_base_commit_usage() {
  local scenario_name="$1"
  local recorded_base_commit

  recorded_base_commit="$(< "${state_dir}/run-changed-args.txt")"
  assert_equals "${bootstrap_base_commit}" "${recorded_base_commit}" "${scenario_name} checks base commit"
  assert_equals "${bootstrap_base_commit}" "$(< "${repo_dir}/.work/base_commit")" "${scenario_name} saved base commit"

  if [[ "${recorded_base_commit}" == "${advanced_origin_main}" ]]; then
    fail "${scenario_name} should not use moving origin/main"
  fi

  assert_file_not_contains "${repo_dir}/.work/codex/review.diff" 'upstream-only.txt'
  assert_file_not_contains "${repo_dir}/.work/codex/history/review-diff.round-01.txt" 'upstream-only.txt'
  assert_file_not_contains "${repo_dir}/.work/codex/history/review-diff.round-02.txt" 'upstream-only.txt'
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

if [[ "\${SMOKE_QUEUE_EXTERNAL_PAUSE_DIR:-}" != '' && "\$#" -ge 3 && "\$1" == issue && "\$2" == view && \
      "\$3" == "\${SMOKE_QUEUE_EXTERNAL_PAUSE_ISSUE:-}" ]]; then
  mkdir -p "\$SMOKE_QUEUE_EXTERNAL_PAUSE_DIR"
  pause_label="\${SMOKE_QUEUE_EXTERNAL_PAUSE_LABEL:-external}"
  if [[ "\${SMOKE_QUEUE_REMOVE_WORK_QUEUE:-0}" == 1 ]]; then
    rm -rf -- "\$PWD/.work/queue"
  fi
  printf '%s\t%s\n' "\$\$" "\$(awk '{print \$22}' "/proc/\$\$/stat")" > "\$SMOKE_QUEUE_EXTERNAL_PAUSE_DIR/child.\$pause_label"
  : > "\$SMOKE_QUEUE_EXTERNAL_PAUSE_DIR/paused.\$pause_label"
  while [[ ! -f "\$SMOKE_QUEUE_EXTERNAL_PAUSE_DIR/release.\$pause_label" ]]; do sleep 0.01; done
fi

copy_flag_value_to_file() {
  local flag="\$1"
  local destination="\$2"
  shift 2
  local previous=''
  local value

  for value in "\$@"; do
    if [[ "\$previous" == "\$flag" ]]; then
      cp "\$value" "\$destination"
      return 0
    fi
    previous="\$value"
  done

  printf 'Missing required gh flag: %s\n' "\$flag" >&2
  exit 1
}

write_flag_value_to_file() {
  local flag="\$1"
  local destination="\$2"
  shift 2
  local previous=''
  local value

  for value in "\$@"; do
    if [[ "\$previous" == "\$flag" ]]; then
      printf '%s\n' "\$value" > "\$destination"
      return 0
    fi
    previous="\$value"
  done

  printf 'Missing required gh flag: %s\n' "\$flag" >&2
  exit 1
}

flag_value() {
  local flag="\$1"
  shift
  local previous=''
  local value

  for value in "\$@"; do
    if [[ "\$previous" == "\$flag" ]]; then
      printf '%s\n' "\$value"
      return 0
    fi
    previous="\$value"
  done

  return 1
}

if [[ "\$#" -ge 3 && "\$1" == "issue" && "\$2" == "view" ]]; then
  issue_number="\$3"
  case "\$issue_number" in
    ${ISSUE_NUMBER})
      issue_title='${ISSUE_TITLE}'
      issue_url='${ISSUE_URL}'
      ;;
    ${QUEUE_ISSUE_NUMBER})
      issue_title='${QUEUE_ISSUE_TITLE}'
      issue_url='${QUEUE_ISSUE_URL}'
      ;;
    42|43|44|45|46|47|48|49|50|51|52|53|54|55|56|57|58|59|60|61|62|63|64|65|66|67|68|69|70|71|72|73|74|75|76|77|78|79|80|81|82|83|84)
      issue_title="Control Plane Issue \${issue_number}"
      issue_url="https://example.test/issues/\${issue_number}"
      ;;
    *)
      printf 'Unsupported issue number: %s\n' "\$issue_number" >&2
      exit 1
      ;;
  esac

  if [[ " \$* " == *" --jq .title "* ]]; then
    printf '%s\n' "\$issue_title"
    exit 0
  fi

  cat <<OUT
# Issue #\${issue_number}

Title: \${issue_title}
URL: \${issue_url}

## Body
**Kind**
- refactor

**Problem / Goal**
Smoke harness fixture issue body for #\${issue_number}.
OUT
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "auth" && "\$2" == "status" ]]; then
  printf 'github.com\n'
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "list" && " \$* " == *" --state all "* ]]; then
  if [[ ! -f "${state_dir}/batch-pr-url.txt" ]]; then exit 0; fi
  read -r batch_pr_head_branch < "${state_dir}/batch-pr-head-branch.txt"
  read -r batch_pr_head_sha < "${state_dir}/batch-pr-head-sha.txt"
  requested_head="\$(flag_value '--head' "\$@" || true)"
  if [[ "\$requested_head" != "\$batch_pr_head_branch" ]]; then exit 0; fi
  if [[ -f "${state_dir}/batch-pr-merge.txt" ]]; then
    printf '400\\thttps://example.test/pr/400\\tMERGED\\t2026-08-08T00:00:00Z\\t%s\\tmain\\t%s\\n' "\$batch_pr_head_branch" "\$batch_pr_head_sha"
  else
    printf '400\\thttps://example.test/pr/400\\tOPEN\\tnone\\t%s\\tmain\\t%s\\n' "\$batch_pr_head_branch" "\$batch_pr_head_sha"
  fi
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "list" ]]; then
  head_value="\$(flag_value '--head' "\$@" || true)"
  if [[ "\$head_value" == batch/* ]]; then
    printf '%s\n' "\$head_value" > "${state_dir}/batch-pr-head-branch.txt"
    git rev-parse "\$head_value" > "${state_dir}/batch-pr-head-sha.txt"
    rm -f "${state_dir}/batch-pr-merge.txt"
    if [[ -f "${state_dir}/batch-pr-url.txt" ]]; then
      printf '400\t'
      cat "${state_dir}/batch-pr-url.txt"
      exit 0
    fi

    printf '\n'
    exit 0
  fi

  if [[ -f "${state_dir}/pr-url.txt" ]]; then
    cat "${state_dir}/pr-url.txt"
    exit 0
  fi

  printf '\n'
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "create" ]]; then
  head_value="\$(flag_value '--head' "\$@" || true)"
  if [[ "\$head_value" == batch/* ]]; then
    copy_flag_value_to_file '--body-file' "${state_dir}/batch-pr-create-body.txt" "\$@"
    write_flag_value_to_file '--title' "${state_dir}/batch-pr-create-title.txt" "\$@"
    printf 'https://example.test/pr/400\n' > "${state_dir}/batch-pr-url.txt"
    cat "${state_dir}/batch-pr-url.txt"
    exit 0
  fi

  copy_flag_value_to_file '--body-file' "${state_dir}/pr-create-body.txt" "\$@"
  write_flag_value_to_file '--title' "${state_dir}/pr-create-title.txt" "\$@"
  printf 'https://example.test/pr/${ISSUE_NUMBER}\n' > "${state_dir}/pr-url.txt"
  cat "${state_dir}/pr-url.txt"
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "edit" ]]; then
  if [[ "\$3" == "https://example.test/pr/400" ]]; then
    copy_flag_value_to_file '--body-file' "${state_dir}/batch-pr-edit-body.txt" "\$@"
    write_flag_value_to_file '--title' "${state_dir}/batch-pr-edit-title.txt" "\$@"
    exit 0
  fi

  copy_flag_value_to_file '--body-file' "${state_dir}/pr-edit-body.txt" "\$@"
  write_flag_value_to_file '--title' "${state_dir}/pr-edit-title.txt" "\$@"
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "view" ]]; then
  if [[ "\$3" == "https://example.test/pr/400" && " \$* " == *" --json number "* ]]; then
    printf '400\n'
    exit 0
  fi

  if [[ "\$3" == "400" && " \$* " == *" --json state,mergedAt,headRefName,baseRefName,headRefOid "* ]]; then
    read -r batch_pr_head_branch < "${state_dir}/batch-pr-head-branch.txt"
    read -r batch_pr_head_sha < "${state_dir}/batch-pr-head-sha.txt"
    if [[ -f "${state_dir}/batch-pr-merge.txt" ]]; then
      printf 'MERGED\\t2026-08-08T00:00:00Z\\t%s\\tmain\\t%s\\n' "\$batch_pr_head_branch" "\$batch_pr_head_sha"
    else
      printf 'OPEN\\t\\t%s\\tmain\\t%s\\n' "\$batch_pr_head_branch" "\$batch_pr_head_sha"
    fi
    exit 0
  fi

  if [[ "\$3" == "400" && " \$* " == *" --json state,mergedAt "* ]]; then
    printf 'OPEN\t\n'
    exit 0
  fi

  printf 'Unsupported gh pr view invocation: %s\n' "\$*" >&2
  exit 1
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "merge" ]]; then
  printf 'merged\n' > "${state_dir}/batch-pr-merge.txt"
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
  *"strict batch review session"*)
    batch_review_count="\$(increment_counter "${state_dir}/batch-review-count.txt")"
    if [[ "\$batch_review_count" -eq 1 ]]; then
      printf '%s\n' '${CODEX_RUNTIME_SESSION_LOG_LINE}'
      cat <<'OUT'
accept: no

blocker:
- none

major:
- [cross-issue] smoke harness forces one batch review fix round

minor:
- none
OUT
      exit 0
    fi

    cat <<'OUT'
accept: yes

blocker:
- none

major:
- none

minor:
- none
OUT
    printf '%s\n' '${CODEX_RUNTIME_SESSION_LOG_LINE}'
    exit 0
    ;;
  *"Make the required batch-review fixes, then stop."*)
    fix_batch_review_count="\$(increment_counter "${state_dir}/fix-batch-review-count.txt")"
    printf 'batch review fix round %s\n' "\$fix_batch_review_count" >> smoke-target.txt
    printf 'applied batch review fix round %s\n' "\$fix_batch_review_count"
    exit 0
    ;;
  *"Make the required batch-check fixes, then stop."*)
    printf 'batch checks fix\n' >> smoke-target.txt
    printf 'applied batch checks fix\n'
    exit 0
    ;;
  *"Return exactly this format"*)
    review_count="\$(increment_counter "${state_dir}/review-count.txt")"
    if [[ "\$review_count" -eq 1 ]]; then
      printf '%s\n' '${CODEX_RUNTIME_SESSION_LOG_LINE}'
      cat <<'OUT'
accept: no

blocker:
- none

major:
- smoke harness forces one review fix round

minor:
- none
OUT
      exit 0
    fi

    cat <<'OUT'
accept: yes

blocker:
- none

major:
- none

minor:
- none
OUT
    printf '%s\n' '${CODEX_RUNTIME_SESSION_LOG_LINE}'
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
  *"run_codex retry succeeds"*)
    retry_success_count="\$(increment_counter "${state_dir}/run-codex-retry-success-count.txt")"
    if [[ "\$retry_success_count" -eq 1 ]]; then
      printf 'Selected model is at capacity. Please try a different model.\n'
      exit 1
    fi
    printf 'valid retry output\n'
    exit 0
    ;;
  *"run_codex non retryable failure"*)
    printf 'non retryable failure output\n'
    exit 42
    ;;
  *"run_codex retry exhausted"*)
    retry_exhausted_count="\$(increment_counter "${state_dir}/run-codex-retry-exhausted-count.txt")"
    printf 'Selected model is at capacity. Please try a different model. attempt %s\n' "\$retry_exhausted_count"
    exit 1
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

  cat > "${stub_dir}/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub shellcheck ok\n'
EOF

  chmod +x "${stub_dir}/git" "${stub_dir}/gh" "${stub_dir}/codex" "${stub_dir}/shellcheck"
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
  create_fixture_vendor_symlink
}

run_consumer_init_smoke() {
  local existing_checks_repo="${temp_root}/init-existing-checks"
  local existing_checks_log="${state_dir}/consumer-init-existing-checks.log"
  local invalid_option_log="${state_dir}/consumer-init-invalid-option.log"
  local missing_repo="${temp_root}/init-missing"
  local readme_repo="${temp_root}/init-readme"
  local run_scaffold_repo="${temp_root}/init-run-scaffold"
  local run_scaffold_expected_shell="${state_dir}/expected-consumer-shell.sh"
  local run_scaffold_expected_wrapper="${state_dir}/expected-consumer-run-issue.sh"
  local run_scaffold_forward_log="${state_dir}/consumer-run-forwarded-args.log"
  local run_scaffold_log="${state_dir}/consumer-init-run-scaffold.log"
  local run_scaffold_rerun_log="${state_dir}/consumer-init-run-scaffold-rerun.log"
  local run_scaffold_source_log="${state_dir}/consumer-init-run-source.log"
  local scaffold_repo="${temp_root}/init-scaffold"
  local scaffold_expected="${state_dir}/expected-consumer-run-changed.sh"
  local scaffold_log="${state_dir}/consumer-init-scaffold.log"
  local first_log="${state_dir}/consumer-init-first.log"
  local second_log="${state_dir}/consumer-init-second.log"
  local readme_log="${state_dir}/consumer-init-readme.log"

  log 'running consumer init smoke'

  create_init_fixture_repo "${missing_repo}"

  if ! (
    cd "${missing_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh"
  ) > "${first_log}" 2>&1; then
    fail 'consumer init should succeed for a direct-vendor consumer fixture with missing local files'
  fi

  assert_init_gitignore_configured "${missing_repo}/.gitignore"
  assert_file_exists "${missing_repo}/.issue_forge/project.sh"
  assert_default_consumer_project_file "${missing_repo}/.issue_forge/project.sh"
  assert_file_contains "${first_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_contains "${first_log}" 'note: issue_forge defaults checks to ./.issue_forge/checks/run_changed.sh'
  assert_file_contains "${first_log}" 'warning: missing README.md'
  assert_file_not_contains "${first_log}" 'warning: missing docs/README.md'
  assert_path_not_exists "${missing_repo}/.issue_forge/checks/run_changed.sh"
  assert_path_not_exists "${missing_repo}/tools/run_issue.sh"
  assert_path_not_exists "${missing_repo}/.issue_forge/shell.sh"
  assert_path_not_exists "${missing_repo}/README.md"
  assert_path_not_exists "${missing_repo}/docs/README.md"

  printf '# preserve existing consumer config\n' >> "${missing_repo}/.issue_forge/project.sh"

  if ! (
    cd "${missing_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh"
  ) > "${second_log}" 2>&1; then
    fail 'consumer init should succeed on idempotent rerun'
  fi

  assert_init_gitignore_configured "${missing_repo}/.gitignore"
  assert_file_contains "${missing_repo}/.issue_forge/project.sh" '# preserve existing consumer config'
  assert_file_contains "${second_log}" '.gitignore is already configured'
  assert_file_contains "${second_log}" '.issue_forge/project.sh already exists'
  assert_file_contains "${second_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_contains "${second_log}" 'warning: missing README.md'
  assert_file_not_contains "${second_log}" 'warning: missing docs/README.md'
  assert_path_not_exists "${missing_repo}/.issue_forge/checks/run_changed.sh"
  assert_path_not_exists "${missing_repo}/tools/run_issue.sh"
  assert_path_not_exists "${missing_repo}/.issue_forge/shell.sh"
  assert_path_not_exists "${missing_repo}/README.md"
  assert_path_not_exists "${missing_repo}/docs/README.md"

  if (
    cd "${missing_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh" --unknown-option
  ) > "${invalid_option_log}" 2>&1; then
    fail 'consumer init should fail for an unknown option'
  fi
  assert_file_contains "${invalid_option_log}" 'Usage: tools/consumer/init.sh [--scaffold-checks|--scaffold-run] [consumer-root]'

  create_init_fixture_repo "${run_scaffold_repo}"
  if ! (
    cd "${run_scaffold_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh" --scaffold-run
  ) > "${run_scaffold_log}" 2>&1; then
    fail 'consumer init --scaffold-run should succeed for a direct-vendor consumer fixture'
  fi

  write_expected_consumer_run_wrapper "${run_scaffold_expected_wrapper}"
  write_expected_consumer_shell_snippet "${run_scaffold_expected_shell}"
  assert_init_gitignore_configured "${run_scaffold_repo}/.gitignore"
  assert_file_exists "${run_scaffold_repo}/.issue_forge/project.sh"
  assert_default_consumer_project_file "${run_scaffold_repo}/.issue_forge/project.sh"
  assert_file_exists "${run_scaffold_repo}/tools/run_issue.sh"
  assert_file_executable "${run_scaffold_repo}/tools/run_issue.sh"
  assert_file_ends_with_newline "${run_scaffold_repo}/tools/run_issue.sh"
  assert_files_equal "${run_scaffold_expected_wrapper}" "${run_scaffold_repo}/tools/run_issue.sh" 'scaffolded consumer run wrapper'
  assert_file_exists "${run_scaffold_repo}/.issue_forge/shell.sh"
  assert_file_ends_with_newline "${run_scaffold_repo}/.issue_forge/shell.sh"
  assert_files_equal "${run_scaffold_expected_shell}" "${run_scaffold_repo}/.issue_forge/shell.sh" 'scaffolded consumer shell snippet'
  assert_file_contains "${run_scaffold_log}" 'created tools/run_issue.sh'
  assert_file_contains "${run_scaffold_log}" 'created .issue_forge/shell.sh'
  assert_file_contains "${run_scaffold_log}" 'note: one-shot: source .issue_forge/shell.sh, then run 5'
  assert_file_contains "${run_scaffold_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_contains "${run_scaffold_log}" 'note: issue_forge defaults checks to ./.issue_forge/checks/run_changed.sh'
  assert_file_contains "${run_scaffold_log}" 'warning: missing README.md'
  assert_file_not_contains "${run_scaffold_log}" 'warning: missing docs/README.md'
  assert_path_not_exists "${run_scaffold_repo}/.issue_forge/checks/run_changed.sh"
  assert_path_not_exists "${run_scaffold_repo}/README.md"
  assert_path_not_exists "${run_scaffold_repo}/docs/README.md"

  cat > "${run_scaffold_repo}/tools/run_issue.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" > "${run_scaffold_forward_log}"
EOF
  chmod +x "${run_scaffold_repo}/tools/run_issue.sh"
  mkdir -p "${run_scaffold_repo}/nested/dir"

  if ! (
    cd "${run_scaffold_repo}/nested/dir"
    bash -c '
set -euo pipefail
source "$1"
declare -F run >/dev/null
run 5
' bash "${run_scaffold_repo}/.issue_forge/shell.sh"
  ) > "${run_scaffold_source_log}" 2>&1; then
    fail 'source .issue_forge/shell.sh should define run and forward arguments from a subdirectory'
  fi
  assert_equals '5' "$(< "${run_scaffold_forward_log}")" 'run shell snippet forwarded issue number'

  cat > "${run_scaffold_repo}/.issue_forge/shell.sh" <<'EOF'
# consumer-owned shell snippet
run() {
  printf 'consumer-owned run\n'
}
EOF

  if ! (
    cd "${temp_root}"
    "${run_scaffold_repo}/${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh" --scaffold-run "${run_scaffold_repo}"
  ) > "${run_scaffold_rerun_log}" 2>&1; then
    fail 'consumer init --scaffold-run should preserve existing run scaffold files'
  fi

  assert_file_contains "${run_scaffold_rerun_log}" 'tools/run_issue.sh already exists'
  assert_file_contains "${run_scaffold_rerun_log}" '.issue_forge/shell.sh already exists'
  assert_file_contains "${run_scaffold_rerun_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_contains "${run_scaffold_rerun_log}" 'warning: missing README.md'
  assert_file_not_contains "${run_scaffold_rerun_log}" 'warning: missing docs/README.md'
  assert_file_contains "${run_scaffold_repo}/tools/run_issue.sh" "${run_scaffold_forward_log}"
  assert_file_contains "${run_scaffold_repo}/.issue_forge/shell.sh" 'consumer-owned run'
  assert_path_not_exists "${run_scaffold_repo}/.issue_forge/checks/run_changed.sh"
  assert_path_not_exists "${run_scaffold_repo}/README.md"
  assert_path_not_exists "${run_scaffold_repo}/docs/README.md"

  create_init_fixture_repo "${scaffold_repo}"
  if ! (
    cd "${scaffold_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh" --scaffold-checks
  ) > "${scaffold_log}" 2>&1; then
    fail 'consumer init --scaffold-checks should succeed for a direct-vendor consumer fixture'
  fi

  write_expected_consumer_checks_starter "${scaffold_expected}"
  assert_init_gitignore_configured "${scaffold_repo}/.gitignore"
  assert_file_exists "${scaffold_repo}/.issue_forge/project.sh"
  assert_default_consumer_project_file "${scaffold_repo}/.issue_forge/project.sh"
  assert_file_exists "${scaffold_repo}/.issue_forge/checks/run_changed.sh"
  assert_file_executable "${scaffold_repo}/.issue_forge/checks/run_changed.sh"
  assert_files_equal "${scaffold_expected}" "${scaffold_repo}/.issue_forge/checks/run_changed.sh" 'scaffolded consumer checks starter'
  assert_file_contains "${scaffold_log}" 'created .issue_forge/checks/run_changed.sh'
  assert_file_not_contains "${scaffold_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_not_contains "${scaffold_log}" 'note: issue_forge defaults checks to ./.issue_forge/checks/run_changed.sh'
  assert_file_contains "${scaffold_log}" 'warning: missing README.md'
  assert_file_not_contains "${scaffold_log}" 'warning: missing docs/README.md'
  assert_path_not_exists "${scaffold_repo}/tools/run_issue.sh"
  assert_path_not_exists "${scaffold_repo}/.issue_forge/shell.sh"
  assert_path_not_exists "${scaffold_repo}/README.md"
  assert_path_not_exists "${scaffold_repo}/docs/README.md"

  create_init_fixture_repo "${existing_checks_repo}"
  mkdir -p "${existing_checks_repo}/.issue_forge/checks"
  cat > "${existing_checks_repo}/.issue_forge/checks/run_changed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'consumer owned checks\n'
EOF
  chmod +x "${existing_checks_repo}/.issue_forge/checks/run_changed.sh"

  if ! (
    cd "${temp_root}"
    "${existing_checks_repo}/${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh" --scaffold-checks "${existing_checks_repo}"
  ) > "${existing_checks_log}" 2>&1; then
    fail 'consumer init --scaffold-checks should preserve an existing checks file'
  fi

  assert_init_gitignore_configured "${existing_checks_repo}/.gitignore"
  assert_file_contains "${existing_checks_repo}/.issue_forge/checks/run_changed.sh" 'consumer owned checks'
  assert_file_contains "${existing_checks_log}" '.issue_forge/checks/run_changed.sh already exists'
  assert_file_not_contains "${existing_checks_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_contains "${existing_checks_log}" 'warning: missing README.md'
  assert_file_not_contains "${existing_checks_log}" 'warning: missing docs/README.md'

  create_init_fixture_repo "${readme_repo}"
  mkdir -p "${readme_repo}/.issue_forge/checks"
  cat > "${readme_repo}/.issue_forge/checks/run_changed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
  chmod +x "${readme_repo}/.issue_forge/checks/run_changed.sh"
  cat > "${readme_repo}/README.md" <<'EOF'
# Existing consumer README
EOF

  if ! (
    cd "${readme_repo}"
    "./${FIXTURE_ENGINE_PATH}/tools/consumer/init.sh"
  ) > "${readme_log}" 2>&1; then
    fail 'consumer init should succeed when checks exist, README exists, and docs/README.md is missing'
  fi

  assert_init_gitignore_configured "${readme_repo}/.gitignore"
  assert_file_exists "${readme_repo}/.issue_forge/project.sh"
  assert_default_consumer_project_file "${readme_repo}/.issue_forge/project.sh"
  assert_file_not_contains "${readme_log}" 'warning: missing .issue_forge/checks/run_changed.sh'
  assert_file_not_contains "${readme_log}" 'note: issue_forge defaults checks to ./.issue_forge/checks/run_changed.sh'
  assert_file_not_contains "${readme_log}" 'warning: missing README.md'
  assert_file_not_contains "${readme_log}" 'warning: missing docs/README.md'
  assert_path_not_exists "${readme_repo}/docs/README.md"
}

run_start_from_issue_smoke() {
  log 'running start_from_issue.sh smoke'

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_ISSUE_PATH}/start_from_issue.sh" "${ISSUE_NUMBER}"
  )

  assert_vendor_engine_symlink_present
  assert_equals "${ISSUE_NUMBER}" "$(< "${repo_dir}/.work/current_issue")" 'current issue file'
  assert_file_exists "${repo_dir}/.work/base_commit"
  assert_equals "issue/${ISSUE_NUMBER}-regression-harness-issue" "$(< "${repo_dir}/.work/current_branch")" 'current branch file'
  assert_equals "issue/${ISSUE_NUMBER}-regression-harness-issue" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'checked-out branch'
  assert_file_exists "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "# Issue #${ISSUE_NUMBER}"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "Title: ${ISSUE_TITLE}"
  assert_file_contains "${repo_dir}/.work/issues/${ISSUE_NUMBER}.md" "URL: ${ISSUE_URL}"
  bootstrap_base_commit="$(< "${repo_dir}/.work/base_commit")"
  assert_equals "$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)" "${bootstrap_base_commit}" 'bootstrap base commit'

  if "${REAL_GIT}" -C "${repo_dir}" check-ignore -q .work/current_issue; then
    fail 'fixture repo should not ignore .work/'
  fi
}

run_make_pr_only_smoke() {
  local pr_url

  log 'running make_pr_only.sh smoke'
  printf 'committed before PR-only publish\n' > "${repo_dir}/pr-only-fixture.txt"
  "${REAL_GIT}" -C "${repo_dir}" add pr-only-fixture.txt
  "${REAL_GIT}" -C "${repo_dir}" commit -m 'fixture: add pr-only changed file' >/dev/null
  clear_command_logs

  pr_url="$({
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/make_pr_only.sh" "${ISSUE_NUMBER}"
  })"

  assert_equals "https://example.test/pr/${ISSUE_NUMBER}" "${pr_url}" 'make_pr_only output'
  assert_file_contains "${state_dir}/gh.log" "pr list --head issue/${ISSUE_NUMBER}-regression-harness-issue --base main --state open --json url --jq"
  assert_file_contains "${state_dir}/gh.log" "pr create --draft --base main --head issue/${ISSUE_NUMBER}-regression-harness-issue"
  assert_equals "${ISSUE_TITLE}" "$(< "${state_dir}/pr-create-title.txt")" 'make_pr_only PR title'
  assert_pr_body_common_sections "${state_dir}/pr-create-body.txt"
  assert_file_contains "${state_dir}/pr-create-body.txt" "\`pr-only-fixture.txt\`"
  assert_fixed_line_count "${state_dir}/pr-create-body.txt" '- not available yet' '2' 'make_pr_only missing artifact markers'
  assert_path_not_exists "${state_dir}/pr-edit-body.txt"

  if grep -Fq 'push --set-upstream origin issue/' "${state_dir}/git.log"; then
    fail 'make_pr_only.sh should not push the issue branch'
  fi
}

run_issue_flow_skip_publish_smoke() {
  local previous_head
  local current_head
  local skip_publish_log="${state_dir}/skip-publish.log"

  log 'running CODEX_FLOW_SKIP_PUBLISH smoke'
  clear_command_logs
  reset_flow_counters
  previous_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"

  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_flow.sh" "${ISSUE_NUMBER}"
  ) > "${skip_publish_log}" 2>&1; then
    cat "${skip_publish_log}" >&2
    fail 'CODEX_FLOW_SKIP_PUBLISH=1 run_issue_flow.sh should succeed'
  fi

  current_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"
  if [[ "${current_head}" == "${previous_head}" ]]; then
    fail 'CODEX_FLOW_SKIP_PUBLISH=1 should still commit issue flow changes'
  fi

  assert_file_contains "${skip_publish_log}" 'publish skipped because CODEX_FLOW_SKIP_PUBLISH is set'
  assert_equals "chore: address issue #${ISSUE_NUMBER}" "$("${REAL_GIT}" -C "${repo_dir}" log -1 --pretty=%s)" 'skip publish commit message'
  assert_file_not_contains "${state_dir}/git.log" "push --set-upstream origin issue/${ISSUE_NUMBER}-regression-harness-issue"
  assert_file_not_contains "${state_dir}/gh.log" 'pr create'
  assert_file_not_contains "${state_dir}/gh.log" 'pr edit'
}

write_pr_body_for_current_issue() {
  local body_path="$1"

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" bash -c '
set -euo pipefail
body_path="$1"
issue_number="$2"
source vendor/issue_forge/tools/codex/lib/config.sh
source vendor/issue_forge/tools/codex/lib/flow_state.sh
source vendor/issue_forge/tools/codex/lib/publish_helpers.sh
issue_file="$(require_issue_file "$issue_number")"
issue_title="$(read_issue_title_from_issue_file "$issue_file")"
branch_name="$(< "$CODEX_FLOW_CURRENT_BRANCH_FILE")"
write_issue_pr_body_file "$issue_number" "$branch_name" "$issue_title" "$body_path"
' bash "$body_path" "${ISSUE_NUMBER}"
  )
}

run_pr_body_utf8_smoke() {
  local body_path="${state_dir}/pr-body-utf8.txt"
  local original_issue_file="${state_dir}/issue-${ISSUE_NUMBER}.original.md"
  local issue_file="${repo_dir}/.work/issues/${ISSUE_NUMBER}.md"

  log 'running PR body UTF-8 smoke'
  cp "${issue_file}" "${original_issue_file}"
  mkdir -p "${repo_dir}/.work/codex"

  cat > "${issue_file}" <<EOF
# Issue #${ISSUE_NUMBER}

Title: ${UTF8_PR_BODY_TITLE}
URL: ${ISSUE_URL}

## Body
Smoke harness fixture issue body.
EOF

  printf '%s\n' "${UTF8_CHECKS_LINE}" > "${repo_dir}/.work/codex/checks.log"

  write_pr_body_for_current_issue "${body_path}"

  assert_file_contains "${body_path}" "${UTF8_PR_BODY_TITLE}"
  assert_file_contains "${body_path}" "${UTF8_CHECKS_LINE}"

  mv "${original_issue_file}" "${issue_file}"
  rm -f "${repo_dir}/.work/codex/checks.log"
}

run_pr_body_review_count_smoke() {
  local review_file="${repo_dir}/.work/codex/review.txt"
  local placeholder_body="${state_dir}/pr-body-review-placeholder.txt"
  local mixed_body="${state_dir}/pr-body-review-mixed.txt"

  log 'running PR body review count smoke'
  mkdir -p "${repo_dir}/.work/codex"

  write_review_output_fixture "${review_file}" 'yes' '-  NONE  ' '- No Issues' $'-   n/a\n- nothing'
  write_pr_body_for_current_issue "${placeholder_body}"
  assert_file_contains "${placeholder_body}" 'accept: yes'
  assert_file_contains "${placeholder_body}" 'findings: blocker 0, major 0, minor 0'

  write_review_output_fixture "${review_file}" 'yes' '-  NONE  ' '- No Issues' $'- n/a\n- real minor follow-up'
  write_pr_body_for_current_issue "${mixed_body}"
  assert_file_contains "${mixed_body}" 'accept: yes'
  assert_file_contains "${mixed_body}" 'findings: blocker 0, major 0, minor 1'

  rm -f "${review_file}"
}

run_doctor_smoke() {
  local doctor_success_log="${state_dir}/doctor-success.log"
  local doctor_warning_log="${state_dir}/doctor-warning.log"
  local doctor_missing_light_log="${state_dir}/doctor-missing-light.log"
  local doctor_light_disabled_log="${state_dir}/doctor-light-disabled.log"
  local doctor_failure_log="${state_dir}/doctor-failure.log"
  local custom_prompt_dir="${state_dir}/doctor-prompts-without-light"
  local original_project_config
  log 'running doctor.sh smoke'

  set_work_ignore_fixture_state 'enabled'
  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${doctor_success_log}" 2>&1; then
    fail 'doctor.sh should succeed when requirements are satisfied'
  fi
  assert_file_contains "${doctor_success_log}" 'OK'
  assert_file_not_contains "${doctor_success_log}" 'WARN .work/'
  assert_file_not_contains "${doctor_success_log}" 'FAIL'

  set_work_ignore_fixture_state 'disabled'
  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${doctor_warning_log}" 2>&1; then
    fail 'doctor.sh should exit 0 when only warning-level findings exist'
  fi
  assert_file_contains "${doctor_warning_log}" 'WARN .work/ is not ignored by git; this is recommended for local hygiene but not a hard requirement'
  assert_file_contains "${doctor_warning_log}" '0 failure(s)'

  original_project_config="$(mktemp)"
  cp "${repo_dir}/.issue_forge/project.sh" "${original_project_config}"
  mkdir -p "${custom_prompt_dir}"
  cp "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/prompts/implementation.prompt.md.tmpl" "${custom_prompt_dir}/implementation.prompt.md.tmpl"
  cp "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/prompts/fix-from-checks.prompt.md.tmpl" "${custom_prompt_dir}/fix-from-checks.prompt.md.tmpl"
  cp "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/prompts/review.prompt.md.tmpl" "${custom_prompt_dir}/review.prompt.md.tmpl"
  cp "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/prompts/fix-from-review.prompt.md.tmpl" "${custom_prompt_dir}/fix-from-review.prompt.md.tmpl"
  set_work_ignore_fixture_state 'enabled'

  cat > "${repo_dir}/.issue_forge/project.sh" <<EOF
CODEX_FLOW_PROMPTS_DIR='${custom_prompt_dir}'
EOF

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${doctor_missing_light_log}" 2>&1; then
    fail 'doctor.sh should fail when queue light review is enabled and review-light template is missing'
  fi
  assert_file_contains "${doctor_missing_light_log}" "FAIL missing prompt template: ${custom_prompt_dir}/review-light.prompt.md.tmpl"

  cat > "${repo_dir}/.issue_forge/project.sh" <<EOF
CODEX_FLOW_PROMPTS_DIR='${custom_prompt_dir}'
CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW=0
EOF

  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${doctor_light_disabled_log}" 2>&1; then
    cat "${doctor_light_disabled_log}" >&2
    fail 'doctor.sh should not fail solely because review-light template is missing when queue light review is disabled'
  fi
  assert_file_not_contains "${doctor_light_disabled_log}" "missing prompt template: ${custom_prompt_dir}/review-light.prompt.md.tmpl"
  assert_file_contains "${doctor_light_disabled_log}" '0 failure(s)'

  cat > "${repo_dir}/.issue_forge/project.sh" <<'EOF'
CODEX_FLOW_BASE_REF='origin/missing'
EOF

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${doctor_failure_log}" 2>&1; then
    fail 'doctor.sh should fail when the configured bootstrap base ref does not resolve'
  fi
  assert_file_contains "${doctor_failure_log}" 'FAIL Missing required base ref: origin/missing'
  assert_file_contains "${doctor_failure_log}" '1 failure(s)'

  mv "${original_project_config}" "${repo_dir}/.issue_forge/project.sh"
}

run_invalid_consumer_root_smoke() {
  local invalid_root="${temp_root}/invalid-consumer-root"
  local invalid_consumer_root_log="${state_dir}/invalid-consumer-root.log"

  log 'running invalid ISSUE_FORGE_CONSUMER_ROOT smoke'
  mkdir -p "${invalid_root}"

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      ISSUE_FORGE_CONSUMER_ROOT="${invalid_root}" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/doctor.sh"
  ) > "${invalid_consumer_root_log}" 2>&1; then
    fail 'doctor.sh should fail when ISSUE_FORGE_CONSUMER_ROOT does not contain .issue_forge/project.sh'
  fi

  assert_file_contains "${invalid_consumer_root_log}" 'Invalid ISSUE_FORGE_CONSUMER_ROOT'
  assert_file_not_contains "${invalid_consumer_root_log}" "loaded consumer config via current runtime path: ${repo_dir}/.issue_forge/project.sh"
}

run_run_codex_retry_smoke() {
  log 'running run_codex.sh retry smoke'

  retry_success_prompt="${prompt_dir}/run-codex-retry-success.prompt.md"
  retry_success_stdout="${state_dir}/run-codex-retry-success.stdout"
  retry_success_stderr="${state_dir}/run-codex-retry-success.stderr"
  retry_success_expected="${state_dir}/run-codex-retry-success.expected"
  printf 'run_codex retry succeeds\n' > "${retry_success_prompt}"
  printf 'valid retry output\n' > "${retry_success_expected}"
  rm -f "${state_dir}/run-codex-retry-success-count.txt"
  if ! PATH="${stub_dir}:$PATH" \
    CODEX_TRANSIENT_INITIAL_DELAY_SEC=0 \
    CODEX_TRANSIENT_MAX_RETRIES=1 \
    "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" read "${retry_success_prompt}" \
    > "${retry_success_stdout}" 2> "${retry_success_stderr}"; then
    fail 'expected transient run_codex.sh read retry to succeed'
  fi
  assert_files_equal "${retry_success_expected}" "${retry_success_stdout}" 'retry success stdout'
  assert_file_not_contains "${retry_success_stdout}" 'Selected model is at capacity. Please try a different model.'
  assert_file_contains "${retry_success_stderr}" '[codex] transient Codex failure detected; retrying attempt 2/2 after 0 seconds'

  non_retryable_prompt="${prompt_dir}/run-codex-non-retryable.prompt.md"
  non_retryable_stdout="${state_dir}/run-codex-non-retryable.stdout"
  non_retryable_stderr="${state_dir}/run-codex-non-retryable.stderr"
  non_retryable_expected="${state_dir}/run-codex-non-retryable.expected"
  printf 'run_codex non retryable failure\n' > "${non_retryable_prompt}"
  printf 'non retryable failure output\n' > "${non_retryable_expected}"
  set +e
  PATH="${stub_dir}:$PATH" \
    CODEX_TRANSIENT_INITIAL_DELAY_SEC=0 \
    "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" read "${non_retryable_prompt}" \
    > "${non_retryable_stdout}" 2> "${non_retryable_stderr}"
  non_retryable_status="$?"
  set -e
  assert_equals '42' "${non_retryable_status}" 'non-retryable failure status'
  assert_files_equal "${non_retryable_expected}" "${non_retryable_stdout}" 'non-retryable failure stdout'

  retry_exhausted_prompt="${prompt_dir}/run-codex-retry-exhausted.prompt.md"
  retry_exhausted_stdout="${state_dir}/run-codex-retry-exhausted.stdout"
  retry_exhausted_stderr="${state_dir}/run-codex-retry-exhausted.stderr"
  retry_exhausted_expected="${state_dir}/run-codex-retry-exhausted.expected"
  printf 'run_codex retry exhausted\n' > "${retry_exhausted_prompt}"
  printf 'Selected model is at capacity. Please try a different model. attempt 2\n' > "${retry_exhausted_expected}"
  rm -f "${state_dir}/run-codex-retry-exhausted-count.txt"
  set +e
  PATH="${stub_dir}:$PATH" \
    CODEX_TRANSIENT_INITIAL_DELAY_SEC=0 \
    CODEX_TRANSIENT_MAX_RETRIES=1 \
    "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" read "${retry_exhausted_prompt}" \
    > "${retry_exhausted_stdout}" 2> "${retry_exhausted_stderr}"
  retry_exhausted_status="$?"
  set -e
  assert_equals '1' "${retry_exhausted_status}" 'retry-exhausted failure status'
  assert_files_equal "${retry_exhausted_expected}" "${retry_exhausted_stdout}" 'retry-exhausted failure stdout'
  assert_file_not_contains "${retry_exhausted_stdout}" 'attempt 1'
  assert_file_contains "${retry_exhausted_stderr}" '[codex] transient Codex failure persisted after 2 attempts; giving up'
}

run_run_codex_smoke() {
  log 'running run_codex.sh mode smoke'

  write_prompt="${prompt_dir}/write.prompt.md"
  read_prompt="${prompt_dir}/read.prompt.md"
  printf 'write prompt\n' > "${write_prompt}"
  printf 'read prompt\n' > "${read_prompt}"
  : > "${state_dir}/codex.log"

  write_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" write "${write_prompt}"
  )"
  read_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" read "${read_prompt}"
  )"
  override_output="$(
    PATH="${stub_dir}:$PATH" \
      CODEX_RUN_REASONING_EFFORT=override_effort \
      "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" write "${write_prompt}"
  )"
  post_override_write_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" write "${write_prompt}"
  )"

  assert_equals 'stub codex ok' "${write_output}" 'write mode stdout'
  assert_equals 'stub codex ok' "${read_output}" 'read mode stdout'
  assert_equals 'stub codex ok' "${override_output}" 'override write mode stdout'
  assert_equals 'stub codex ok' "${post_override_write_output}" 'post-override write mode stdout'
  assert_fixed_line_count "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=high' '2' 'write reasoning profile count'
  assert_fixed_line_count "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=medium' '1' 'read reasoning profile count'
  assert_fixed_line_count "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=override_effort' '1' 'reasoning override count'

  invalid_mode_log="${state_dir}/invalid-mode.log"
  if PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" invalid "${write_prompt}" > "${invalid_mode_log}" 2>&1; then
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
source vendor/issue_forge/tools/codex/lib/config.sh
source vendor/issue_forge/tools/codex/lib/codex_profiles.sh
printf "write-profile=%s\n" "$(resolve_codex_profile_for_mode write)"
printf "write-sandbox=%s\n" "$(resolve_codex_profile_sandbox "$CODEX_FLOW_WRITE_PROFILE")"
printf "write-reasoning=%s\n" "$(resolve_codex_profile_reasoning "$CODEX_FLOW_WRITE_PROFILE")"
printf "read-profile=%s\n" "$(resolve_codex_profile_for_mode read)"
printf "read-sandbox=%s\n" "$(resolve_codex_profile_sandbox "$CODEX_FLOW_READ_PROFILE")"
printf "read-reasoning=%s\n" "$(resolve_codex_profile_reasoning "$CODEX_FLOW_READ_PROFILE")"
'
    )
  )"

  assert_equals $'write-profile=write\nwrite-sandbox=danger-full-access\nwrite-reasoning=high\nread-profile=read\nread-sandbox=danger-full-access\nread-reasoning=medium' "${profile_report}" 'profile resolution output'

  invalid_profile_log="${state_dir}/invalid-profile.log"
  if (
    cd "${repo_dir}"
    bash -lc 'set -euo pipefail
source vendor/issue_forge/tools/codex/lib/config.sh
source vendor/issue_forge/tools/codex/lib/codex_profiles.sh
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
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=high
readonly CODEX_FLOW_PROFILE_READ_SANDBOX=danger-full-access
readonly CODEX_FLOW_PROFILE_READ_REASONING=medium
source vendor/issue_forge/tools/codex/lib/codex_profiles.sh
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
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=high
readonly CODEX_FLOW_PROFILE_READ_SANDBOX=danger-full-access
readonly CODEX_FLOW_PROFILE_READ_REASONING=medium
source vendor/issue_forge/tools/codex/lib/codex_profiles.sh
resolve_codex_profile_sandbox write
'
  ) > "${incomplete_profile_log}" 2>&1; then
    fail 'expected incomplete execution profile settings to fail'
  fi
  assert_file_contains "${incomplete_profile_log}" 'Missing Codex profile setting: profile write sandbox'
}

run_token_usage_parser_smoke() {
  local token_log="${state_dir}/token-usage-parser.log"
  local no_token_log="${state_dir}/token-usage-parser-empty.log"
  local parsed_tokens
  local empty_tokens

  log 'running token usage parser smoke'

  cat > "$token_log" <<'EOF'
OpenAI Codex v0.0.0
tokens used
42
codex
tokens used
133,813
EOF
  cat > "$no_token_log" <<'EOF'
OpenAI Codex v0.0.0
no token block here
EOF

  # shellcheck source=tools/codex/lib/token_usage_helpers.sh
  source "${REPO_ROOT}/tools/codex/lib/token_usage_helpers.sh"

  parsed_tokens="$(extract_codex_token_usage "$token_log")"
  empty_tokens="$(extract_codex_token_usage "$no_token_log")"
  assert_equals '133813' "$parsed_tokens" 'token usage parser should return final comma-normalized value'
  assert_equals '' "$empty_tokens" 'token usage parser should return empty without a token block'
}

run_review_output_validation_smoke() {
  local valid_yes_empty_output="${state_dir}/review-valid-yes-empty.txt"
  local valid_yes_empty_raw="${state_dir}/review-valid-yes-empty.raw.txt"
  local valid_yes_output="${state_dir}/review-valid-yes.txt"
  local valid_yes_raw="${state_dir}/review-valid-yes.raw.txt"
  local valid_yes_placeholder_output="${state_dir}/review-valid-yes-placeholder.txt"
  local valid_yes_placeholder_raw="${state_dir}/review-valid-yes-placeholder.raw.txt"
  local invalid_yes_blocker_output="${state_dir}/review-invalid-yes-blocker.txt"
  local invalid_yes_blocker_raw="${state_dir}/review-invalid-yes-blocker.raw.txt"
  local invalid_yes_blocker_log="${state_dir}/review-invalid-yes-blocker.log"
  local invalid_yes_major_output="${state_dir}/review-invalid-yes-major.txt"
  local invalid_yes_major_raw="${state_dir}/review-invalid-yes-major.raw.txt"
  local invalid_yes_major_log="${state_dir}/review-invalid-yes-major.log"
  local valid_no_output="${state_dir}/review-valid-no.txt"
  local valid_no_raw="${state_dir}/review-valid-no.raw.txt"
  local runtime_before_output="${state_dir}/review-runtime-before.txt"
  local runtime_before_raw="${state_dir}/review-runtime-before.raw.txt"
  local runtime_after_output="${state_dir}/review-runtime-after.txt"
  local runtime_after_raw="${state_dir}/review-runtime-after.raw.txt"
  local runtime_fixture="${state_dir}/review-runtime-fixture.txt"
  local token_trailer_output="${state_dir}/review-token-trailer.txt"
  local token_trailer_raw="${state_dir}/review-token-trailer.raw.txt"
  local token_trailer_extra_output="${state_dir}/review-token-trailer-extra.txt"
  local token_trailer_extra_raw="${state_dir}/review-token-trailer-extra.raw.txt"
  local token_trailer_extra_log="${state_dir}/review-token-trailer-extra.log"
  local transcript_output="${state_dir}/review-transcript.txt"
  local transcript_raw="${state_dir}/review-transcript.raw.txt"
  local garbage_before_output="${state_dir}/review-garbage-before.txt"
  local garbage_before_raw="${state_dir}/review-garbage-before.raw.txt"
  local garbage_before_log="${state_dir}/review-garbage-before.log"
  local garbage_after_output="${state_dir}/review-garbage-after.txt"
  local garbage_after_raw="${state_dir}/review-garbage-after.raw.txt"
  local garbage_after_log="${state_dir}/review-garbage-after.log"
  local malformed_output="${state_dir}/review-malformed.txt"
  local malformed_raw="${state_dir}/review-malformed.raw.txt"
  local malformed_log="${state_dir}/review-malformed.log"

  log 'running review output validation smoke'

  write_review_output_fixture "$valid_yes_empty_output" 'yes' '' '' ''
  cp "$valid_yes_empty_output" "$valid_yes_empty_raw"
  run_review_validation_command "$valid_yes_empty_output" "$valid_yes_empty_raw" 'yes'

  write_review_output_fixture "$valid_yes_output" 'yes' '' '' '- minor follow-up remains'
  cp "$valid_yes_output" "$valid_yes_raw"
  run_review_validation_command "$valid_yes_output" "$valid_yes_raw" 'yes'

  write_review_output_fixture "$valid_yes_placeholder_output" 'yes' '-  NONE  ' '- No Issues' $'-   n/a\n- nothing'
  cp "$valid_yes_placeholder_output" "$valid_yes_placeholder_raw"
  run_review_validation_command "$valid_yes_placeholder_output" "$valid_yes_placeholder_raw" 'yes'

  write_review_output_fixture "$invalid_yes_blocker_output" 'yes' '- blocker still present' '' ''
  cp "$invalid_yes_blocker_output" "$invalid_yes_blocker_raw"
  if run_review_validation_command "$invalid_yes_blocker_output" "$invalid_yes_blocker_raw" 'yes' > "$invalid_yes_blocker_log" 2>&1; then
    fail 'accept: yes with blocker findings should fail validation'
  fi
  assert_file_contains "$invalid_yes_blocker_log" 'review output is inconsistent with acceptance'

  write_review_output_fixture "$invalid_yes_major_output" 'yes' '' '- major still present' ''
  cp "$invalid_yes_major_output" "$invalid_yes_major_raw"
  if run_review_validation_command "$invalid_yes_major_output" "$invalid_yes_major_raw" 'yes' > "$invalid_yes_major_log" 2>&1; then
    fail 'accept: yes with major findings should fail validation'
  fi
  assert_file_contains "$invalid_yes_major_log" 'review output is inconsistent with acceptance'

  write_review_output_fixture "$valid_no_output" 'no' '- blocker remains' '- major remains' '- minor remains'
  cp "$valid_no_output" "$valid_no_raw"
  run_review_validation_command "$valid_no_output" "$valid_no_raw" 'no'

  write_review_output_fixture "$runtime_fixture" 'yes' '' '' '- minor follow-up remains'
  {
    printf '%s\n' "$CODEX_RUNTIME_SESSION_LOG_LINE"
    cat "$runtime_fixture"
  } > "$runtime_before_raw"
  run_review_extraction_validation_command "$runtime_before_raw" "$runtime_before_output" 'yes'
  assert_file_contains "$runtime_before_raw" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "$runtime_before_output" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "$runtime_before_output" 'accept: yes'

  {
    cat "$runtime_fixture"
    printf '%s\n' "$CODEX_RUNTIME_SESSION_LOG_LINE"
  } > "$runtime_after_raw"
  run_review_extraction_validation_command "$runtime_after_raw" "$runtime_after_output" 'yes'
  assert_file_contains "$runtime_after_raw" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "$runtime_after_output" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "$runtime_after_output" 'accept: yes'

  {
    cat "$runtime_fixture"
    printf '\n'
    printf 'tokens used\n'
    printf '133,813\n'
    printf '\n'
  } > "$token_trailer_raw"
  run_review_extraction_validation_command "$token_trailer_raw" "$token_trailer_output" 'yes'
  assert_file_contains "$token_trailer_raw" 'tokens used'
  assert_file_contains "$token_trailer_raw" '133,813'
  assert_file_not_contains "$token_trailer_output" 'tokens used'
  assert_file_not_contains "$token_trailer_output" '133,813'
  assert_file_contains "$token_trailer_output" 'accept: yes'

  {
    cat "$runtime_fixture"
    printf '\n'
    printf 'tokens used\n'
    printf '133813\n'
    printf 'unrelated extra line\n'
  } > "$token_trailer_extra_raw"
  if run_review_extraction_validation_command "$token_trailer_extra_raw" "$token_trailer_extra_output" 'yes' > "$token_trailer_extra_log" 2>&1; then
    fail 'structured review output with token trailer and extra text should fail validation'
  fi
  assert_path_not_exists "$token_trailer_extra_output"

  cat > "$transcript_raw" <<EOF
Reading prompt from stdin...
OpenAI Codex v0.0.0
user
Return exactly this format:

accept: yes/no

blocker:
- none

major:
- none

minor:
- none
codex
I will inspect the provided material and then return the review block.
exec
sed -n '1,40p' smoke-target.txt
tool output
implementation round 1
${CODEX_RUNTIME_SESSION_LOG_LINE}
codex
accept: no

blocker:
- none

major:
- stale transcript candidate before the final review

minor:
- none
codex
accept: yes

blocker:
- none

major:
- none

minor:
- none
tokens used
50,261
accept: yes

blocker:
- none

major:
- none

minor:
- none
${CODEX_RUNTIME_SESSION_LOG_LINE}
EOF
  run_review_extraction_validation_command "$transcript_raw" "$transcript_output" 'yes'
  assert_file_contains "$transcript_raw" 'Reading prompt from stdin'
  assert_file_contains "$transcript_raw" 'tokens used'
  assert_file_contains "$transcript_raw" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "$transcript_output" 'Reading prompt from stdin'
  assert_file_not_contains "$transcript_output" 'OpenAI Codex'
  assert_file_not_contains "$transcript_output" 'user'
  assert_file_not_contains "$transcript_output" 'codex'
  assert_file_not_contains "$transcript_output" 'exec'
  assert_file_not_contains "$transcript_output" 'tool output'
  assert_file_not_contains "$transcript_output" 'tokens used'
  assert_file_not_contains "$transcript_output" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "$transcript_output" 'accept: no'
  assert_fixed_line_count "$transcript_output" 'accept: yes' '1' 'transcript extraction should keep one final review block'

  {
    printf 'unrelated garbage before review\n'
    cat "$runtime_fixture"
  } > "$garbage_before_raw"
  if run_review_extraction_validation_command "$garbage_before_raw" "$garbage_before_output" 'yes' > "$garbage_before_log" 2>&1; then
    fail 'garbage before structured review output should fail validation'
  fi

  {
    cat "$runtime_fixture"
    printf 'unrelated garbage after review\n'
  } > "$garbage_after_raw"
  if run_review_extraction_validation_command "$garbage_after_raw" "$garbage_after_output" 'yes' > "$garbage_after_log" 2>&1; then
    fail 'garbage after structured review output should fail validation'
  fi
  assert_path_not_exists "$garbage_after_output"

  cat > "$malformed_output" <<'EOF'
accept: yes
blocker:
- malformed because the required blank line is missing

major:

minor:
EOF
  cp "$malformed_output" "$malformed_raw"
  if run_review_validation_command "$malformed_output" "$malformed_raw" 'yes' > "$malformed_log" 2>&1; then
    fail 'malformed review output should fail validation'
  fi
  assert_file_contains "$malformed_log" 'review output format is invalid'
}

write_expected_issue_flow_prompts() {
  expected_prompt_dir="${prompt_dir}/expected"
  mkdir -p "${expected_prompt_dir}"

  cat > "${expected_prompt_dir}/implementation.prompt.md" <<EOF
Use the already-loaded AGENTS.md instructions. Do not re-read AGENTS.md unless you need to verify a specific line or resolve an ambiguity.
Read the issue artifact named below:
- .work/issues/${ISSUE_NUMBER}.md
Read README.md and docs/README.md only when they are directly relevant to the current issue. Prefer targeted rg/sed section reads over reading entire files.

You are the implementation session for issue #${ISSUE_NUMBER}.

Priority order for instructions and facts you use:
1. already-loaded AGENTS.md instructions
2. README.md when directly relevant
3. docs/README.md when directly relevant and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

Token discipline:
- Prefer \`rg\`, \`git diff --stat\`, \`git diff --name-only\`, and targeted file/hunk reads.
- Avoid printing full repository diffs unless needed for a concrete uncertainty.
- Avoid re-reading the same file/range repeatedly.
- Keep test/check output concise; inspect relevant failing sections instead of dumping huge logs.

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
Use the already-loaded AGENTS.md instructions. Do not re-read AGENTS.md unless you need to verify a specific line or resolve an ambiguity.
Read the issue/check artifact(s) named below:
- .work/issues/${ISSUE_NUMBER}.md
- .work/codex/checks.log
Read README.md and docs/README.md only when they are directly relevant to the current issue or check failure. Prefer targeted rg/sed section reads over reading entire files.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order for instructions and facts you use:
1. already-loaded AGENTS.md instructions
2. README.md when directly relevant
3. docs/README.md when directly relevant and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

Token discipline:
- Prefer \`rg\`, \`git diff --stat\`, \`git diff --name-only\`, and targeted file/hunk reads.
- Avoid printing full repository diffs unless needed for a concrete uncertainty.
- Avoid re-reading the same file/range repeatedly.
- Keep test/check output concise; inspect relevant failing sections instead of dumping huge logs.

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
Use the already-loaded AGENTS.md instructions. Do not re-read AGENTS.md unless you need to verify a specific line or resolve an ambiguity.
Read the issue/review artifact(s) named below:
- .work/issues/${ISSUE_NUMBER}.md
- .work/codex/review.diff
- .work/codex/review.untracked.txt
- .work/codex/review.summary.txt
Read README.md and docs/README.md only when they are directly relevant to the current issue, review finding, or diff. Prefer targeted rg/sed section reads over reading entire files.

You are the review session for issue #${ISSUE_NUMBER}.

Priority order for instructions and facts you use:
1. already-loaded AGENTS.md instructions
2. README.md when directly relevant
3. docs/README.md when directly relevant and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

Review only the provided review material.

Token discipline:
- Review only the provided material.
- Do not shell out to rediscover diffs.
- Inspect docs only for named conflicts or ambiguous source-of-truth questions.

Rules:
- Do not edit code.
- Do not shell out to git to discover the diff.
- Do not rely on a remote branch or PR.
- Stay within issue scope unless the issue conflicts with AGENTS.md or source-of-truth docs.
- If issue and docs conflict, docs win.
- Reject changes that satisfy the issue but violate AGENTS.md or source-of-truth docs.
- Accept changes that remain consistent with docs even if the issue wording is slightly broader.
- Focus on correctness, scope, regressions, repository rules, and doc consistency.
- If there is any real blocker or major finding, set \`accept: no\`.
- If there are only minor findings, \`accept: yes\` is allowed.
- If \`accept: yes\`, then \`blocker:\` and \`major:\` must contain only \`- none\`.
- Use the exact lowercase placeholder \`none\` for any empty section.
- Never output \`...\` or \`- ...\`.
- Do not add any prose before or after the required format.
- Every real finding must be a single \`- \` bullet in the correct section.

Return exactly this format and nothing else:

accept: yes/no

blocker:
- none

major:
- none

minor:
- none
EOF

  cat > "${expected_prompt_dir}/fix-from-review.prompt.md" <<EOF
Use the already-loaded AGENTS.md instructions. Do not re-read AGENTS.md unless you need to verify a specific line or resolve an ambiguity.
Read the issue/review artifact(s) named below:
- .work/issues/${ISSUE_NUMBER}.md
- .work/codex/review.txt
Read README.md and docs/README.md only when they are directly relevant to the current issue or review finding. Prefer targeted rg/sed section reads over reading entire files.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order for instructions and facts you use:
1. already-loaded AGENTS.md instructions
2. README.md when directly relevant
3. docs/README.md when directly relevant and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

Token discipline:
- Prefer \`rg\`, \`git diff --stat\`, \`git diff --name-only\`, and targeted file/hunk reads.
- Avoid printing full repository diffs unless needed for a concrete uncertainty.
- Avoid re-reading the same file/range repeatedly.
- Keep test/check output concise; inspect relevant failing sections instead of dumping huge logs.

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
  configure_fixture_gitignore_for_managed_paths
  assert_init_gitignore_configured "${repo_dir}/.gitignore"
  "${REAL_GIT}" -C "${repo_dir}" add .gitignore
  "${REAL_GIT}" -C "${repo_dir}" commit -m 'fixture: ignore managed paths' >/dev/null
  clear_command_logs
  reset_flow_counters

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_flow.sh" "${ISSUE_NUMBER}"
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
  assert_file_exists "${repo_dir}/.work/codex/review.summary.txt"
  assert_file_exists "${repo_dir}/.work/codex/review.raw.txt"
  assert_file_exists "${repo_dir}/.work/codex/review.txt"
  assert_file_exists "${repo_dir}/.work/codex/fix-from-review.log"
  assert_file_exists "${repo_dir}/.work/codex/token-usage.tsv"

  assert_file_exists "${repo_dir}/.work/codex/history/implementation.round-00.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-01.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-02.log"
  assert_file_exists "${repo_dir}/.work/codex/history/checks.round-03.log"
  assert_file_exists "${repo_dir}/.work/codex/history/fix-from-checks.round-01.log"
  assert_file_exists "${repo_dir}/.work/codex/history/review-diff.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-diff.round-02.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-untracked.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-untracked.round-02.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-summary.round-01.txt"
  assert_file_exists "${repo_dir}/.work/codex/history/review-summary.round-02.txt"
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
  assert_file_contains "${repo_dir}/.work/codex/history/review-raw.round-01.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${repo_dir}/.work/codex/history/review-raw.round-02.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${repo_dir}/.work/codex/history/review.round-01.txt" 'accept: no'
  assert_file_contains "${repo_dir}/.work/codex/history/review.round-02.txt" 'accept: yes'
  assert_file_contains "${repo_dir}/.work/codex/review.prompt.md" "You are the review session for issue #${ISSUE_NUMBER}."
  assert_file_contains "${repo_dir}/.work/codex/review.prompt.md" '.work/codex/review.summary.txt'
  assert_file_not_contains "${repo_dir}/.work/codex/review.prompt.md" 'queue smoke review'
  assert_file_not_contains "${repo_dir}/.work/codex/history/review.round-01.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "${repo_dir}/.work/codex/history/review.round-02.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${repo_dir}/.work/codex/history/checks.round-03.log" 'simulated checks pass on round 3'
  assert_equals $'phase\tissue\tround\treasoning\ttokens\tlog' "$(head -n 1 "${repo_dir}/.work/codex/token-usage.tsv")" 'single-issue token usage header'
  assert_file_contains "${repo_dir}/.work/codex/review.raw.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${repo_dir}/.work/codex/review.txt" 'accept: yes'
  assert_file_not_contains "${repo_dir}/.work/codex/review.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${repo_dir}/smoke-target.txt" 'implementation round 1'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'fix checks round 1'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'fix review round 1'
  assert_fixed_line_count "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=high' '3' 'issue-flow write phase reasoning count'
  assert_fixed_line_count "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=medium' '2' 'issue-flow review phase reasoning count'
  assert_equals 'chore: address issue #40' "$("${REAL_GIT}" -C "${repo_dir}" log -1 --pretty=%s)" 'commit message'
  assert_staging_uses_concrete_pathspecs "${state_dir}/git.log"
  assert_file_contains "${state_dir}/gh.log" 'pr edit https://example.test/pr/40 --title Regression Harness Issue --body-file'
  assert_file_not_contains "${state_dir}/gh.log" 'pr create --draft --base main --head issue/40-regression-harness-issue'
  assert_equals "${ISSUE_TITLE}" "$(< "${state_dir}/pr-edit-title.txt")" 'run_issue_flow PR title sync'
  assert_pr_body_common_sections "${state_dir}/pr-edit-body.txt"
  assert_file_contains "${state_dir}/pr-edit-body.txt" "\`smoke-target.txt\`"
  assert_file_contains "${state_dir}/pr-edit-body.txt" "\`pr-only-fixture.txt\`"
  assert_file_contains "${state_dir}/pr-edit-body.txt" 'simulated checks pass on round 3'
  assert_file_contains "${state_dir}/pr-edit-body.txt" 'accept: yes'
  assert_file_contains "${state_dir}/pr-edit-body.txt" 'findings: blocker 0, major 0, minor 0'
  assert_fixed_base_commit_usage 'run_issue_flow'
  assert_review_material_excludes_engine_path
  assert_commit_includes_path HEAD 'smoke-target.txt'
  assert_commit_excludes_internal_paths HEAD
}

run_restart_issue_flow_smoke() {
  local previous_head
  local current_head

  log 'running restart_issue_flow.sh smoke'
  printf 'restart dirty change\n' >> "${repo_dir}/smoke-target.txt"
  printf 'restart untracked vendor change\n' > "${repo_dir}/vendor/restart-untracked.txt"
  clear_command_logs
  reset_flow_counters
  previous_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/restart_issue_flow.sh" --hard
  )

  current_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"
  if [[ "${current_head}" == "${previous_head}" ]]; then
    fail 'restart_issue_flow.sh should create a new commit when rerunning the flow'
  fi

  if grep -Fq 'restart dirty change' "${repo_dir}/smoke-target.txt"; then
    fail 'restart_issue_flow.sh should discard dirty tracked changes outside .work'
  fi

  if [[ -e "${repo_dir}/vendor/restart-untracked.txt" ]]; then
    fail 'restart_issue_flow.sh should clean unrelated untracked files under vendor/'
  fi

  assert_vendor_engine_symlink_present
  assert_file_exists "${repo_dir}/.work/codex/review.txt"
  assert_file_contains "${state_dir}/git.log" 'reset --hard HEAD'
  assert_file_contains "${state_dir}/git.log" 'clean -fd -e vendor/issue_forge -- . :(exclude).work'
  assert_file_contains "${state_dir}/gh.log" 'pr edit https://example.test/pr/40 --title Regression Harness Issue --body-file'
  assert_fixed_base_commit_usage 'restart_issue_flow'
  assert_review_material_excludes_engine_path
  assert_commit_includes_path HEAD 'smoke-target.txt'
  assert_commit_excludes_internal_paths HEAD
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
      "./${FIXTURE_ENGINE_CODEX_PATH}/continue_after_review.sh"
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

  assert_staging_uses_concrete_pathspecs "${state_dir}/git.log"
  assert_file_contains "${state_dir}/gh.log" 'pr edit https://example.test/pr/40 --title Regression Harness Issue --body-file'
  assert_fixed_base_commit_usage 'continue_after_review'
  assert_review_material_excludes_engine_path
  assert_commit_includes_path HEAD 'smoke-target.txt'
  assert_commit_excludes_internal_paths HEAD
  assert_commit_excludes_internal_paths HEAD~1
}

run_issue_queue_fail_fast_smoke() {
  local fail_fast_log="${state_dir}/queue-fail-fast.log"
  local current_branch
  local current_head

  log 'running issue queue fail-fast smoke'
  clear_command_logs
  current_branch="$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)"
  current_head="$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)"

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --review-every 1 "${ISSUE_NUMBER}" "${QUEUE_ISSUE_NUMBER}"
  ) > "${fail_fast_log}" 2>&1; then
    fail 'run_issue_queue.sh should fail before modifying files when multiple batches are requested without --auto-merge'
  fi

  assert_file_contains "${fail_fast_log}" 'Multiple batches require --auto-merge'
  assert_equals "${current_branch}" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'fail-fast current branch'
  assert_equals "${current_head}" "$("${REAL_GIT}" -C "${repo_dir}" rev-parse HEAD)" 'fail-fast HEAD'
  assert_path_not_exists "${repo_dir}/.work/queue"
  if "${REAL_GIT}" -C "${repo_dir}" show-ref --verify --quiet "refs/heads/batch/${ISSUE_NUMBER}-${ISSUE_NUMBER}"; then
    fail 'fail-fast queue should not create the first batch branch'
  fi
  if "${REAL_GIT}" -C "${repo_dir}" show-ref --verify --quiet "refs/heads/batch/${QUEUE_ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}"; then
    fail 'fail-fast queue should not create the second batch branch'
  fi
}

run_queue_state_store_smoke() {
  local store="${state_dir}/queue-state-store" helper="${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/lib/queue_state.sh" log_file="${state_dir}/queue-state-store.log"
  log 'running queue state store smoke'; rm -rf "$store"; mkdir -p "$store"
  if ! QUEUE_STATE_HELPER="$helper" QUEUE_STATE_STORE="$store" bash -c '
set -euo pipefail
CODEX_FLOW_QUEUE_RUNS_DIR="${QUEUE_STATE_STORE}/runs"; ISSUE_FORGE_INTERNAL_QUEUE_TEST_MODE=1; source "${QUEUE_STATE_HELPER}"
: > "${QUEUE_STATE_STORE}/control.guard"; queue_state_configure_guard "${QUEUE_STATE_STORE}/control.guard"
one="$(queue_state_generate_run_id "${CODEX_FLOW_QUEUE_RUNS_DIR}")"; two="$(queue_state_generate_run_id "${CODEX_FLOW_QUEUE_RUNS_DIR}")"
[[ "${one}" != "${two}" && "${one}" =~ ^[A-Za-z0-9._-]+$ ]]
dir_one="${CODEX_FLOW_QUEUE_RUNS_DIR}/${one}"; dir_two="${CODEX_FLOW_QUEUE_RUNS_DIR}/${two}"
queue_state_create_manifest "$dir_one" "$one" 41,40 2 0 0 1 review fix check_fix batch/ main origin/main test/repository
queue_state_create_run "${dir_one}/run.state" "$one" planned
queue_state_create_manifest "$dir_two" "$two" 41,40 2 0 0 1 review fix check_fix batch/ main origin/main test/repository
queue_state_create_run "${dir_two}/run.state" "$two" planned
[[ "$(queue_state_read_field "${dir_one}/manifest.state" manifest issues)" == 41,40 && "$dir_one" != "$dir_two" ]]
https_identity="$(queue_state_canonical_repository_identity https://user:secret@github.example/owner/repository.git)"
ssh_identity="$(queue_state_canonical_repository_identity git@github.example:owner/repository.git)"
[[ "$https_identity" == github.example/owner/repository && "$https_identity" == "$ssh_identity" && "$https_identity" != *secret* ]]
[[ "$(queue_state_canonical_repository_identity https://github.example:443/owner/repository.git)" == "$https_identity" ]]
[[ "$(queue_state_canonical_repository_identity http://github.example:80/owner/repository.git)" == "$https_identity" ]]
[[ "$(queue_state_canonical_repository_identity ssh://git@github.example:22/owner/repository.git)" == "$https_identity" ]]
[[ "$(queue_state_canonical_repository_identity https://user:secret@github.example:8443/owner/repository.git)" == github.example:8443/owner/repository ]]
[[ "$(queue_state_canonical_repository_identity ssh://git@github.example:2222/owner/repository.git)" == github.example:2222/owner/repository ]]
[[ "$(queue_state_canonical_repository_identity https://github.example/other/repository.git)" != "$https_identity" ]]
if QUEUE_STATE_TEST_INTERRUPT_BEFORE_MV=1 queue_state_transition "${dir_one}/run.state" run "run ${one}" planned running; then exit 10; fi
grep -Fxq "state$(printf "\\t")planned" "${dir_one}/run.state"; compgen -G "${dir_one}/.queue-state.tmp.*" >/dev/null
queue_state_transition "${dir_one}/run.state" run "run ${one}" planned running
! compgen -G "${dir_one}/.queue-state.tmp.*" >/dev/null
before="$(cksum < "${dir_one}/run.state")"
if queue_state_transition "${dir_one}/run.state" run "run ${one}" planned completed; then exit 11; fi
[[ "$(cksum < "${dir_one}/run.state")" == "$before" ]]
queue_state_create_batch "${dir_one}/batch.state" "$one" batch-41-40 41 40 batch/41-40 .work/queue/batches/batch-41-40
queue_state_create_issue "${dir_one}/issue.state" "$one" batch-41-40 41
issue_before="$(cksum < "${dir_one}/issue.state")"
if queue_state_update_issue "${dir_one}/issue.state" Issue-41 planned acknowledged 0123456789012345678901234567890123456789 .work/archive 0123456789012345678901234567890123456789012345678901234567890123; then exit 12; fi
[[ "$(cksum < "${dir_one}/issue.state")" == "$issue_before" ]]
if queue_state_transition "${dir_one}/batch.state" batch batch-41-40 planned completed; then exit 13; fi
sed "s/^state$(printf "\\t")planned$/state$(printf "\\t")acknowledged/" "${dir_one}/issue.state" > "${QUEUE_STATE_STORE}/incoherent-issue.state"
if queue_state_validate_file "${QUEUE_STATE_STORE}/incoherent-issue.state" issue; then exit 14; fi
queue_state_publish_pointer "${QUEUE_STATE_STORE}/current" "$one" owner-token 1
printf "schema_version\t3\nrun_id\t%s\nstate\tcompleted\nupdated_at\t2026-08-06T00:00:00Z\n" "$one" > "${QUEUE_STATE_STORE}/candidate"
deny_owner() { return 1; }
invoke_denied() {
  local context="$1"; shift
  case "$context" in
    or) "$@" || true ;;
    if) if "$@"; then exit 21; fi ;;
    not) if ! "$@"; then :; else exit 22; fi ;;
  esac
}

queue_state_set_owner_assertion deny_owner
for context in or if not; do
  snapshot="$(find "$QUEUE_STATE_STORE" -type f ! -name control.guard -printf "%p " -exec cksum {} \; | LC_ALL=C sort)"
  invoke_denied "$context" queue_state_publish_file "${dir_one}/run.state" run "${QUEUE_STATE_STORE}/candidate"
  invoke_denied "$context" queue_state_read_field "${dir_one}/run.state" run state
  invoke_denied "$context" queue_state_transition "${dir_one}/run.state" run "run ${one}" running completed
  invoke_denied "$context" queue_state_update_batch "${dir_one}/batch.state" batch-41-40 planned branch_ready 0123456789012345678901234567890123456789
  invoke_denied "$context" queue_state_update_issue "${dir_one}/issue.state" Issue-41 planned leased none none
  invoke_denied "$context" queue_state_set_issue_base "${dir_one}/issue.state" planned 0123456789012345678901234567890123456789
  invoke_denied "$context" queue_state_publish_pointer "${QUEUE_STATE_STORE}/current" "$one" replacement-token 2
  invoke_denied "$context" queue_state_remove_pointer_if_matches "${QUEUE_STATE_STORE}/current" "$one" owner-token 1
  [[ "$(find "$QUEUE_STATE_STORE" -type f ! -name control.guard -printf "%p " -exec cksum {} \; | LC_ALL=C sort)" == "$snapshot" ]]
  ! find "$QUEUE_STATE_STORE" -type f -name ".queue-state.tmp.*" -print -quit | grep -q .
done
queue_state_set_owner_assertion ''
valid="${dir_one}/run.state"
for kind in malformed duplicate missing unknown; do
  candidate="${QUEUE_STATE_STORE}/${kind}.state"
  case "$kind" in
    malformed) printf "schema_version\\t1\\nrun_id\\tbad/id\\nstate\\tplanned\\nupdated_at\\t2026-08-06T00:00:00Z\\n" > "$candidate" ;;
    duplicate) { cat "$valid"; printf "state\\trunning\\n"; } > "$candidate" ;;
    missing) sed "/^state/d" "$valid" > "$candidate" ;;
    unknown) { cat "$valid"; printf "surprise\\tvalue\\n"; } > "$candidate" ;;
  esac
  if queue_state_validate_file "$candidate" run; then exit 12; fi
done
target="${QUEUE_STATE_STORE}/bad-target.state"
mkdir "$target"
if queue_state_publish_file "$target" run "${QUEUE_STATE_STORE}/candidate"; then exit 13; fi
! find "$target" -name ".queue-state.tmp.*" -print -quit | grep -q .
rmdir "$target"
ln -s "$valid" "$target"
if queue_state_read_field "$target" run state; then exit 14; fi
rm "$target"
mkfifo "$target"
if queue_state_publish_file "$target" run "${QUEUE_STATE_STORE}/candidate"; then exit 15; fi
rm "$target"
ln "$valid" "$target"
if queue_state_read_field "$target" run state; then exit 16; fi
rm "$target"
' > "$log_file" 2>&1; then cat "$log_file" >&2; fail 'queue state store scenarios should succeed'; fi
  assert_file_contains "$log_file" "expected state 'planned', actual state 'running', requested target state 'completed'"
  assert_file_contains "$log_file" 'Duplicate run state key'
  assert_file_contains "$log_file" 'Missing required run state key'
  assert_file_contains "$log_file" 'Unknown run state key'
  assert_file_contains "$log_file" 'Unsupported run schema version: 1'
  assert_file_contains "$log_file" 'Queue singleton path is not a regular file'
  assert_file_contains "$log_file" 'Queue singleton path must not be a symlink'
  assert_file_contains "$log_file" 'Queue singleton path has unexpected hard-link count'
}

run_queue_private_environment_smoke() {
  local log_file assignment emitted_run before_snapshot after_snapshot config_backup pause preflight_pid attempt
  local -a injections=(
    'QUEUE_STATE_GUARD_DEPTH=1'
    'QUEUE_STATE_GUARD_FD=9'
    'QUEUE_STATE_ASSERT_IN_PROGRESS=1'
    'QUEUE_STATE_GUARD_DEPTH=1 QUEUE_STATE_GUARD_FD=9'
    'QUEUE_STATE_GUARD_DEPTH=1 QUEUE_STATE_GUARD_FD=9 QUEUE_STATE_ASSERT_IN_PROGRESS=1'
    'ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1'
  )
  local -a injection_words=()
  log 'running queue private-environment and preflight-signal smoke'
  clear_command_logs; reset_flow_counters
  for assignment in "${injections[@]}"; do
    read -r -a injection_words <<< "$assignment"
    log_file="${state_dir}/queue-private-$(printf '%s' "$assignment" | tr ' =_' '---').log"
    if (
      cd "$repo_dir"
      env "${injection_words[@]}" PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 \
        CODEX_FLOW_QUEUE_FAILPOINT=after_minimal_run_publication \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99
    ) > "$log_file" 2>&1; then
      fail "private queue variable injection should stop only at the requested failpoint: ${assignment}"
    fi
    assert_file_contains "$log_file" 'Queue failpoint triggered: after_minimal_run_publication'
    assert_file_not_contains "$log_file" 'command not found'
    emitted_run="$(sed -n 's/.*--resume \([A-Za-z0-9._-]*\).*/\1/p' "$log_file" | head -n 1)"
    [[ -n "$emitted_run" ]] || fail "private queue variable injection emitted no recovery command: ${assignment}"
    assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/manifest.state"
    assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/run.state"
  done
  assert_equals 0 "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'private-variable injection Issue fetch count'
  assert_equals 0 "$(awk '$1 == "switch" || $1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" 'private-variable injection Git mutation count'

  if (cd "$repo_dir"; env ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG=1 bash -c \
      'source vendor/issue_forge/tools/codex/lib/config.sh') > "${state_dir}/queue-private-config-bootstrap.log" 2>&1; then
    fail 'a caller outside run_issue_queue.sh bypassed full consumer configuration validation'
  fi
  assert_file_contains "${state_dir}/queue-private-config-bootstrap.log" \
    'Private minimal queue configuration bootstrap is available only to run_issue_queue.sh'

  before_snapshot="$(queue_tree_snapshot "${repo_dir}/.work/queue")"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_FAILPOINT=after_minimal_run_publication \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99) > "${state_dir}/queue-test-hook-production.log" 2>&1; then
    fail 'production queue must reject a failpoint without explicit test mode'
  fi
  assert_file_contains "${state_dir}/queue-test-hook-production.log" 'requires CODEX_FLOW_QUEUE_TEST_MODE=1'
  after_snapshot="$(queue_tree_snapshot "${repo_dir}/.work/queue")"
  assert_equals "$before_snapshot" "$after_snapshot" 'production test-hook rejection queue snapshot'

  config_backup="$(mktemp)"
  cp "${repo_dir}/.issue_forge/project.sh" "$config_backup"
  printf '\nreadonly QUEUE_STATE_GUARD_DEPTH=1\n' >> "${repo_dir}/.issue_forge/project.sh"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99) > "${state_dir}/queue-readonly-private.log" 2>&1; then
    fail 'readonly private queue injection must fail'
  fi
  cp "$config_backup" "${repo_dir}/.issue_forge/project.sh"
  assert_file_contains "${state_dir}/queue-readonly-private.log" 'Consumer config must not set private queue variable QUEUE_STATE_GUARD_DEPTH'
  after_snapshot="$(queue_tree_snapshot "${repo_dir}/.work/queue")"
  assert_equals "$before_snapshot" "$after_snapshot" 'readonly private-variable rejection queue snapshot'

  pause="${state_dir}/queue-preflight-signal-pause"
  rm -rf "$pause"; mkdir -p "$pause"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" \
      CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_minimal_run_publication CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=preflight-term \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99
  ) > "${state_dir}/queue-preflight-term.log" 2>&1 & preflight_pid=$!
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    [[ -f "$pause/paused.after_minimal_run_publication.preflight-term" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.after_minimal_run_publication.preflight-term" ]] || fail 'preflight candidate did not reach the signal pause'
  kill -TERM "$preflight_pid"
  if wait "$preflight_pid"; then fail 'SIGTERM-interrupted preflight unexpectedly succeeded'; fi
  assert_file_contains "${state_dir}/queue-preflight-term.log" 'resume with:'
  emitted_run="$(sed -n 's/.*--resume \([A-Za-z0-9._-]*\).*/\1/p' "${state_dir}/queue-preflight-term.log" | head -n 1)"
  assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/manifest.state"
  assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/run.state"
  assert_path_not_exists "${repo_dir}/.work/queue/lease.lock"
}

run_queue_full_contention_smoke() {
  local barrier="${state_dir}/queue-contention-barrier" pause="${state_dir}/queue-contention-pause"
  local first_log="${state_dir}/queue-contention-first.log" second_log="${state_dir}/queue-contention-second.log"
  local first_pid second_pid winner loser winner_label owner_count issue_fetch_count gh_call_count git_mutation_count attempt
  local authoritative_run emitted_run winner_log loser_log
  log 'running full queue runner contention smoke'
  rm -rf "$barrier" "$pause"; mkdir -p "$barrier" "$pause"
  clear_command_logs; reset_flow_counters
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 QUEUE_STATE_GUARD_DEPTH=1 QUEUE_STATE_GUARD_FD=9 QUEUE_STATE_ASSERT_IN_PROGRESS=1 \
      CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch \
      CODEX_FLOW_QUEUE_TEST_BARRIER_DIR="$barrier" CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" \
      CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=first \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "${QUEUE_ISSUE_NUMBER}"
  ) > "$first_log" 2>&1 & first_pid=$!
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 QUEUE_STATE_GUARD_DEPTH=1 QUEUE_STATE_GUARD_FD=9 QUEUE_STATE_ASSERT_IN_PROGRESS=1 \
      CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch \
      CODEX_FLOW_QUEUE_TEST_BARRIER_DIR="$barrier" CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" \
      CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=second \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "${QUEUE_ISSUE_NUMBER}"
  ) > "$second_log" 2>&1 & second_pid=$!
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    [[ -f "$barrier/ready.lease_acquire.first" && -f "$barrier/ready.lease_acquire.second" ]] && break
    sleep 0.01
  done
  [[ -f "$barrier/ready.lease_acquire.first" && -f "$barrier/ready.lease_acquire.second" ]] || fail 'queue contention runners did not reach the acquisition barrier'
  touch "$barrier/release.lease_acquire"
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    compgen -G "$pause/paused.after_acquire.*" >/dev/null && break
    sleep 0.01
  done
  if [[ -f "$pause/paused.after_acquire.first" ]]; then
    winner="$first_pid"; loser="$second_pid"; winner_label=first
  elif [[ -f "$pause/paused.after_acquire.second" ]]; then
    winner="$second_pid"; loser="$first_pid"; winner_label=second
  else
    fail 'queue contention produced no lease owner'
  fi
  if wait "$loser"; then fail 'queue contention loser unexpectedly succeeded'; fi
  owner_count="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state' | wc -l)"
  assert_equals 1 "$owner_count" 'complete authoritative lease owner count during contention'
  authoritative_run="$(awk -F '\t' '$1 == "run_id" { print $2 }' "$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')")"
  if [[ "$winner_label" == first ]]; then winner_log="$first_log"; loser_log="$second_log"; else winner_log="$second_log"; loser_log="$first_log"; fi
  assert_file_not_contains "$winner_log" 'resume with:'
  assert_equals 1 "$(grep -Fc -- '--resume ' "$loser_log")" 'contention loser recovery command count'
  assert_file_contains "$loser_log" "--resume ${authoritative_run}"
  assert_file_not_contains "$first_log" 'command not found'
  assert_file_not_contains "$second_log" 'command not found'
  touch "$pause/release.after_acquire.${winner_label}"
  if wait "$winner"; then fail 'queue contention winner should stop at the deterministic post-acquire failpoint'; fi
  while IFS= read -r emitted_run; do
    [[ -n "$emitted_run" ]] || continue
    assert_equals "$authoritative_run" "$emitted_run" 'contention emitted resume run identity'
    assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/manifest.state"
    assert_file_exists "${repo_dir}/.work/queue/runs/${emitted_run}/run.state"
  done < <(sed -n 's/.*--resume \([A-Za-z0-9._-]*\).*/\1/p' "$first_log" "$second_log")
  issue_fetch_count="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  gh_call_count="$(awk 'NF { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  git_mutation_count="$(awk '$1 == "switch" || $1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  assert_equals 0 "$issue_fetch_count" 'contention pre-boundary Issue fetch count'
  assert_equals 0 "$gh_call_count" 'contention pre-boundary GitHub call count'
  assert_equals 0 "$git_mutation_count" 'contention pre-boundary repository mutation count'
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume current) > "${state_dir}/queue-contention-resume.log" 2>&1; then
    cat "${state_dir}/queue-contention-resume.log" >&2; fail 'contention winner run should resume deterministically'
  fi
  rm -f "${state_dir}/batch-pr-url.txt"
}

run_queue_acquisition_crash_smoke() {
  local first_log="${state_dir}/queue-claim-crash.log" owner_log="${state_dir}/queue-owner-sigkill.log" run_id other_run
  local pause="${state_dir}/queue-owner-sigkill-pause" owner_job owner_record owner_pid owner_start owner_token owner_generation
  local replacement_record replacement_token replacement_generation attempt issue_fetch_count branch_create_count push_count pr_count merge_count
  log 'running queue acquisition crash-window smoke'
  clear_command_logs; reset_flow_counters
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
      CODEX_FLOW_QUEUE_FAILPOINT=after_exclusive_claim_before_owner_record \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "${ISSUE_NUMBER}") > "$first_log" 2>&1; then
    fail 'exclusive-claim failpoint should stop the queue'
  fi
  run_id="$(sed -n 's/^\[queue\] run ID: //p' "$first_log" | head -n 1)"
  [[ -n "$run_id" && -f "${repo_dir}/.work/queue/runs/${run_id}/manifest.state" && -f "${repo_dir}/.work/queue/runs/${run_id}/run.state" ]] || fail 'claim crash must retain a resumable minimal run'
  [[ -d "${repo_dir}/.work/queue/lease.lock" ]] || fail 'claim crash should expose the tested empty lease boundary'
  assert_equals 0 "$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state' | wc -l)" 'empty claim owner count'

  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 \
      CODEX_FLOW_QUEUE_FAILPOINT=after_minimal_run_publication \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "${QUEUE_ISSUE_NUMBER}") > "${state_dir}/queue-other-candidate.log" 2>&1; then
    fail 'different-run candidate setup should stop after minimal publication'
  fi
  other_run="$(sed -n 's/^\[queue\] run ID: //p' "${state_dir}/queue-other-candidate.log" | head -n 1)"
  [[ -n "$other_run" && "$other_run" != "$run_id" ]] || fail 'different-run candidate setup did not publish a distinct run'

  rm -rf "$pause"; mkdir -p "$pause"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=sigkill-owner \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id"
  ) > "$owner_log" 2>&1 & owner_job=$!
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    [[ -f "$pause/paused.after_acquire.sigkill-owner" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.after_acquire.sigkill-owner" ]] || fail 'queue owner did not pause after complete owner publication'
  owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
  owner_start="$(awk -F '\t' '$1 == "process_start" { print $2 }' "$owner_record")"
  owner_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$owner_record")"
  owner_generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$owner_record")"
  assert_equals 1 "$owner_generation" 'initial complete owner generation before SIGKILL'
  assert_equals "$owner_start" "$(awk '{print $22}' "/proc/${owner_pid}/stat")" 'initial complete owner process-start identity'
  kill -9 "$owner_pid"
  if wait "$owner_job" 2>/dev/null; then fail 'SIGKILLed complete owner unexpectedly exited successfully'; fi
  assert_file_exists "$owner_record"
  assert_file_contains "$owner_record" "owner_token$(printf '\t')${owner_token}"
  assert_file_contains "$owner_record" "lease_generation$(printf '\t')1"

  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99) > "${state_dir}/queue-stale-owner-fresh.log" 2>&1; then
    fail 'fresh run must refuse a complete stale owner'
  fi
  assert_file_contains "${state_dir}/queue-stale-owner-fresh.log" "--resume ${run_id}"
  assert_equals 1 "$(grep -Fc -- '--resume ' "${state_dir}/queue-stale-owner-fresh.log")" 'fresh stale-owner recovery command count'
  assert_file_not_contains "${state_dir}/queue-stale-owner-fresh.log" "--resume ${other_run}"
  assert_file_not_contains "${state_dir}/queue-stale-owner-fresh.log" 'command not found'
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$other_run") > "${state_dir}/queue-stale-owner-other-run.log" 2>&1; then
    fail 'different-run resume must refuse a complete stale owner'
  fi
  assert_file_contains "${state_dir}/queue-stale-owner-other-run.log" "conflicts with requested run ${other_run}"

  rm -f "$pause/paused.after_acquire.sigkill-owner"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=sigkill-recovery \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id"
  ) > "${state_dir}/queue-claim-resume.log" 2>&1 & owner_job=$!
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    [[ -f "$pause/paused.after_acquire.sigkill-recovery" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.after_acquire.sigkill-recovery" ]] || fail 'same-run stale-owner recovery did not publish its replacement owner'
  replacement_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  replacement_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$replacement_record")"
  replacement_generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$replacement_record")"
  [[ "$replacement_token" != "$owner_token" ]] || fail 'dead-owner recovery must rotate the owner token'
  assert_equals 2 "$replacement_generation" 'dead-owner recovery generation'
  touch "$pause/release.after_acquire.sigkill-recovery"
  if ! wait "$owner_job"; then
    cat "${state_dir}/queue-claim-resume.log" >&2
    fail 'same-run recovery after actual SIGKILL should complete'
  fi
  issue_fetch_count="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  branch_create_count="$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  push_count="$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  pr_count="$(awk '$1 == "pr" && ($2 == "create" || $2 == "edit") { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  merge_count="$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  assert_equals 1 "$issue_fetch_count" 'actual stale-owner recovery Issue fetch count'
  assert_equals 1 "$branch_create_count" 'actual stale-owner recovery branch creation count'
  assert_equals 1 "$push_count" 'actual stale-owner recovery push count'
  assert_equals 1 "$pr_count" 'actual stale-owner recovery PR mutation count'
  assert_equals 0 "$merge_count" 'actual stale-owner recovery merge count'
  assert_file_contains "$owner_log" 'recovering incomplete empty queue lease claim'
  assert_file_not_contains "$owner_log" 'command not found'
  assert_path_not_exists "${repo_dir}/.work/queue/lease.lock"
  rm -f "${state_dir}/batch-pr-url.txt"
}

run_queue_legacy_control_plane_smoke() {
  local lease_log="${state_dir}/queue-legacy-lease.log" current_log="${state_dir}/queue-legacy-current.log"
  log 'running legacy queue control-plane rejection smoke'
  mkdir -p "${repo_dir}/.work/queue"
  printf 'schema_version\t1\nrun_id\tlegacy\n' > "${repo_dir}/.work/queue/lease.state"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "${ISSUE_NUMBER}") > "$lease_log" 2>&1; then
    fail 'legacy v1 lease artifact must be rejected'
  fi
  assert_file_contains "$lease_log" 'Unsupported legacy queue lease schema/path'
  assert_file_not_contains "$lease_log" 'command not found'
  rm -f "${repo_dir}/.work/queue/lease.state"
  printf 'legacy-run\n' > "${repo_dir}/.work/queue/current"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume current) > "$current_log" 2>&1; then
    fail 'legacy v1 current artifact must be rejected'
  fi
  assert_file_contains "$current_log" 'Unsupported legacy queue current schema v1'
  assert_file_not_contains "$current_log" 'command not found'
  rm -f "${repo_dir}/.work/queue/current"
}

run_queue_singleton_path_type_smoke() {
  local current="${repo_dir}/.work/queue/current" git_common guard_dir active cleanup_marker guard backup log_file before after kind
  log 'running queue singleton path-type rejection smoke'
  git_common="$("${REAL_GIT}" -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)"
  guard_dir="${git_common}/issue-forge/queue"; active="${guard_dir}/active-process.state"
  cleanup_marker="${guard_dir}/completion-cleanup.state"; guard="${guard_dir}/control.guard"
  mkdir -p "${repo_dir}/.work/queue" "$guard_dir"
  for kind in directory symlink fifo; do
    rm -rf -- "$current"
    case "$kind" in
      directory) mkdir "$current" ;;
      symlink) ln -s runs "$current" ;;
      fifo) mkfifo "$current" ;;
    esac
    before="$(find "${repo_dir}/.work/queue" -type f -printf '%p ' -exec cksum {} \; | LC_ALL=C sort)"
    clear_command_logs; reset_flow_counters
    log_file="${state_dir}/queue-current-${kind}.log"
    if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 53) > "$log_file" 2>&1; then
      fail "malformed current ${kind} unexpectedly allowed queue startup"
    fi
    case "$kind" in
      directory)
        assert_file_contains "$log_file" 'Queue singleton path is not a regular file'
        if find "$current" -name '.queue-state.tmp.*' -print -quit | grep -q .; then fail 'directory current captured a sibling temporary file'; fi
        ;;
      symlink) assert_file_contains "$log_file" 'Queue singleton path must not be a symlink' ;;
      fifo) assert_file_contains "$log_file" 'Queue singleton path is not a regular file' ;;
    esac
    after="$(find "${repo_dir}/.work/queue" -type f -printf '%p ' -exec cksum {} \; | LC_ALL=C sort)"
    assert_equals "$before" "$after" "malformed current ${kind} state checksum"
    assert_equals 0 "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" "malformed current ${kind} Issue side-effect count"
    assert_equals 0 "$(awk '$1 == "switch" || $1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" "malformed current ${kind} Git side-effect count"
  done
  rm -rf -- "$current"

  mkdir "$active"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 54) > "${state_dir}/queue-active-directory.log" 2>&1; then
    fail 'directory active-process singleton unexpectedly allowed startup'
  fi
  assert_file_contains "${state_dir}/queue-active-directory.log" 'Invalid active queue process path'
  rmdir "$active"
  ln -s "$current" "$active"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 54) > "${state_dir}/queue-active-symlink.log" 2>&1; then
    fail 'symlink active-process singleton unexpectedly allowed startup'
  fi
  assert_file_contains "${state_dir}/queue-active-symlink.log" 'Queue singleton path must not be a symlink'
  rm "$active"

  mkdir "$cleanup_marker"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 63) > "${state_dir}/queue-cleanup-marker-directory.log" 2>&1; then
    fail 'directory completion-cleanup singleton unexpectedly allowed startup'
  fi
  assert_file_contains "${state_dir}/queue-cleanup-marker-directory.log" 'Invalid completion cleanup path'
  rmdir "$cleanup_marker"
  ln -s "$current" "$cleanup_marker"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 63) > "${state_dir}/queue-cleanup-marker-symlink.log" 2>&1; then
    fail 'symlink completion-cleanup singleton unexpectedly allowed startup'
  fi
  assert_file_contains "${state_dir}/queue-cleanup-marker-symlink.log" 'Queue singleton path must not be a symlink'
  rm "$cleanup_marker"

  backup="${guard}.singleton-smoke-backup"
  mv "$guard" "$backup"; mkdir "$guard"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 55) > "${state_dir}/queue-guard-directory.log" 2>&1; then
    fail 'directory control.guard unexpectedly allowed startup'
  fi
  assert_file_contains "${state_dir}/queue-guard-directory.log" 'Queue serialization guard is not the expected regular file'
  rmdir "$guard"; mv "$backup" "$guard"
}

run_issue_queue_strict_issue_review_smoke() {
  local batch_dir="${repo_dir}/.work/queue/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}"
  local queue_log="${state_dir}/queue-strict-review.log" run_id pause queue_job owner_record owner_pid owner_token owner_generation attempt
  local issue_fetch_before branch_create_before push_before pr_before merge_before

  log 'running issue queue strict per-issue review smoke'
  clear_command_logs
  reset_flow_counters

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 \
      CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW=0 \
      CODEX_FLOW_QUEUE_FAILPOINT=after_minimal_run_publication \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --review-every 2 "${ISSUE_NUMBER}" "${QUEUE_ISSUE_NUMBER}"
  ) > "${state_dir}/queue-after-manifest.log" 2>&1; then
    fail 'queue after-manifest failpoint should interrupt the new run'
  fi
  assert_file_contains "${state_dir}/queue-after-manifest.log" 'Queue failpoint triggered: after_minimal_run_publication'
  assert_file_contains "${state_dir}/queue-after-manifest.log" 'resume with:'
  run_id="$(sed -n 's/^\[queue\] run ID: //p' "${state_dir}/queue-after-manifest.log" | head -n 1)"
  assert_path_not_exists "${repo_dir}/.work/queue/current"
  assert_path_not_exists "${repo_dir}/.work/queue/lease.lock"
  cp "${repo_dir}/.work/queue/runs/${run_id}/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}/issues/${QUEUE_ISSUE_NUMBER}.state" "${state_dir}/missing-entity.saved"
  rm "${repo_dir}/.work/queue/runs/${run_id}/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}/issues/${QUEUE_ISSUE_NUMBER}.state"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-partial-reconcile.log" 2>&1; then
    fail 'resume must reject a missing authoritative Issue entity'
  fi
  assert_file_contains "${state_dir}/queue-partial-reconcile.log" 'Missing queue singleton state file'
  cp "${state_dir}/missing-entity.saved" "${repo_dir}/.work/queue/runs/${run_id}/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}/issues/${QUEUE_ISSUE_NUMBER}.state"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-partial-reconcile-restored.log" 2>&1; then
    fail 'restored graph should stop only at the requested pre-Issue failpoint'
  fi
  assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}/issues/${ISSUE_NUMBER}.state" $'state\tplanned'
  assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/batches/batch-${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}/issues/${QUEUE_ISSUE_NUMBER}.state" $'state\tplanned'
  assert_file_contains "${repo_dir}/.work/queue/current" "run_id$(printf '\t')${run_id}"

  pause="${state_dir}/queue-completion-sigkill-pause"
  rm -rf "$pause"; mkdir -p "$pause"
  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW=0 \
      CODEX_FLOW_LIGHT_ISSUE_REVIEW=1 \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_run_completed_before_current_cleanup \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=completion-sigkill \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume current
  ) > "${queue_log}" 2>&1 & queue_job=$!
  for ((attempt = 0; attempt < 2000; attempt += 1)); do
    [[ -f "$pause/paused.after_run_completed_before_current_cleanup.completion-sigkill" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.after_run_completed_before_current_cleanup.completion-sigkill" ]] || fail 'queue did not reach durable completed-state SIGKILL boundary'
  owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
  owner_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$owner_record")"
  owner_generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$owner_record")"
  assert_equals 1 "$owner_generation" 'completed SIGKILL initial lease generation'
  issue_fetch_before="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  branch_create_before="$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  push_before="$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  pr_before="$(awk '$1 == "pr" && $2 == "create" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  merge_before="$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  printf 'issue_fetch\t%s\nbranch_create\t%s\npush\t%s\npr_create\t%s\nmerge\t%s\n' \
    "$issue_fetch_before" "$branch_create_before" "$push_before" "$pr_before" "$merge_before" \
    > "${state_dir}/completion-side-effect-counts.before"
  kill -9 "$owner_pid"
  wait "$queue_job" 2>/dev/null || true
  kill -0 "$owner_pid" 2>/dev/null && fail 'completed queue owner survived kill -9'
  assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/run.state" $'state\tcompleted'
  assert_file_exists "${repo_dir}/.work/queue/current"
  assert_file_exists "$owner_record"
  assert_file_contains "$owner_record" "owner_token$(printf '\t')${owner_token}"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume current) > "${state_dir}/queue-stale-completed-current.log" 2>&1; then
    fail 'stale completed current should finalize without rerunning work'
  fi
  assert_file_contains "${state_dir}/queue-stale-completed-current.log" 'control plane finalized without rerunning work'
  assert_path_not_exists "${repo_dir}/.work/queue/current"
  assert_path_not_exists "${repo_dir}/.work/queue/lease.lock"
  assert_file_exists "${repo_dir}/.work/queue/lease.finalized.${owner_generation}.${owner_token}/owner.${owner_token}.state"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-stale-completed-explicit.log" 2>&1; then
    fail 'explicit completed-run finalization should be idempotent'
  fi
  assert_file_contains "${state_dir}/queue-stale-completed-explicit.log" 'control plane is already finalized'
  assert_file_not_contains "${state_dir}/queue-stale-completed-current.log" 'resume with:'
  assert_file_not_contains "${state_dir}/queue-stale-completed-explicit.log" 'resume with:'
  assert_equals "$issue_fetch_before" "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'completed finalization Issue fetch count'
  assert_equals "$branch_create_before" "$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" 'completed finalization branch creation count'
  assert_equals "$push_before" "$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" 'completed finalization push count'
  assert_equals "$pr_before" "$(awk '$1 == "pr" && $2 == "create" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'completed finalization PR count'
  assert_equals "$merge_before" "$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'completed finalization merge count'
  printf 'issue_fetch\t%s\nbranch_create\t%s\npush\t%s\npr_create\t%s\nmerge\t%s\n' \
    "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" \
    "$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" \
    "$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" \
    "$(awk '$1 == "pr" && $2 == "create" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" \
    "$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" \
    > "${state_dir}/completion-side-effect-counts.after"
  cmp -s "${state_dir}/completion-side-effect-counts.before" "${state_dir}/completion-side-effect-counts.after" || \
    fail 'completed finalization changed byte-for-byte side-effect counters'

  assert_equals "batch/${ISSUE_NUMBER}-${QUEUE_ISSUE_NUMBER}" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'strict queue batch branch'
  assert_file_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/review.prompt.md" "You are the review session for issue #${ISSUE_NUMBER}."
  assert_file_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/review.prompt.md" "You are the review session for issue #${QUEUE_ISSUE_NUMBER}."
  assert_file_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/review.prompt.md" 'Focus on correctness, scope, regressions, repository rules, and doc consistency.'
  assert_file_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/review.prompt.md" 'Focus on correctness, scope, regressions, repository rules, and doc consistency.'
  assert_file_not_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/review.prompt.md" 'queue smoke review'
  assert_file_not_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/review.prompt.md" 'queue smoke review'
  assert_file_contains "${batch_dir}/batch-review.prompt.md" 'strict batch review session'
  assert_file_not_contains "${batch_dir}/batch-review.prompt.md" 'queue smoke review'
  assert_file_contains "${queue_log}" 'publish skipped because CODEX_FLOW_SKIP_PUBLISH is set'
  assert_commit_includes_path HEAD 'smoke-target.txt'
  assert_commit_excludes_internal_paths HEAD
}

run_queue_completion_cleanup_transaction_smoke() {
  local boundary issue label pause owner_job finalizer_job owner_record owner_pid run_id owner_token owner_generation
  local marker active_file audit retry_target index attempt project_backup b_run b_record b_token
  local record
  local -a boundaries=(
    after_completion_cleanup_marker
    after_completed_lease_retirement
    after_completed_current_batch_removal
    before_completed_current_removal
    after_completed_current_removal
    before_completion_cleanup_terminal
  )
  local -a issues=(56 57 58 59 60 61)
  local -a config_overrides=(
    $'CODEX_FLOW_BASE_BRANCH=\'changed-after-completion\'\nCODEX_FLOW_BASE_REF=\'origin/changed-after-completion\'\nCODEX_FLOW_PROMPTS_DIR=\'/missing/completion-only-prompts\''
    "CODEX_FLOW_QUEUE_REVIEW_EVERY=0"
    "CODEX_FLOW_BATCH_REVIEW_REASONING=''"
    "CODEX_FLOW_CHECKS_COMMAND=''"
    "CODEX_FLOW_PROMPTS_DIR=''"
    "CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS=0"
  )
  local -a config_diagnostics=(
    'Missing prompt template'
    'queue review interval must be a positive integer: 0'
    'Missing required consumer config: batch review reasoning'
    'Missing required consumer config: checks command'
    'Missing required consumer config: prompts directory'
    'auto-merge wait seconds must be a positive integer: 0'
  )

  log 'running completed cleanup transaction SIGKILL smoke'
  marker="$(${REAL_GIT} -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)/issue-forge/queue/completion-cleanup.state"
  active_file="$(dirname "$marker")/active-process.state"
  project_backup="${state_dir}/completion-project.sh"
  cp "${repo_dir}/.issue_forge/project.sh" "$project_backup"

  for index in 0 1 2 3 4 5; do
    boundary="${boundaries[$index]}"; issue="${issues[$index]}"; label="completion-${index}"
    pause="${state_dir}/queue-${boundary}"
    rm -rf "$pause"; mkdir -p "$pause"
    rm -f "${state_dir}/batch-pr-url.txt"
    clear_command_logs; reset_flow_counters
    (
      cd "$repo_dir"
      exec env PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
        CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_run_completed_before_current_cleanup \
        CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL="${label}-owner" \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue"
    ) > "${state_dir}/${label}.owner.log" 2>&1 & owner_job=$!
    for ((attempt = 0; attempt < 3000; attempt += 1)); do
      [[ -f "$pause/paused.after_run_completed_before_current_cleanup.${label}-owner" ]] && break
      sleep 0.01
    done
    [[ -f "$pause/paused.after_run_completed_before_current_cleanup.${label}-owner" ]] || \
      fail "completed owner did not reach pre-cleanup boundary for ${boundary}"
    owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
    owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
    run_id="$(awk -F '\t' '$1 == "run_id" { print $2 }' "$owner_record")"
    owner_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$owner_record")"
    owner_generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$owner_record")"
    assert_equals 1 "$owner_generation" "${boundary} completed owner generation"
    kill -9 "$owner_pid"
    wait "$owner_job" 2>/dev/null || true
    kill -0 "$owner_pid" 2>/dev/null && fail "completed owner survived kill -9 before ${boundary}"
    assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/run.state" $'state\tcompleted'

    {
      cat "$project_backup"
      printf '%s\n' "${config_overrides[$index]}"
    } > "${repo_dir}/.issue_forge/project.sh"

    queue_side_effect_snapshot > "${state_dir}/${label}.side-effects.before"
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'issue_fetch\t1'
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'implementation\t1'
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'branch_switch\t1'
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'push\t1'
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'pr_mutation\t1'
    assert_file_contains "${state_dir}/${label}.side-effects.before" $'merge\t0'

    (
      cd "$repo_dir"
      exec env PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 \
        CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT="$boundary" \
        CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL="${label}-finalizer" \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id"
    ) > "${state_dir}/${label}.finalizer.log" 2>&1 & finalizer_job=$!
    for ((attempt = 0; attempt < 2000; attempt += 1)); do
      [[ -f "$pause/paused.${boundary}.${label}-finalizer" ]] && break
      sleep 0.01
    done
    [[ -f "$pause/paused.${boundary}.${label}-finalizer" ]] || {
      cat "${state_dir}/${label}.finalizer.log" >&2
      fail "completed finalizer did not reach ${boundary}"
    }
    kill -9 "$finalizer_job"
    wait "$finalizer_job" 2>/dev/null || true
    kill -0 "$finalizer_job" 2>/dev/null && fail "completed finalizer survived kill -9 at ${boundary}"
    assert_file_exists "$marker"
    assert_file_contains "$marker" "run_id$(printf '\t')${run_id}"

    if [[ "$index" -eq 1 || "$index" -eq 3 ]]; then retry_target="$run_id"; else retry_target=current; fi
    if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$retry_target") \
        > "${state_dir}/${label}.retry.log" 2>&1; then
      cat "${state_dir}/${label}.retry.log" >&2
      fail "completed cleanup retry failed after ${boundary}"
    fi
    assert_file_contains "${state_dir}/${label}.retry.log" 'control plane finalized without rerunning work'
    queue_side_effect_snapshot > "${state_dir}/${label}.side-effects.after"
    cmp -s "${state_dir}/${label}.side-effects.before" "${state_dir}/${label}.side-effects.after" || \
      fail "completed cleanup changed exact side-effect counts after ${boundary}"
    audit="${repo_dir}/.work/queue/lease.finalized.${owner_generation}.${owner_token}"
    assert_file_exists "${audit}/owner.${owner_token}.state"
    assert_equals 1 "$(find "${repo_dir}/.work/queue" -maxdepth 1 -type d -name "lease.finalized.${owner_generation}.${owner_token}" | wc -l)" \
      "${boundary} finalized lease audit count"
    assert_path_not_exists "$marker"
    assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/completion-cleanup.state" $'phase\tcompleted'
    assert_path_not_exists "${repo_dir}/.work/queue/current"
    assert_path_not_exists "${repo_dir}/.work/queue/current_batch"
    assert_path_not_exists "${repo_dir}/.work/queue/lease.lock"
    if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
        > "${state_dir}/${label}.idempotent.log" 2>&1; then
      fail "explicit finalization was not idempotent after ${boundary}"
    fi
    assert_file_contains "${state_dir}/${label}.idempotent.log" 'control plane is already finalized'
    queue_side_effect_snapshot > "${state_dir}/${label}.side-effects.idempotent"
    cmp -s "${state_dir}/${label}.side-effects.before" "${state_dir}/${label}.side-effects.idempotent" || \
      fail "idempotent completed cleanup changed side effects after ${boundary}"
    if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 63) \
        > "${state_dir}/${label}.invalid-new-run.log" 2>&1; then
      fail "normal queue startup accepted invalid work configuration after ${boundary}"
    fi
    assert_file_contains "${state_dir}/${label}.invalid-new-run.log" "${config_diagnostics[$index]}"
    queue_side_effect_snapshot > "${state_dir}/${label}.side-effects.invalid-new-run"
    cmp -s "${state_dir}/${label}.side-effects.before" "${state_dir}/${label}.side-effects.invalid-new-run" || \
      fail "strict invalid configuration check changed side effects after ${boundary}"
    cp "$project_backup" "${repo_dir}/.issue_forge/project.sh"
  done

  pause="${state_dir}/queue-completed-a-active-b"
  rm -rf "$pause"; mkdir -p "$pause"
  clear_command_logs; reset_flow_counters
  (
    cd "$repo_dir"
    exec env PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_worker_registration_before_authorization \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=active-b \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 62
  ) > "${state_dir}/queue-active-b.log" 2>&1 & owner_job=$!
  for ((attempt = 0; attempt < 2000; attempt += 1)); do
    [[ -f "$pause/paused.after_worker_registration_before_authorization.active-b" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.after_worker_registration_before_authorization.active-b" ]] || fail 'run B did not publish its active control plane'
  b_run="$(awk -F '\t' '$1 == "run_id" { print $2 }' "${repo_dir}/.work/queue/current")"
  b_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  b_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$b_record")"
  cp "${repo_dir}/.work/queue/current" "${state_dir}/active-b.current"
  cp -a "${repo_dir}/.work/queue/lease.lock" "${state_dir}/active-b.lease"
  cp "$active_file" "${state_dir}/active-b.active"
  queue_side_effect_snapshot > "${state_dir}/active-b.side-effects"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
      > "${state_dir}/completed-a-active-b.log" 2>&1; then
    cat "${state_dir}/completed-a-active-b.log" >&2
    fail 'already-finalized A should succeed while B owns the active control plane'
  fi
  assert_file_contains "${state_dir}/completed-a-active-b.log" 'control plane is already finalized'
  cmp -s "${state_dir}/active-b.current" "${repo_dir}/.work/queue/current" || fail 'A finalization changed B current pointer'
  assert_equals 1 "$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state' | wc -l)" 'B lease owner count after A finalization'
  cmp -s "${state_dir}/active-b.lease/owner.${b_token}.state" \
    "${repo_dir}/.work/queue/lease.lock/owner.${b_token}.state" || fail 'A finalization changed B lease'
  cmp -s "${state_dir}/active-b.active" "$active_file" || fail 'A finalization changed B active-process record'
  queue_side_effect_snapshot > "${state_dir}/active-b.side-effects.after"
  cmp -s "${state_dir}/active-b.side-effects" "${state_dir}/active-b.side-effects.after" || fail 'A finalization changed B counters'
  touch "$pause/release.after_worker_registration_before_authorization.active-b"
  if ! wait "$owner_job"; then cat "${state_dir}/queue-active-b.log" >&2; fail 'run B did not finish after isolation check'; fi
  assert_file_contains "${repo_dir}/.work/queue/runs/${b_run}/run.state" $'state\tcompleted'

  cp "${state_dir}/active-b.active" "$active_file"
  cp "$active_file" "${state_dir}/dead-b.active.before"
  queue_side_effect_snapshot > "${state_dir}/dead-b.side-effects.before"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
      > "${state_dir}/completed-a-dead-active-b.log" 2>&1; then
    fail 'already-finalized A should no-op with a dead active-process record for B'
  fi
  cmp -s "${state_dir}/dead-b.active.before" "$active_file" || fail 'A finalization removed dead active-process record for B'
  queue_side_effect_snapshot > "${state_dir}/dead-b.side-effects.after"
  cmp -s "${state_dir}/dead-b.side-effects.before" "${state_dir}/dead-b.side-effects.after" || fail 'A finalization with dead B active state changed side effects'

  cp "${state_dir}/dead-b.active.before" "$active_file"
  mv "${repo_dir}/.work/queue/runs/${run_id}/completion-cleanup.state" "${state_dir}/completed-a-terminal.state"
  printf 'schema_version\t3\nrun_id\t%s\nowner_token\t%s\nlease_generation\t%s\nupdated_at\t2026-08-07T00:00:00Z\n' \
    "$run_id" "$owner_token" "$owner_generation" > "${repo_dir}/.work/queue/current"
  queue_tree_snapshot "$(dirname "$active_file")" > "${state_dir}/cross-run-active.before"
  queue_side_effect_snapshot > "${state_dir}/cross-run-active.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
      > "${state_dir}/completed-a-cross-run-active.log" 2>&1; then
    fail 'pending A cleanup must reject B active-process ownership'
  fi
  assert_file_contains "${state_dir}/completed-a-cross-run-active.log" "Active-process record belongs to run ${b_run}"
  queue_tree_snapshot "$(dirname "$active_file")" > "${state_dir}/cross-run-active.after"
  cmp -s "${state_dir}/cross-run-active.before" "${state_dir}/cross-run-active.after" || fail 'A finalizer mutated B active-process control state'
  queue_side_effect_snapshot > "${state_dir}/cross-run-active.side-effects.after"
  cmp -s "${state_dir}/cross-run-active.side-effects.before" "${state_dir}/cross-run-active.side-effects.after" || fail 'cross-run active rejection changed side effects'
  rm -f "$active_file" "${repo_dir}/.work/queue/current"
  mv "${state_dir}/completed-a-terminal.state" "${repo_dir}/.work/queue/runs/${run_id}/completion-cleanup.state"

  mv "${repo_dir}/.work/queue/runs/${run_id}/completion-cleanup.state" "${state_dir}/completed-a-terminal.state"
  cp -a "$audit" "${repo_dir}/.work/queue/lease.lock"
  record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  printf 'schema_version\t3\nrun_id\t%s\nowner_token\tmismatched-token\nlease_generation\t%s\nupdated_at\t2026-08-07T00:00:00Z\n' \
    "$run_id" "$owner_generation" > "${repo_dir}/.work/queue/current"
  queue_tree_snapshot "${repo_dir}/.work/queue" > "${state_dir}/fencing-mismatch.before"
  queue_side_effect_snapshot > "${state_dir}/fencing-mismatch.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
      > "${state_dir}/completion-fencing-mismatch.log" 2>&1; then
    fail 'same-run pointer/lease fencing mismatch must fail'
  fi
  assert_file_contains "${state_dir}/completion-fencing-mismatch.log" 'contradictory current/lease fencing identities'
  queue_tree_snapshot "${repo_dir}/.work/queue" > "${state_dir}/fencing-mismatch.after"
  cmp -s "${state_dir}/fencing-mismatch.before" "${state_dir}/fencing-mismatch.after" || fail 'fencing mismatch failure mutated control state'
  queue_side_effect_snapshot > "${state_dir}/fencing-mismatch.side-effects.after"
  cmp -s "${state_dir}/fencing-mismatch.side-effects.before" "${state_dir}/fencing-mismatch.side-effects.after" || fail 'fencing mismatch changed side effects'
  rm -rf "${repo_dir}/.work/queue/lease.lock"; rm -f "${repo_dir}/.work/queue/current"

  cp -a "$audit" "${repo_dir}/.work/queue/lease.lock"
  record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  mv "$record" "${repo_dir}/.work/queue/lease.lock/owner.renamed-token.state"
  queue_tree_snapshot "${repo_dir}/.work/queue" > "${state_dir}/renamed-owner.before"
  queue_side_effect_snapshot > "${state_dir}/renamed-owner.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
      > "${state_dir}/completion-renamed-owner.log" 2>&1; then
    fail 'renamed lease owner record must fail completed finalization'
  fi
  assert_file_contains "${state_dir}/completion-renamed-owner.log" 'filename does not match embedded owner token'
  queue_tree_snapshot "${repo_dir}/.work/queue" > "${state_dir}/renamed-owner.after"
  cmp -s "${state_dir}/renamed-owner.before" "${state_dir}/renamed-owner.after" || fail 'renamed owner failure mutated control state'
  queue_side_effect_snapshot > "${state_dir}/renamed-owner.side-effects.after"
  cmp -s "${state_dir}/renamed-owner.side-effects.before" "${state_dir}/renamed-owner.side-effects.after" || fail 'renamed owner failure changed side effects'
  rm -rf "${repo_dir}/.work/queue/lease.lock"
  mv "${state_dir}/completed-a-terminal.state" "${repo_dir}/.work/queue/runs/${run_id}/completion-cleanup.state"
}

run_queue_completion_cleanup_invariant_smoke() {
  local manifest run_id terminal token generation lease_required batch marker guard_dir audit saved_audit
  local queue_root="${repo_dir}/.work/queue" pointer batch_pointer lock active log_file case_name

  log 'running completion cleanup phase-postcondition invariant smoke'
  clear_command_logs; reset_flow_counters
  rm -f "${state_dir}/batch-pr-url.txt"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 69) > "${state_dir}/cleanup-invariant-owner.log" 2>&1; then
    cat "${state_dir}/cleanup-invariant-owner.log" >&2
    fail 'cleanup invariant fixture queue did not complete'
  fi
  manifest="$(grep -l $'^issues\t69$' "${queue_root}"/runs/*/manifest.state | head -n 1)"
  [[ -n "$manifest" ]] || fail 'cannot locate cleanup invariant fixture run'
  run_id="$(basename "$(dirname "$manifest")")"
  terminal="${queue_root}/runs/${run_id}/completion-cleanup.state"
  token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$terminal")"
  generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$terminal")"
  lease_required="$(awk -F '\t' '$1 == "lease_required" { print $2 }' "$terminal")"
  batch="$(awk -F '\t' '$1 == "batch_pointer" { print $2 }' "$terminal")"
  guard_dir="$(${REAL_GIT} -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)/issue-forge/queue"
  marker="${guard_dir}/completion-cleanup.state"; active="${guard_dir}/active-process.state"
  audit="${queue_root}/lease.finalized.${generation}.${token}"; saved_audit="${state_dir}/cleanup-invariant-audit"
  pointer="${queue_root}/current"; batch_pointer="${queue_root}/current_batch"; lock="${queue_root}/lease.lock"
  assert_equals 1 "$lease_required" 'cleanup invariant fixture lease requirement'
  assert_file_exists "${audit}/owner.${token}.state"
  queue_side_effect_snapshot > "${state_dir}/cleanup-invariant.side-effects.baseline"
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'issue_fetch\t1'
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'implementation\t1'
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'branch_switch\t1'
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'push\t1'
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'pr_mutation\t1'
  assert_file_contains "${state_dir}/cleanup-invariant.side-effects.baseline" $'merge\t0'

  case_name='missing-audit'
  mv "$audit" "$saved_audit"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" lease_retired
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.before"
  log_file="${state_dir}/${case_name}.log"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "$log_file" 2>&1; then
    fail 'lease_retired cleanup without its required audit must fail'
  fi
  assert_file_contains "$log_file" 'requires finalized lease audit'
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/${case_name}.queue.before" "${state_dir}/${case_name}.queue.after" || fail 'missing-audit rejection mutated queue state'
  cmp -s "${state_dir}/${case_name}.control.before" "${state_dir}/${case_name}.control.after" || fail 'missing-audit rejection mutated common control state'
  cmp -s "${state_dir}/${case_name}.side-effects.before" "${state_dir}/${case_name}.side-effects.after" || fail 'missing-audit rejection changed side effects'
  rm "$marker"; mv "$saved_audit" "$audit"

  case_name='lease-still-present'
  cp -a "$audit" "$lock"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" lease_retired
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.before"
  log_file="${state_dir}/${case_name}.log"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "$log_file" 2>&1; then
    fail 'lease_retired cleanup with a same-run lease path must fail'
  fi
  assert_file_contains "$log_file" 'requires the same-run lease path to be absent'
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/${case_name}.queue.before" "${state_dir}/${case_name}.queue.after" || fail 'remaining-lease rejection mutated queue state'
  cmp -s "${state_dir}/${case_name}.control.before" "${state_dir}/${case_name}.control.after" || fail 'remaining-lease rejection mutated common control state'
  cmp -s "${state_dir}/${case_name}.side-effects.before" "${state_dir}/${case_name}.side-effects.after" || fail 'remaining-lease rejection changed side effects'
  rm -rf "$lock"; rm "$marker"

  case_name='reappeared-batch'
  printf '%s\n' "$batch" > "$batch_pointer"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" batch_pointer_removed
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'exact reappeared current_batch was not reconciled'
  fi
  assert_path_not_exists "$batch_pointer"; assert_path_not_exists "$marker"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/cleanup-invariant.side-effects.baseline" "${state_dir}/${case_name}.side-effects.after" || fail 'batch reconciliation changed side effects'

  case_name='different-batch'
  printf 'batch-different\n' > "$batch_pointer"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" batch_pointer_removed
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'different current_batch must fail cleanup without mutation'
  fi
  assert_file_contains "${state_dir}/${case_name}.log" 'current_batch does not match completed run'
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/${case_name}.queue.before" "${state_dir}/${case_name}.queue.after" || fail 'different-batch rejection mutated queue state'
  cmp -s "${state_dir}/${case_name}.control.before" "${state_dir}/${case_name}.control.after" || fail 'different-batch rejection mutated common control state'
  cmp -s "${state_dir}/${case_name}.side-effects.before" "${state_dir}/${case_name}.side-effects.after" || fail 'different-batch rejection changed side effects'
  rm "$batch_pointer" "$marker"

  case_name='reappeared-current'
  write_queue_pointer_fixture "$pointer" "$run_id" "$token" "$generation"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" current_removed
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'exact reappeared current pointer was not reconciled'
  fi
  assert_path_not_exists "$pointer"; assert_path_not_exists "$marker"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/cleanup-invariant.side-effects.baseline" "${state_dir}/${case_name}.side-effects.after" || fail 'current reconciliation changed side effects'

  case_name='different-current-fencing'
  write_queue_pointer_fixture "$pointer" "$run_id" mismatched-token "$generation"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" current_removed
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'different current fencing identity must fail cleanup'
  fi
  assert_file_contains "${state_dir}/${case_name}.log" 'current pointer contradicts its cleanup transaction identity'
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/${case_name}.queue.before" "${state_dir}/${case_name}.queue.after" || fail 'different-current rejection mutated queue state'
  cmp -s "${state_dir}/${case_name}.control.before" "${state_dir}/${case_name}.control.after" || fail 'different-current rejection mutated common control state'
  cmp -s "${state_dir}/${case_name}.side-effects.before" "${state_dir}/${case_name}.side-effects.after" || fail 'different-current rejection changed side effects'
  rm "$pointer" "$marker"

  case_name='completed-residue'
  printf '%s\n' "$batch" > "$batch_pointer"
  write_queue_pointer_fixture "$pointer" "$run_id" "$token" "$generation"
  write_completion_cleanup_fixture "$marker" "$run_id" "$token" "$generation" 1 "$batch" completed
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'completed marker did not reconcile exact same-run residue'
  fi
  assert_path_not_exists "$batch_pointer"; assert_path_not_exists "$pointer"; assert_path_not_exists "$marker"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/cleanup-invariant.side-effects.baseline" "${state_dir}/${case_name}.side-effects.after" || fail 'completed residue reconciliation changed side effects'

  case_name='terminal-pointer-residue'
  write_queue_pointer_fixture "$pointer" "$run_id" "$token" "$generation"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'terminal tombstone fast path ignored same-run current residue'
  fi
  assert_path_not_exists "$pointer"; assert_path_not_exists "$marker"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/cleanup-invariant.side-effects.baseline" "${state_dir}/${case_name}.side-effects.after" || fail 'terminal-pointer reconciliation changed side effects'

  case_name='terminal-lease-residue'
  cp -a "$audit" "$lock"
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.before"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.before"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.before"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/${case_name}.log" 2>&1; then
    fail 'terminal tombstone plus same-run lease/audit contradiction must fail'
  fi
  assert_file_contains "${state_dir}/${case_name}.log" 'requires the same-run lease path to be absent'
  queue_tree_snapshot "$queue_root" > "${state_dir}/${case_name}.queue.after"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/${case_name}.control.after"
  queue_side_effect_snapshot > "${state_dir}/${case_name}.side-effects.after"
  cmp -s "${state_dir}/${case_name}.queue.before" "${state_dir}/${case_name}.queue.after" || fail 'terminal-lease rejection mutated queue state'
  cmp -s "${state_dir}/${case_name}.control.before" "${state_dir}/${case_name}.control.after" || fail 'terminal-lease rejection mutated common control state'
  cmp -s "${state_dir}/${case_name}.side-effects.before" "${state_dir}/${case_name}.side-effects.after" || fail 'terminal-lease rejection changed side effects'
  rm -rf "$lock"
  assert_path_not_exists "$marker"; assert_path_not_exists "$active"
}

run_queue_linked_worktree_rejection_smoke() {
  local linked_dir="${temp_root}/linked-queue-worktree" git_common guard_dir existing_run invocation label log_file
  local -a invocations=()

  log 'running linked-worktree queue rejection smoke'
  git_common="$(${REAL_GIT} -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)"
  guard_dir="${git_common}/issue-forge/queue"
  existing_run="$(find "${repo_dir}/.work/queue/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort | head -n 1)"
  [[ -n "$existing_run" ]] || fail 'linked-worktree smoke requires an existing primary-worktree run'
  "${REAL_GIT}" -C "$repo_dir" worktree add --detach "$linked_dir" HEAD >/dev/null
  assert_path_not_exists "${linked_dir}/.work/queue"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/linked-worktree.control.before"
  clear_command_logs; reset_flow_counters

  invocations=(
    "70"
    "--resume ${existing_run}"
    "--resume current"
  )
  for invocation in "${invocations[@]}"; do
    label="$(printf '%s' "$invocation" | tr ' ' '-')"
    log_file="${state_dir}/linked-worktree-${label}.log"
    # shellcheck disable=SC2086 # the fixture intentionally expands one fixed argument string
    if (cd "$linked_dir"; env ISSUE_FORGE_CONSUMER_ROOT="$linked_dir" PATH="${stub_dir}:$PATH" \
        "${REPO_ROOT}/tools/codex/run_issue_queue.sh" $invocation) > "$log_file" 2>&1; then
      fail "linked-worktree queue invocation unexpectedly succeeded: ${invocation}"
    fi
    assert_file_contains "$log_file" 'Queue execution from a linked Git worktree is unsupported because queue ownership state is worktree-local'
    assert_file_contains "$log_file" 'primary worktree or use a separate clone'
    assert_file_not_contains "$log_file" 'resume with:'
  done
  assert_path_not_exists "${linked_dir}/.work/queue"
  queue_tree_snapshot "$guard_dir" > "${state_dir}/linked-worktree.control.after"
  cmp -s "${state_dir}/linked-worktree.control.before" "${state_dir}/linked-worktree.control.after" || \
    fail 'rejected linked-worktree invocation changed Git-common-dir queue control state'
  queue_side_effect_snapshot > "${state_dir}/linked-worktree.side-effects"
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'issue_fetch\t0'
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'implementation\t0'
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'branch_switch\t0'
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'push\t0'
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'pr_mutation\t0'
  assert_file_contains "${state_dir}/linked-worktree.side-effects" $'merge\t0'

  clear_command_logs; reset_flow_counters
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 70) > "${state_dir}/primary-after-linked.log" 2>&1; then
    cat "${state_dir}/primary-after-linked.log" >&2
    fail 'primary worktree queue failed after linked-worktree rejection'
  fi
  queue_side_effect_snapshot > "${state_dir}/primary-after-linked.side-effects"
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'issue_fetch\t1'
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'implementation\t1'
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'branch_switch\t1'
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'push\t1'
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'pr_mutation\t1'
  assert_file_contains "${state_dir}/primary-after-linked.side-effects" $'merge\t0'
  "${REAL_GIT}" -C "$repo_dir" worktree remove "$linked_dir" >/dev/null
}

run_queue_worker_registration_smoke() {
  local boundary issue label pause queue_job index wait_attempt owner_record owner_pid run_id worker_pid active_file guard_file contender_log
  local issue_fetch_count branch_create_count push_count pr_count merge_count
  local -a boundaries=(after_worker_fork_before_registration after_worker_registration_before_authorization after_worker_authorization_before_first_external_mutation)
  local -a issues=(44 45 46)
  log 'running controlled worker registration and authorization smoke'
  active_file="$("${REAL_GIT}" -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)/issue-forge/queue/active-process.state"
  guard_file="$(dirname "$active_file")/control.guard"
  for index in 0 1 2; do
    boundary="${boundaries[$index]}"; issue="${issues[$index]}"; label="worker-${index}"
    pause="${state_dir}/queue-${boundary}"
    rm -rf "$pause"; mkdir -p "$pause"
    clear_command_logs; reset_flow_counters
    (
      cd "$repo_dir"
      PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
        CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT="$boundary" \
        CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL="$label" \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue"
    ) > "${state_dir}/queue-${boundary}.owner.log" 2>&1 & queue_job=$!
    for ((wait_attempt = 0; wait_attempt < 2000; wait_attempt += 1)); do
      [[ -f "$pause/paused.${boundary}.${label}" ]] && break
      sleep 0.01
    done
    [[ -f "$pause/paused.${boundary}.${label}" ]] || fail "worker did not reach ${boundary}"
    owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
    owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
    run_id="$(awk -F '\t' '$1 == "run_id" { print $2 }' "$owner_record")"
    assert_file_contains "$owner_record" $'lease_generation\t1'
    if [[ "$boundary" == after_worker_fork_before_registration ]]; then
      worker_pid="$(ps -o pid= --ppid "$owner_pid" | awk 'NF { print $1; exit }')"
      [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]] || fail 'pre-registration worker PID was not observable'
      assert_path_not_exists "$active_file"
    else
      assert_file_exists "$active_file"
      worker_pid="$(awk -F '\t' '$1 == "child_pid" { print $2 }' "$active_file")"
      assert_file_contains "$active_file" "run_id$(printf '\t')${run_id}"
      assert_file_contains "$active_file" "child_pgid$(printf '\t')${worker_pid}"
      assert_file_contains "$active_file" 'process_start'
    fi
    kill -0 "$worker_pid" 2>/dev/null || fail "controlled worker was not alive at ${boundary}"
    issue_fetch_count="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
    branch_create_count="$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
    push_count="$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
    pr_count="$(awk '$1 == "pr" && $2 == "create" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
    merge_count="$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
    assert_equals 0 "$issue_fetch_count" "${boundary} pre-authorization Issue fetch count"
    assert_equals 0 "$branch_create_count" "${boundary} pre-authorization branch creation count"
    assert_equals 0 "$push_count" "${boundary} pre-authorization push count"
    assert_equals 0 "$pr_count" "${boundary} pre-authorization PR count"
    assert_equals 0 "$merge_count" "${boundary} pre-authorization merge count"
    kill -9 "$owner_pid"
    wait "$queue_job" 2>/dev/null || true
    kill -0 "$owner_pid" 2>/dev/null && fail "queue parent survived kill -9 at ${boundary}"
    if [[ "$boundary" != after_worker_fork_before_registration ]]; then
      contender_log="${state_dir}/queue-${boundary}.contender.log"
      if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" timeout 5 "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") \
          > "$contender_log" 2>&1; then
        fail "registered orphan contender unexpectedly acquired ownership at ${boundary}"
      fi
      assert_file_contains "$contender_log" 'Queue serialization guard remained busy for 1 second'
      assert_file_contains "$contender_log" "child PID=${worker_pid}"
    fi
    for ((wait_attempt = 0; wait_attempt < 400; wait_attempt += 1)); do
      kill -0 "$worker_pid" 2>/dev/null || break
      sleep 0.01
    done
    kill -0 "$worker_pid" 2>/dev/null && fail "worker did not self-terminate after parent death at ${boundary}"
    if ! flock -w 2 "$guard_file" true; then fail "control.guard remained busy after ${boundary} worker exit"; fi
    if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-${boundary}.resume.log" 2>&1; then
      cat "${state_dir}/queue-${boundary}.resume.log" >&2
      fail "same-run resume failed after parent death at ${boundary}"
    fi
    assert_path_not_exists "$active_file"
    if compgen -G "$(dirname "$active_file")/worker.${run_id}.*" >/dev/null; then
      fail "worker registration artifact remained after recovery at ${boundary}"
    fi
    assert_equals 1 "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" "${boundary} recovered Issue fetch count"
    assert_equals 1 "$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" "${boundary} recovered branch creation count"
    assert_equals 1 "$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" "${boundary} recovered push count"
    assert_equals 0 "$(awk '$1 == "pr" && $2 == "create" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" "${boundary} recovered PR count"
    assert_equals 0 "$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" "${boundary} recovered merge count"
  done
}

run_queue_worker_phase_checkpoint_smoke() {
  local index failpoint phase issue log_file run_id pause queue_job owner_record owner_pid attempt
  local -a failpoints=(fail_issue_context_fetch fail_issue_flow fail_batch_checks fail_batch_review fail_batch_publish)
  local -a phases=(issue_context_fetch issue_flow batch_checks batch_review batch_publish)
  local -a issues=(47 48 49 50 51)
  log 'running controlled worker terminal phase propagation smoke'
  for index in 0 1 2 3 4; do
    failpoint="${failpoints[$index]}"; phase="${phases[$index]}"; issue="${issues[$index]}"
    log_file="${state_dir}/queue-phase-${phase}.log"
    clear_command_logs; reset_flow_counters
    if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
        CODEX_FLOW_QUEUE_FAILPOINT="$failpoint" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue") > "$log_file" 2>&1; then
      fail "controlled worker failpoint ${failpoint} unexpectedly succeeded"
    fi
    run_id="$(awk -F '\t' '$1 == "run_id" { print $2 }' "${repo_dir}/.work/queue/current")"
    assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/checkpoint.state" "phase$(printf '\t')${phase}"
    assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/checkpoint.state" $'status\tfailed'
    assert_file_not_contains "$log_file" $'phase\tstartup'
    if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
        "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-phase-${phase}.resume.log" 2>&1; then
      fail "resume failed after controlled worker phase ${phase} failure"
    fi
  done

  issue=52; phase=issue_context_fetch; pause="${state_dir}/queue-phase-sigterm-pause"
  rm -rf "$pause"; mkdir -p "$pause"; clear_command_logs; reset_flow_counters
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_SKIP_PUBLISH=1 \
      CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_active_phase_issue_context_fetch \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=phase-term \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue"
  ) > "${state_dir}/queue-phase-sigterm.log" 2>&1 & queue_job=$!
  for ((attempt = 0; attempt < 2000; attempt += 1)); do [[ -f "$pause/paused.after_active_phase_issue_context_fetch.phase-term" ]] && break; sleep 0.01; done
  [[ -f "$pause/paused.after_active_phase_issue_context_fetch.phase-term" ]] || fail 'controlled worker did not reach SIGTERM phase pause'
  owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
  run_id="$(awk -F '\t' '$1 == "run_id" { print $2 }' "$owner_record")"
  kill -TERM "$owner_pid"
  wait "$queue_job" 2>/dev/null || true
  assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/checkpoint.state" "phase$(printf '\t')${phase}"
  assert_file_contains "${repo_dir}/.work/queue/runs/${run_id}/checkpoint.state" $'status\tinterrupted'
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-phase-sigterm.resume.log" 2>&1; then
    cat "${state_dir}/queue-phase-sigterm.resume.log" >&2
    fail 'resume failed after controlled worker SIGTERM phase capture'
  fi
}

run_queue_external_orphan_smoke() {
  local pause="${state_dir}/queue-external-orphan-pause" log_file="${state_dir}/queue-external-orphan-owner.log"
  local queue_job attempt owner_record owner_pid run_id active_file child_pid child_pgid child_start busy_status elapsed
  local issue_fetch_count branch_create_count push_count pr_count merge_count
  log 'running queue external-child owner-SIGKILL smoke'
  clear_command_logs; reset_flow_counters
  rm -rf "$pause"; mkdir -p "$pause"
  active_file="$(${REAL_GIT} -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)/issue-forge/queue/active-process.state"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      SMOKE_QUEUE_EXTERNAL_PAUSE_DIR="$pause" SMOKE_QUEUE_EXTERNAL_PAUSE_ISSUE=42 SMOKE_QUEUE_EXTERNAL_PAUSE_LABEL=orphan \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 42
  ) > "$log_file" 2>&1 & queue_job=$!
  for ((attempt = 0; attempt < 2000; attempt += 1)); do
    [[ -f "$pause/paused.orphan" && -f "$active_file" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.orphan" && -f "$active_file" ]] || fail 'external queue stub did not reach the controlled child pause'
  owner_record="$(find "${repo_dir}/.work/queue/lease.lock" -maxdepth 1 -type f -name 'owner.*.state')"
  owner_pid="$(awk -F '\t' '$1 == "owner_pid" { print $2 }' "$owner_record")"
  run_id="$(awk -F '\t' '$1 == "run_id" { print $2 }' "$owner_record")"
  child_pid="$(awk -F '\t' '$1 == "child_pid" { print $2 }' "$active_file")"
  child_pgid="$(awk -F '\t' '$1 == "child_pgid" { print $2 }' "$active_file")"
  child_start="$(awk -F '\t' '$1 == "process_start" { print $2 }' "$active_file")"
  assert_equals issue_context_fetch "$(awk -F '\t' '$1 == "phase" { print $2 }' "$active_file")" 'external orphan active phase'
  kill -9 "$owner_pid"
  if wait "$queue_job" 2>/dev/null; then fail 'queue parent killed during external phase unexpectedly succeeded'; fi
  assert_file_exists "$owner_record"
  assert_file_exists "$active_file"

  elapsed="$SECONDS"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" timeout 5 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-external-orphan-busy.log" 2>&1; then
    fail 'resume must not take over while the orphan external process group is alive'
  else
    busy_status=$?
  fi
  elapsed=$((SECONDS - elapsed))
  [[ "$busy_status" -ne 124 && "$elapsed" -lt 5 ]] || fail 'orphan guard diagnostic exceeded the bounded interval'
  assert_file_contains "${state_dir}/queue-external-orphan-busy.log" 'Queue serialization guard remained busy for 1 second'
  assert_file_contains "${state_dir}/queue-external-orphan-busy.log" "run=${run_id}"
  assert_file_contains "${state_dir}/queue-external-orphan-busy.log" 'active phase: issue_context_fetch'
  assert_file_contains "${state_dir}/queue-external-orphan-busy.log" "child PID=${child_pid} PGID=${child_pgid} process_start=${child_start}"
  assert_file_contains "${state_dir}/queue-external-orphan-busy.log" "kill -TERM -- -${child_pgid}"
  assert_equals 1 "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'orphan-busy Issue fetch count'

  touch "$pause/release.orphan"
  for ((attempt = 0; attempt < 2000; attempt += 1)); do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.01
  done
  kill -0 "$child_pid" 2>/dev/null && fail 'controlled orphan child did not terminate after its external stub completed'
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "${state_dir}/queue-external-orphan-resume.log" 2>&1; then
    cat "${state_dir}/queue-external-orphan-resume.log" >&2
    fail 'same-run resume should proceed after the controlled orphan process group exits'
  fi
  assert_file_contains "${state_dir}/queue-external-orphan-resume.log" 'reconciled existing durable Issue 42 context without refetching'
  issue_fetch_count="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  branch_create_count="$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  push_count="$(awk '$1 == "push" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  pr_count="$(awk '$1 == "pr" && ($2 == "create" || $2 == "edit") { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  merge_count="$(awk '$1 == "pr" && $2 == "merge" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  assert_equals 1 "$issue_fetch_count" 'external orphan recovery Issue fetch count'
  assert_equals 1 "$branch_create_count" 'external orphan recovery branch creation count'
  assert_equals 1 "$push_count" 'external orphan recovery push count'
  assert_equals 1 "$pr_count" 'external orphan recovery PR mutation count'
  assert_equals 0 "$merge_count" 'external orphan recovery merge count'
  assert_equals 1 "$(< "${state_dir}/implementation-count.txt")" 'external orphan recovery implementation count'
  assert_path_not_exists "$active_file"
}

run_queue_guard_path_stability_smoke() {
  local pause="${state_dir}/queue-guard-stability-pause" log_file="${state_dir}/queue-guard-stability-owner.log"
  local queue_job attempt guard guard_identity busy_status issue_fetch_count branch_create_count
  log 'running queue guard-path stability smoke'
  clear_command_logs; reset_flow_counters
  rm -rf "$pause"; mkdir -p "$pause"
  guard="$(${REAL_GIT} -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)/issue-forge/queue/control.guard"
  guard_identity="$(stat -Lc '%d:%i' "$guard")"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_SKIP_PUBLISH=1 \
      SMOKE_QUEUE_EXTERNAL_PAUSE_DIR="$pause" SMOKE_QUEUE_EXTERNAL_PAUSE_ISSUE=43 SMOKE_QUEUE_EXTERNAL_PAUSE_LABEL=guard-rebind \
      SMOKE_QUEUE_REMOVE_WORK_QUEUE=1 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 43
  ) > "$log_file" 2>&1 & queue_job=$!
  for ((attempt = 0; attempt < 2000; attempt += 1)); do
    [[ -f "$pause/paused.guard-rebind" ]] && break
    sleep 0.01
  done
  [[ -f "$pause/paused.guard-rebind" ]] || fail 'guard-path cleanup stub did not reach its pause'
  assert_path_not_exists "${repo_dir}/.work/queue"
  assert_equals "$guard_identity" "$(stat -Lc '%d:%i' "$guard")" 'Git-common-dir guard inode during .work cleanup'
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" timeout 5 \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 44) > "${state_dir}/queue-guard-stability-busy.log" 2>&1; then
    fail 'second queue owner must not start after .work/queue replacement'
  else
    busy_status=$?
  fi
  [[ "$busy_status" -ne 124 ]] || fail 'guard-path stability contender hung instead of returning a bounded diagnostic'
  assert_file_contains "${state_dir}/queue-guard-stability-busy.log" 'Queue serialization guard remained busy for 1 second'
  assert_file_contains "${state_dir}/queue-guard-stability-busy.log" 'active phase: issue_context_fetch'
  assert_equals "$guard_identity" "$(stat -Lc '%d:%i' "$guard")" 'Git-common-dir guard inode after contender'
  assert_path_not_exists "${repo_dir}/.work/queue/control.guard"
  issue_fetch_count="$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")"
  branch_create_count="$(awk '$1 == "switch" && $2 == "--create" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")"
  assert_equals 1 "$issue_fetch_count" 'guard stability Issue fetch count'
  assert_equals 1 "$branch_create_count" 'guard stability branch creation count'
  touch "$pause/release.guard-rebind"
  if wait "$queue_job"; then fail 'queue whose authoritative .work state was removed must fail safely'; fi
  assert_equals "$guard_identity" "$(stat -Lc '%d:%i' "$guard")" 'Git-common-dir guard inode after owner failure'
  assert_equals 1 "$(grep -Fc 'resume with:' "$log_file")" 'guard stability pre-cleanup resume hint count'
  assert_file_contains "$log_file" 'state disappeared or became invalid; no resume command can be advertised'
}

queue_run_to_failpoint() {
  local issue="$1" failpoint="$2" log_file="$3"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_FAILPOINT="$failpoint" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue") > "$log_file" 2>&1; then
    fail "queue failpoint ${failpoint} unexpectedly succeeded for Issue ${issue}"
  fi
  assert_file_contains "$log_file" "Queue failpoint triggered: ${failpoint}"
  sed -n 's/^\[queue\] run ID: //p' "$log_file" | head -n 1
}

queue_resume_success() {
  local run="$1" log_file="$2"
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run") > "$log_file" 2>&1; then
    cat "$log_file" >&2
    fail "queue run ${run} should resume successfully"
  fi
}

queue_resume_failure() {
  local run="$1" expected="$2" log_file="$3"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run") > "$log_file" 2>&1; then
    fail "queue run ${run} unexpectedly resumed successfully"
  fi
  assert_file_contains "$log_file" "$expected"
}

run_queue_entity_integrity_smoke() {
  local issue run run_dir batch state_file base commit archive manifest_hash accepted issues_file second_run second_dir first_archive second_archive
  local log_file state_backup manifest_backup missing_file grandparent
  log 'running queue manifest/entity/commit/archive integrity smoke'

  clear_command_logs; reset_flow_counters
  issue=71; log_file="${state_dir}/queue-branch-created.log"
  run="$(queue_run_to_failpoint "$issue" after_batch_branch_creation "$log_file")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"
  state_file="${run_dir}/batches/${batch}/batch.state"; base="$(awk -F '\t' '$1 == "base_commit" { print $2 }' "$state_file")"
  assert_file_contains "$state_file" $'state\tbase_resolved'
  assert_equals "$base" "$(${REAL_GIT} -C "$repo_dir" rev-parse "refs/heads/batch/${issue}-${issue}")" 'branch-created saved base'
  queue_resume_success "$run" "${state_dir}/queue-branch-created.resume.log"

  clear_command_logs; reset_flow_counters
  issue=72; run="$(queue_run_to_failpoint "$issue" after_batch_branch_creation "${state_dir}/queue-wrong-branch-head.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/batch.state"
  base="$(awk -F '\t' '$1 == "base_commit" { print $2 }' "$state_file")"
  printf 'unexpected branch commit\n' >> "${repo_dir}/smoke-target.txt"
  "${REAL_GIT}" -C "$repo_dir" add smoke-target.txt
  "${REAL_GIT}" -C "$repo_dir" commit -m 'unexpected branch drift' >/dev/null
  queue_resume_failure "$run" 'does not match saved branch-ready boundary SHA' "${state_dir}/queue-wrong-branch-head.resume.log"
  "${REAL_GIT}" -C "$repo_dir" reset --hard "$base" >/dev/null
  queue_resume_success "$run" "${state_dir}/queue-wrong-branch-head.repaired.log"

  clear_command_logs; reset_flow_counters
  issue=73; run="$(queue_run_to_failpoint "$issue" after_issue_flow_commit "${state_dir}/queue-fresh-commit.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/issues/${issue}.state"
  assert_file_contains "$state_file" $'state\trunning'
  assert_equals 1 "$(< "${state_dir}/implementation-count.txt")" 'fresh commit-window implementation count before resume'
  queue_resume_success "$run" "${state_dir}/queue-fresh-commit.resume.log"
  assert_equals 1 "$(< "${state_dir}/implementation-count.txt")" 'fresh commit-window implementation count after resume'
  commit="$(awk -F '\t' '$1 == "commit_sha" { print $2 }' "$state_file")"; base="$(awk -F '\t' '$1 == "base_commit" { print $2 }' "$state_file")"
  assert_equals 1 "$(${REAL_GIT} -C "$repo_dir" rev-list --count "${base}..${commit}")" 'fresh commit-window exact commit count'

  clear_command_logs; reset_flow_counters
  issue=74; run="$(queue_run_to_failpoint "$issue" during_artifact_archive_copy "${state_dir}/queue-archive-copy.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/issues/${issue}.state"
  commit="$(${REAL_GIT} -C "$repo_dir" rev-parse HEAD)"; archive="${run_dir}/archives/${batch}/issues/${issue}/${commit}"
  assert_path_not_exists "$archive"
  assert_file_contains "$state_file" $'state\tcommitted'
  queue_resume_success "$run" "${state_dir}/queue-archive-copy.resume.log"

  clear_command_logs; reset_flow_counters
  issue=75; run="$(queue_run_to_failpoint "$issue" after_artifact_archive_publication "${state_dir}/queue-archive-published.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/issues/${issue}.state"
  commit="$(${REAL_GIT} -C "$repo_dir" rev-parse HEAD)"; archive="${run_dir}/archives/${batch}/issues/${issue}/${commit}"
  assert_file_exists "${archive}/archive.manifest"; assert_file_contains "$state_file" $'state\tcommitted'
  manifest_hash="$(sha256sum "${archive}/archive.manifest")"
  queue_resume_success "$run" "${state_dir}/queue-archive-published.resume.log"
  assert_equals "$manifest_hash" "$(sha256sum "${archive}/archive.manifest")" 'published archive adopted without replacement'

  clear_command_logs; reset_flow_counters
  issue=76; run="$(queue_run_to_failpoint "$issue" after_artifact_archive_publication "${state_dir}/queue-archive-tamper.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/issues/${issue}.state"
  commit="$(${REAL_GIT} -C "$repo_dir" rev-parse HEAD)"; archive="${run_dir}/archives/${batch}/issues/${issue}/${commit}"
  manifest_backup="${state_dir}/archive-76.manifest"; cp "${archive}/archive.manifest" "$manifest_backup"
  sed -i "s/^run_id.*/run_id$(printf '\t')cross-run/" "${archive}/archive.manifest"
  queue_resume_failure "$run" 'content manifest does not match' "${state_dir}/queue-archive-cross-run.log"; cp "$manifest_backup" "${archive}/archive.manifest"
  sed -i "s/^issue_number.*/issue_number$(printf '\t')999/" "${archive}/archive.manifest"
  queue_resume_failure "$run" 'content manifest does not match' "${state_dir}/queue-archive-cross-issue.log"; cp "$manifest_backup" "${archive}/archive.manifest"
  sed -i "s/^commit_sha.*/commit_sha$(printf '\t')0000000000000000000000000000000000000000/" "${archive}/archive.manifest"
  queue_resume_failure "$run" 'content manifest does not match' "${state_dir}/queue-archive-wrong-commit.log"; cp "$manifest_backup" "${archive}/archive.manifest"
  missing_file="$(find "${archive}/codex" -type f | head -n 1)"; cp "$missing_file" "${state_dir}/archive-76.missing"; rm "$missing_file"
  queue_resume_failure "$run" 'content manifest does not match' "${state_dir}/queue-archive-partial.log"
  cp "${state_dir}/archive-76.missing" "$missing_file"
  queue_resume_success "$run" "${state_dir}/queue-archive-tamper.repaired.log"

  clear_command_logs; reset_flow_counters
  issue=77; run="$(queue_run_to_failpoint "$issue" after_batch_acceptance "${state_dir}/queue-accepted-head.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; state_file="${run_dir}/batches/${batch}/batch.state"
  accepted="$(awk -F '\t' '$1 == "accepted_head" { print $2 }' "$state_file")"
  printf 'accepted head drift\n' >> "${repo_dir}/smoke-target.txt"; "${REAL_GIT}" -C "$repo_dir" add smoke-target.txt
  "${REAL_GIT}" -C "$repo_dir" commit -m 'unexpected accepted head drift' >/dev/null
  queue_resume_failure "$run" 'does not match saved accepted head SHA' "${state_dir}/queue-accepted-head.resume.log"
  "${REAL_GIT}" -C "$repo_dir" reset --hard "$accepted" >/dev/null
  queue_resume_success "$run" "${state_dir}/queue-accepted-head.repaired.log"

  clear_command_logs; reset_flow_counters
  issue=78; run="$(queue_run_to_failpoint "$issue" fail_batch_checks "${state_dir}/queue-issues-rebuild.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-${issue}-${issue}"; issues_file="${repo_dir}/.work/queue/batches/${batch}/issues.txt"
  printf 'unexpected stale Issue material\n' >> "$issues_file"
  queue_resume_success "$run" "${state_dir}/queue-issues-rebuild.resume.log"
  assert_equals 1 "$(grep -Fc "## Issue #${issue}" "$issues_file")" 'rebuilt Issue material membership count'
  assert_file_not_contains "$issues_file" 'unexpected stale Issue material'

  clear_command_logs; reset_flow_counters
  issue=79; run="$(queue_run_to_failpoint "$issue" fail_issue_flow "${state_dir}/queue-dirty-inner.log")"
  printf 'dirty interrupted implementation\n' >> "${repo_dir}/smoke-target.txt"
  queue_resume_failure "$run" 'Refusing to silently replay dirty interrupted phase issue_flow' "${state_dir}/queue-dirty-inner.resume.log"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; assert_file_contains "${run_dir}/run.state" $'state\tmanual_review_required'
  assert_file_contains "${run_dir}/manual-review.txt" "run_id$(printf '\t')${run}"
  assert_file_contains "${run_dir}/manual-review.txt" 'smoke-target.txt'
  [[ ! -f "${state_dir}/implementation-count.txt" ]] || assert_equals 0 "$(< "${state_dir}/implementation-count.txt")" 'dirty inner phase implementation replay count'
  "${REAL_GIT}" -C "$repo_dir" restore smoke-target.txt
  queue_resume_success "$run" "${state_dir}/queue-dirty-inner.repaired.log"

  clear_command_logs; reset_flow_counters
  issue=80; run="$(queue_run_to_failpoint "$issue" after_minimal_run_publication "${state_dir}/queue-graph-a.log")"
  issue=81; second_run="$(queue_run_to_failpoint "$issue" after_minimal_run_publication "${state_dir}/queue-graph-b.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; second_dir="${repo_dir}/.work/queue/runs/${second_run}"
  state_backup="${state_dir}/queue-graph-b.issue"; cp "${second_dir}/batches/batch-81-81/issues/81.state" "$state_backup"
  cp "${run_dir}/batches/batch-80-80/issues/80.state" "${second_dir}/batches/batch-81-81/issues/81.state"
  clear_command_logs
  queue_resume_failure "$second_run" 'Immutable Issue 81 field run_id differs' "${state_dir}/queue-graph-cross-run.log"
  assert_equals 0 "$(awk '$1 == "issue" && $2 == "view" { count += 1 } END { print count + 0 }' "${state_dir}/gh.log")" 'cross-run graph Issue side-effect count'
  assert_equals 0 "$(awk '$1 == "switch" { count += 1 } END { print count + 0 }' "${state_dir}/git.log")" 'cross-run graph Git mutation count'
  cp "$state_backup" "${second_dir}/batches/batch-81-81/issues/81.state"
  queue_resume_success "$second_run" "${state_dir}/queue-graph-b.resume.log"
  queue_resume_success "$run" "${state_dir}/queue-graph-a.resume.log"

  clear_command_logs; reset_flow_counters
  issue=82
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue") > "${state_dir}/queue-repeat-one.log" 2>&1; then fail 'first repeated-range run failed'; fi
  run="$(grep -l $'^issues\t82$' "${repo_dir}"/.work/queue/runs/*/manifest.state | tail -n 1)"; run="$(basename "$(dirname "$run")")"
  first_archive="$(awk -F '\t' '$1 == "artifact_path" { print $2 }' "${repo_dir}/.work/queue/runs/${run}/batches/batch-82-82/issues/82.state")"
  "${REAL_GIT}" -C "$repo_dir" switch --detach origin/main >/dev/null; "${REAL_GIT}" -C "$repo_dir" branch -D batch/82-82 >/dev/null
  "${REAL_GIT}" -C "$repo_dir" push origin --delete batch/82-82 >/dev/null
  rm -f "${state_dir}/batch-pr-url.txt" "${state_dir}/batch-pr-head-branch.txt" \
    "${state_dir}/batch-pr-head-sha.txt" "${state_dir}/batch-pr-merge.txt"
  reset_flow_counters
  if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" "$issue") > "${state_dir}/queue-repeat-two.log" 2>&1; then cat "${state_dir}/queue-repeat-two.log" >&2; fail 'second repeated-range run failed'; fi
  second_run="$(grep -l $'^issues\t82$' "${repo_dir}"/.work/queue/runs/*/manifest.state | tail -n 1)"; second_run="$(basename "$(dirname "$second_run")")"
  second_archive="$(awk -F '\t' '$1 == "artifact_path" { print $2 }' "${repo_dir}/.work/queue/runs/${second_run}/batches/batch-82-82/issues/82.state")"
  [[ "$run" != "$second_run" && "$first_archive" != "$second_archive" ]] || fail 'identical Issue ranges shared authoritative archive identity'

  clear_command_logs; reset_flow_counters
  issue=83; run="$(queue_run_to_failpoint "$issue" after_issue_flow_commit "${state_dir}/queue-nondirect-base.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; state_file="${run_dir}/batches/batch-83-83/issues/83.state"; state_backup="${state_dir}/queue-nondirect-base.issue"; cp "$state_file" "$state_backup"
  base="$(awk -F '\t' '$1 == "base_commit" { print $2 }' "$state_file")"; grandparent="$(${REAL_GIT} -C "$repo_dir" rev-parse "${base}^")"
  sed -i "s/^base_commit.*/base_commit$(printf '\t')${grandparent}/" "$state_file"
  queue_resume_failure "$run" 'does not start from expected frontier' "${state_dir}/queue-nondirect-base.resume.log"
  cp "$state_backup" "$state_file"
  queue_resume_success "$run" "${state_dir}/queue-nondirect-base.repaired.log"

  clear_command_logs; reset_flow_counters
  issue=84; run="$(queue_run_to_failpoint "$issue" after_artifact_state_transition "${state_dir}/queue-ack-validation.log")"
  run_dir="${repo_dir}/.work/queue/runs/${run}"; batch="batch-84-84"; state_file="${run_dir}/batches/${batch}/issues/84.state"
  state_backup="${state_dir}/queue-ack-validation.issue"; cp "$state_file" "$state_backup"
  base="$(awk -F '\t' '$1 == "base_commit" { print $2 }' "$state_file")"; grandparent="$(${REAL_GIT} -C "$repo_dir" rev-parse "${base}^")"
  sed -i "s/^base_commit.*/base_commit$(printf '\t')${grandparent}/" "$state_file"
  queue_resume_failure "$run" 'does not equal expected frontier' "${state_dir}/queue-ack-wrong-base.log"; cp "$state_backup" "$state_file"
  commit="$(awk -F '\t' '$1 == "commit_sha" { print $2 }' "$state_file")"
  sed -i "s/^commit_sha.*/commit_sha$(printf '\t')${base}/" "$state_file"
  queue_resume_failure "$run" 'archive identity does not match' "${state_dir}/queue-ack-wrong-commit.log"; cp "$state_backup" "$state_file"
  printf 'dirty acknowledgement\n' >> "${repo_dir}/smoke-target.txt"
  queue_resume_failure "$run" 'Working tree must be clean before processing issue 84' "${state_dir}/queue-ack-dirty.log"
  assert_file_contains "$state_file" $'state\tartifacts_archived'
  "${REAL_GIT}" -C "$repo_dir" restore smoke-target.txt
  queue_resume_success "$run" "${state_dir}/queue-ack-validation.repaired.log"
}

run_issue_queue_smoke() {
  local batch_dir="${repo_dir}/.work/queue/batches/batch-${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}"
  local queue_log="${state_dir}/queue.log"
  local run_dir

  log 'running issue queue smoke'
  clear_command_logs
  reset_flow_counters

  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" \
        --review-every 2 \
        --batch-review-effort queue_review \
        --batch-fix-effort queue_fix \
        "${QUEUE_ISSUE_NUMBER}" "${ISSUE_NUMBER}"
  ) > "${queue_log}" 2>&1; then
    cat "${queue_log}" >&2
    fail 'run_issue_queue.sh should succeed for one batch'
  fi

  assert_equals "batch/${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'queue batch branch'
  assert_file_contains "${state_dir}/git.log" "switch --create batch/${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER} $(< "${batch_dir}/base_commit")"
  assert_file_not_contains "${state_dir}/git.log" "switch --create issue/${QUEUE_ISSUE_NUMBER}"
  assert_file_not_contains "${state_dir}/git.log" "switch --create issue/${ISSUE_NUMBER}"
  assert_file_contains "${state_dir}/gh.log" "issue view ${QUEUE_ISSUE_NUMBER}"
  assert_file_contains "${state_dir}/gh.log" "issue view ${ISSUE_NUMBER}"
  assert_file_not_contains "${state_dir}/gh.log" '--head issue/'
  assert_file_contains "${state_dir}/gh.log" "pr create --base main --head batch/${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}"
  assert_equals "Batch: address issues #${QUEUE_ISSUE_NUMBER}-#${ISSUE_NUMBER}" "$(< "${state_dir}/batch-pr-create-title.txt")" 'batch PR title'
  assert_file_contains "${state_dir}/batch-pr-create-body.txt" "Closes #${QUEUE_ISSUE_NUMBER}"
  assert_file_contains "${state_dir}/batch-pr-create-body.txt" "Closes #${ISSUE_NUMBER}"
  assert_file_contains "${state_dir}/batch-pr-create-body.txt" "#${QUEUE_ISSUE_NUMBER} ${QUEUE_ISSUE_TITLE}"
  assert_file_contains "${state_dir}/batch-pr-create-body.txt" "#${ISSUE_NUMBER} ${ISSUE_TITLE}"

  assert_file_exists "${batch_dir}/issues.txt"
  assert_file_order "${batch_dir}/issues.txt" "# Issue #${QUEUE_ISSUE_NUMBER}" "# Issue #${ISSUE_NUMBER}"
  assert_file_exists "${batch_dir}/base_commit"
  assert_file_exists "${batch_dir}/head_commit"
  assert_file_exists "${batch_dir}/changed-files.txt"
  assert_file_exists "${batch_dir}/batch.diff"
  assert_file_exists "${batch_dir}/batch.untracked.txt"
  assert_file_exists "${batch_dir}/batch.summary.txt"
  assert_file_exists "${batch_dir}/checks.log"
  assert_file_exists "${batch_dir}/token-usage.tsv"
  assert_file_exists "${batch_dir}/batch-review.prompt.md"
  assert_file_exists "${batch_dir}/batch-review.raw.txt"
  assert_file_exists "${batch_dir}/batch-review.txt"
  assert_file_exists "${batch_dir}/fix-from-batch-review.prompt.md"
  assert_file_exists "${batch_dir}/fix-from-batch-review.log"
  assert_file_exists "${batch_dir}/history/batch-review.round-01.txt"
  assert_file_exists "${batch_dir}/history/batch-review.round-02.txt"
  assert_file_exists "${batch_dir}/history/batch-summary.round-01.txt"
  assert_file_exists "${batch_dir}/history/batch-summary.round-02.txt"
  assert_file_exists "${batch_dir}/history/batch-review-raw.round-01.txt"
  assert_file_exists "${batch_dir}/history/batch-review-raw.round-02.txt"
  assert_file_exists "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/implementation.prompt.md"
  assert_file_exists "${batch_dir}/issues/${ISSUE_NUMBER}/codex/implementation.prompt.md"
  assert_file_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/implementation.prompt.md" "issue #${QUEUE_ISSUE_NUMBER}"
  assert_file_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/implementation.prompt.md" "issue #${ISSUE_NUMBER}"
  assert_file_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/review.prompt.md" "queue smoke review for issue #${QUEUE_ISSUE_NUMBER}"
  assert_file_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/review.prompt.md" "queue smoke review for issue #${ISSUE_NUMBER}"
  assert_file_not_contains "${batch_dir}/issues/${QUEUE_ISSUE_NUMBER}/codex/review.prompt.md" 'strict batch review session'
  assert_file_not_contains "${batch_dir}/issues/${ISSUE_NUMBER}/codex/review.prompt.md" 'strict batch review session'
  assert_file_contains "${batch_dir}/batch-review.prompt.md" 'strict batch review session'
  assert_file_contains "${batch_dir}/batch-review.prompt.md" ".work/queue/batches/batch-${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}/batch.summary.txt"
  assert_file_not_contains "${batch_dir}/batch-review.prompt.md" 'queue smoke review'
  assert_file_contains "${batch_dir}/history/batch-review-raw.round-01.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_equals $'phase\tissues\tround\treasoning\ttokens\tlog' "$(head -n 1 "${batch_dir}/token-usage.tsv")" 'batch token usage header'
  assert_file_contains "${batch_dir}/history/batch-review-raw.round-02.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${batch_dir}/batch-review.raw.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${batch_dir}/batch-review.txt" 'accept: yes'
  assert_file_not_contains "${batch_dir}/history/batch-review.round-01.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "${batch_dir}/history/batch-review.round-02.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_not_contains "${batch_dir}/batch-review.txt" "$CODEX_RUNTIME_SESSION_LOG_LINE"
  assert_file_contains "${batch_dir}/fix-from-batch-review.log" 'applied batch review fix round 1'
  assert_file_contains "${repo_dir}/smoke-target.txt" 'batch review fix round 1'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=queue_review'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=queue_fix'
  assert_file_contains "${state_dir}/codex.log" 'strict batch review session'
  assert_file_contains "${state_dir}/codex.log" 'Make the required batch-review fixes, then stop.'
  assert_file_contains "${queue_log}" 'publish skipped because CODEX_FLOW_SKIP_PUBLISH is set'
  assert_file_contains "${state_dir}/run-changed-args.txt" "$(< "${batch_dir}/base_commit")"
  assert_file_contains "${batch_dir}/changed-files.txt" 'smoke-target.txt'
  assert_commit_includes_path HEAD 'smoke-target.txt'
  assert_commit_excludes_internal_paths HEAD
  run_dir="$(grep -l $'^issues\t41,40$' "${repo_dir}"/.work/queue/runs/*/manifest.state | head -n 1)"
  run_dir="${run_dir%/manifest.state}"
  assert_file_contains "${run_dir}/manifest.state" $'issues\t41,40'
  assert_file_contains "${run_dir}/manifest.state" $'review_every\t2'
  assert_file_contains "${run_dir}/manifest.state" $'batch_review_reasoning\tqueue_review'
  assert_file_contains "${run_dir}/run.state" $'state\tcompleted'
  assert_file_contains "${run_dir}/batches/batch-${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}/issues/${QUEUE_ISSUE_NUMBER}.state" $'state\tacknowledged'
  assert_file_contains "${run_dir}/batches/batch-${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}/issues/${ISSUE_NUMBER}.state" $'state\tacknowledged'
  assert_file_contains "${run_dir}/batches/batch-${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}/publish.state" "head_branch$(printf '\t')batch/${QUEUE_ISSUE_NUMBER}-${ISSUE_NUMBER}"
  assert_path_not_exists "${repo_dir}/.work/queue/current"

  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume current
  ) > "${state_dir}/queue-completed-current.log" 2>&1; then
    fail 'completed queue current finalization should be idempotently successful'
  fi
  assert_file_contains "${state_dir}/queue-completed-current.log" 'control plane is already finalized'

  if (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$(basename "$run_dir")" --review-every 1
  ) > "${state_dir}/queue-resume-options.log" 2>&1; then
    fail 'resume must reject changed queue options'
  fi
  assert_file_contains "${state_dir}/queue-resume-options.log" '--resume accepts only a run ID/current'
}

run_queue_lease_smoke() {
  local helper="${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/lib/queue_state.sh" lease="${repo_dir}/.work/queue/lease.lock" log_file run_id other_run other_state token='smoke-owner-token' owner_start
  local pause="${state_dir}/queue-takeover-pause" takeover_barrier="${state_dir}/queue-takeover-barrier"
  local takeover_pid takeover_two_pid takeover_winner takeover_loser takeover_label replacement_record replacement_token replacement_generation attempt
  log 'running queue lease smoke'
  run_id="$(basename "$(dirname "$(grep -L $'^state\tcompleted$' "${repo_dir}"/.work/queue/runs/*/run.state | head -n 1)")")"
  owner_start="$(awk '{print $22}' "/proc/$$/stat")"
  mkdir -p "$lease"
  QUEUE_STATE_HELPER="$helper" QUEUE_LEASE="$lease" QUEUE_OWNER_PID="$$" QUEUE_OWNER_START="$owner_start" QUEUE_RUN_ID="$run_id" QUEUE_TOKEN="$token" bash -c '
set -euo pipefail; source "$QUEUE_STATE_HELPER"; : > "${QUEUE_LEASE}.guard"; queue_state_configure_guard "${QUEUE_LEASE}.guard"; queue_state_write_lease "$QUEUE_LEASE/owner.${QUEUE_TOKEN}.state" "$QUEUE_RUN_ID" "$QUEUE_TOKEN" 1 "$QUEUE_OWNER_PID" "$(hostname 2>/dev/null || uname -n)" "$QUEUE_OWNER_START"
'
  log_file="${state_dir}/queue-live-lease.log"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "$log_file" 2>&1; then
    fail 'live same-host queue lease must block another runner'
  fi
  assert_file_contains "$log_file" 'leased by live same-host PID'

  rm -rf "$lease"; mkdir -p "$lease"
  QUEUE_STATE_HELPER="$helper" QUEUE_LEASE="$lease" QUEUE_RUN_ID="$run_id" QUEUE_TOKEN="$token" bash -c '
set -euo pipefail; source "$QUEUE_STATE_HELPER"; : > "${QUEUE_LEASE}.guard"; queue_state_configure_guard "${QUEUE_LEASE}.guard"; queue_state_write_lease "$QUEUE_LEASE/owner.${QUEUE_TOKEN}.state" "$QUEUE_RUN_ID" "$QUEUE_TOKEN" 1 999999 different-host unavailable
'
  log_file="${state_dir}/queue-foreign-lease.log"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id") > "$log_file" 2>&1; then
    fail 'different-host queue lease must require explicit takeover'
  fi
  assert_file_contains "$log_file" 'with --take-over-lease'
  log_file="${state_dir}/queue-stale-new-run.log"
  if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" 99) > "$log_file" 2>&1; then
    fail 'fresh run must reject a stale unfinished lease'
  fi
  assert_file_contains "$log_file" "resume with: ${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh --resume ${run_id}"
  assert_file_not_contains "$log_file" 'command not found'
  other_run="$(find "${repo_dir}/.work/queue/runs" -mindepth 1 -maxdepth 1 -type d ! -name "$run_id" -printf '%f\n' | head -n 1)"
  other_state="$(awk -F '\t' '$1 == "state" { print $2 }' "${repo_dir}/.work/queue/runs/${other_run}/run.state")"
  log_file="${state_dir}/queue-lease-run-mismatch.log"
  if [[ "$other_state" == completed ]]; then
    if ! (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$other_run" --take-over-lease) > "$log_file" 2>&1; then
      fail 'already-finalized completed run should ignore another run lease'
    fi
    assert_file_contains "$log_file" 'control plane is already finalized'
    assert_file_exists "$lease/owner.${token}.state"
  else
    if (cd "$repo_dir"; PATH="${stub_dir}:$PATH" "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$other_run" --take-over-lease) > "$log_file" 2>&1; then
      fail 'resume run-ID mismatch must not consume another run lease'
    fi
    if ! grep -Fq "Queue lease run ${run_id} conflicts with requested run ${other_run}" "$log_file" && \
       ! grep -Fq "Queue lease belongs to different run ${run_id}" "$log_file"; then
      fail 'different-run resume did not preserve the conflicting lease'
    fi
  fi
  rm -rf "$pause" "$takeover_barrier"; mkdir -p "$pause" "$takeover_barrier"
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch CODEX_FLOW_QUEUE_TEST_BARRIER_DIR="$takeover_barrier" CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=takeover-one "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id" --take-over-lease
  ) > "${state_dir}/queue-takeover-one.log" 2>&1 & takeover_pid=$!
  (
    cd "$repo_dir"
    PATH="${stub_dir}:$PATH" CODEX_FLOW_QUEUE_TEST_MODE=1 CODEX_FLOW_QUEUE_FAILPOINT=after_lease_before_issue_fetch CODEX_FLOW_QUEUE_TEST_BARRIER_DIR="$takeover_barrier" CODEX_FLOW_QUEUE_TEST_PAUSE_DIR="$pause" CODEX_FLOW_QUEUE_TEST_PAUSE_AT=after_acquire \
      CODEX_FLOW_QUEUE_TEST_RUNNER_LABEL=takeover-two "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" --resume "$run_id" --take-over-lease
  ) > "${state_dir}/queue-takeover-two.log" 2>&1 & takeover_two_pid=$!
  for ((attempt = 0; attempt < 1000; attempt += 1)); do
    [[ -f "$takeover_barrier/ready.lease_acquire.takeover-one" && -f "$takeover_barrier/ready.lease_acquire.takeover-two" ]] && break
    sleep 0.01
  done
  touch "$takeover_barrier/release.lease_acquire"
  for ((attempt = 0; attempt < 1000; attempt += 1)); do compgen -G "$pause/paused.after_acquire.takeover-*" >/dev/null && break; sleep 0.01; done
  if [[ -f "$pause/paused.after_acquire.takeover-one" ]]; then
    takeover_winner="$takeover_pid"; takeover_loser="$takeover_two_pid"; takeover_label=takeover-one
  elif [[ -f "$pause/paused.after_acquire.takeover-two" ]]; then
    takeover_winner="$takeover_two_pid"; takeover_loser="$takeover_pid"; takeover_label=takeover-two
  else
    fail 'explicit takeover contention produced no replacement owner'
  fi
  if wait "$takeover_loser"; then fail 'second takeover contender unexpectedly succeeded'; fi
  replacement_record="$(find "$lease" -maxdepth 1 -type f -name 'owner.*.state')"
  replacement_token="$(awk -F '\t' '$1 == "owner_token" { print $2 }' "$replacement_record")"
  replacement_generation="$(awk -F '\t' '$1 == "lease_generation" { print $2 }' "$replacement_record")"
  [[ "$replacement_token" != "$token" ]] || fail 'takeover must rotate owner token'
  assert_equals 2 "$replacement_generation" 'takeover lease generation'
  assert_equals 1 "$(find "$lease" -maxdepth 1 -type f -name 'owner.*.state' | wc -l)" 'takeover authoritative owner count'
  if find "${repo_dir}/.work/queue" -path '*/lease.lock/lease.lock' -print -quit | grep -q .; then fail 'takeover must not nest lease.lock'; fi
  touch "$pause/release.after_acquire.${takeover_label}"
  if wait "$takeover_winner"; then fail 'takeover winner should stop at the deterministic pre-Issue failpoint'; fi
  if ! grep -Fq 'explicitly taking over lease' "${state_dir}/queue-takeover-one.log" && ! grep -Fq 'explicitly taking over lease' "${state_dir}/queue-takeover-two.log"; then
    fail 'takeover winner did not report explicit displacement'
  fi
  assert_path_not_exists "$lease"
  rm -f -- "${repo_dir}/.work/queue/current" "${repo_dir}/.work/queue/current_batch"
}

run_vendor_worktree_visibility_smoke() {
  local status_log="${state_dir}/vendor-visibility.status.txt"
  local review_diff_log="${state_dir}/vendor-visibility.review.diff"
  local review_untracked_log="${state_dir}/vendor-visibility.review.untracked.txt"
  local review_summary_log="${state_dir}/vendor-visibility.review.summary.txt"
  local staged_log="${state_dir}/vendor-visibility.staged.txt"

  log 'running vendor visibility smoke'
  printf 'tracked dirty change\n' >> "${repo_dir}/vendor/tracked.txt"
  printf 'binary dirty\0change\n' > "${repo_dir}/binary-target.dat"
  printf 'untracked vendor change\n' > "${repo_dir}/vendor/other.txt"
  clear_command_logs

  (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" bash -c '
set -euo pipefail
source vendor/issue_forge/tools/codex/lib/config.sh
source vendor/issue_forge/tools/codex/lib/flow_state.sh
source vendor/issue_forge/tools/codex/lib/checks_review_helpers.sh
source vendor/issue_forge/tools/codex/lib/publish_helpers.sh
review_diff="'"${review_diff_log}"'"
review_untracked="'"${review_untracked_log}"'"
review_summary="'"${review_summary_log}"'"
status_outside_work > "'"${status_log}"'"
generate_review_material
stage_issue_flow_changes
git diff --cached --name-only > "'"${staged_log}"'"
'
  )

  assert_file_contains "${status_log}" 'vendor/other.txt'
  assert_file_contains "${status_log}" 'vendor/tracked.txt'
  assert_path_list_excludes_path_regex "${status_log}" '\.work' '.work'
  assert_path_list_excludes_path_regex "${status_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_file_contains "${review_diff_log}" 'vendor/other.txt'
  assert_file_contains "${review_diff_log}" 'vendor/tracked.txt'
  assert_file_not_contains "${review_diff_log}" 'GIT binary patch'
  assert_diff_file_excludes_path_regex "${review_diff_log}" '\.work' '.work'
  assert_diff_file_excludes_path_regex "${review_diff_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_file_contains "${review_untracked_log}" 'vendor/other.txt'
  assert_path_list_excludes_path_regex "${review_untracked_log}" '\.work' '.work'
  assert_path_list_excludes_path_regex "${review_untracked_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_file_contains "${review_summary_log}" 'base commit:'
  assert_file_contains "${review_summary_log}" 'diff stat:'
  assert_file_contains "${review_summary_log}" 'name status:'
  assert_file_contains "${review_summary_log}" 'numstat:'
  assert_file_contains "${review_summary_log}" 'untracked files:'
  assert_file_contains "${review_summary_log}" 'binary files changed:'
  assert_file_contains "${review_summary_log}" $'M\tbinary-target.dat'
  assert_file_not_contains "${review_summary_log}" 'GIT binary patch'
  assert_file_contains "${staged_log}" 'vendor/other.txt'
  assert_file_contains "${staged_log}" 'vendor/tracked.txt'
  assert_path_list_excludes_path_regex "${staged_log}" '\.work' '.work'
  assert_path_list_excludes_path_regex "${staged_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_staging_uses_concrete_pathspecs "${state_dir}/git.log"
}

run_no_workflow_file_smoke() {
  local workflow_file

  log 'running no workflow file smoke'
  assert_path_not_exists "${repo_dir}/.github/workflows"

  if [[ -d "${REPO_ROOT}/.github/workflows" ]]; then
    workflow_file="$(find "${REPO_ROOT}/.github/workflows" -type f | head -n 1)"
    if [[ -n "${workflow_file}" ]]; then
      fail "expected no GitHub workflow files to exist, found ${workflow_file}"
    fi
  fi
}

cleanup() {
  if [[ -n "${temp_root:-}" && -d "${temp_root}" ]]; then
    rm -rf "${temp_root}"
  fi
}

main() {
  trap cleanup EXIT
  assert_source_checks_command_executable
  create_fixture_repo
  run_consumer_init_smoke
  run_start_from_issue_smoke
  advance_origin_main_after_bootstrap
  run_make_pr_only_smoke
  run_issue_flow_skip_publish_smoke
  run_pr_body_utf8_smoke
  run_pr_body_review_count_smoke
  run_doctor_smoke
  run_invalid_consumer_root_smoke
  run_run_codex_retry_smoke
  run_run_codex_smoke
  run_codex_profile_smoke
  run_token_usage_parser_smoke
  run_review_output_validation_smoke
  run_issue_flow_smoke
  run_restart_issue_flow_smoke
  run_continue_after_review_smoke
  run_queue_state_store_smoke
  run_issue_queue_fail_fast_smoke
  run_queue_legacy_control_plane_smoke
  run_queue_singleton_path_type_smoke
  run_queue_acquisition_crash_smoke
  run_queue_full_contention_smoke
  run_issue_queue_smoke
  run_queue_lease_smoke
  run_issue_queue_strict_issue_review_smoke
  run_queue_completion_cleanup_transaction_smoke
  run_queue_completion_cleanup_invariant_smoke
  run_queue_linked_worktree_rejection_smoke
  run_queue_worker_registration_smoke
  run_queue_worker_phase_checkpoint_smoke
  run_queue_private_environment_smoke
  run_queue_external_orphan_smoke
  run_queue_guard_path_stability_smoke
  run_queue_entity_integrity_smoke
  run_vendor_worktree_visibility_smoke
  run_no_workflow_file_smoke
  log 'all smoke scenarios passed'
}

main "$@"
