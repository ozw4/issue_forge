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
readonly QUEUE_FIRST_ISSUE_NUMBER=41
readonly QUEUE_FIRST_ISSUE_TITLE='Queue First Issue'
readonly QUEUE_FIRST_ISSUE_URL='https://example.test/issues/41'
readonly QUEUE_SECOND_ISSUE_NUMBER=42
readonly QUEUE_SECOND_ISSUE_TITLE='Queue Second Issue'
readonly QUEUE_SECOND_ISSUE_URL='https://example.test/issues/42'
readonly UTF8_PR_BODY_TITLE='Regression Harness Issue 🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀'
readonly UTF8_CHECKS_LINE='checks passed with emoji 🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪'
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

assert_fixed_line_count() {
  local path="$1"
  local pattern="$2"
  local expected_count="$3"
  local message="$4"
  local actual_count

  actual_count="$(grep -Fxc -- "$pattern" "$path" || true)"
  assert_equals "${expected_count}" "${actual_count}" "${message}"
}

assert_line_order() {
  local path="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local message="$4"
  local first_line
  local second_line

  first_line="$(grep -Fn -- "$first_pattern" "$path" | sed -n '1{s/:.*//;p;}' || true)"
  second_line="$(grep -Fn -- "$second_pattern" "$path" | sed -n '1{s/:.*//;p;}' || true)"

  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    printf '[smoke] line order assertion failed: %s\n' "$message" >&2
    printf '[smoke] first pattern: %s\n' "$first_pattern" >&2
    printf '[smoke] second pattern: %s\n' "$second_pattern" >&2
    exit 1
  fi
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
    "${state_dir}/fix-checks-count.txt" \
    "${state_dir}/fix-review-count.txt" \
    "${state_dir}/implementation-count.txt" \
    "${state_dir}/review-count.txt" \
    "${state_dir}/run-changed-args.txt"
}

write_fixture_files() {
  cat > "${repo_dir}/smoke-target.txt" <<'EOF'
baseline
EOF

  cat > "${repo_dir}/vendor/tracked.txt" <<'EOF'
tracked baseline
EOF
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

copy_flag_value_to_file() {
  local flag="\$1"
  local destination="\$2"
  shift 2
  local value

  if ! value="\$(flag_value "\$flag" "\$@")"; then
    printf 'Missing required gh flag: %s\n' "\$flag" >&2
    exit 1
  fi

  cp "\$value" "\$destination"
}

write_flag_value_to_file() {
  local flag="\$1"
  local destination="\$2"
  shift 2
  local value

  if ! value="\$(flag_value "\$flag" "\$@")"; then
    printf 'Missing required gh flag: %s\n' "\$flag" >&2
    exit 1
  fi

  printf '%s\n' "\$value" > "\$destination"
}

issue_title_for_number() {
  case "\$1" in
    ${ISSUE_NUMBER})
      printf '%s\n' "${ISSUE_TITLE}"
      ;;
    ${QUEUE_FIRST_ISSUE_NUMBER})
      printf '%s\n' "${QUEUE_FIRST_ISSUE_TITLE}"
      ;;
    ${QUEUE_SECOND_ISSUE_NUMBER})
      printf '%s\n' "${QUEUE_SECOND_ISSUE_TITLE}"
      ;;
    *)
      printf 'Unsupported fixture issue number: %s\n' "\$1" >&2
      exit 1
      ;;
  esac
}

issue_url_for_number() {
  case "\$1" in
    ${ISSUE_NUMBER})
      printf '%s\n' "${ISSUE_URL}"
      ;;
    ${QUEUE_FIRST_ISSUE_NUMBER})
      printf '%s\n' "${QUEUE_FIRST_ISSUE_URL}"
      ;;
    ${QUEUE_SECOND_ISSUE_NUMBER})
      printf '%s\n' "${QUEUE_SECOND_ISSUE_URL}"
      ;;
    *)
      printf 'Unsupported fixture issue number: %s\n' "\$1" >&2
      exit 1
      ;;
  esac
}

issue_number_for_branch() {
  local branch="\$1"
  local issue_number

  issue_number="\${branch#issue/}"
  issue_number="\${issue_number%%-*}"

  if [[ -z "\$issue_number" || "\$issue_number" == "\$branch" ]]; then
    printf 'unknown\n'
    return 0
  fi

  printf '%s\n' "\$issue_number"
}

pr_state_file_for_branch() {
  local branch="\$1"
  local issue_number

  issue_number="\$(issue_number_for_branch "\$branch")"
  printf '%s/pr-url.%s.txt\n' "${state_dir}" "\$issue_number"
}

pr_url_for_branch() {
  local branch="\$1"
  local issue_number

  issue_number="\$(issue_number_for_branch "\$branch")"
  printf 'https://example.test/pr/%s\n' "\$issue_number"
}

if [[ "\$#" -ge 3 && "\$1" == "issue" && "\$2" == "view" ]]; then
  issue_number="\$3"
  issue_title="\$(issue_title_for_number "\$issue_number")"
  issue_url="\$(issue_url_for_number "\$issue_number")"

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

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "list" ]]; then
  head_branch="\$(flag_value '--head' "\$@")"
  pr_state_file="\$(pr_state_file_for_branch "\$head_branch")"
  if [[ -f "\$pr_state_file" ]]; then
    cat "\$pr_state_file"
    exit 0
  fi

  printf '\n'
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "create" ]]; then
  head_branch="\$(flag_value '--head' "\$@")"
  pr_url="\$(pr_url_for_branch "\$head_branch")"
  copy_flag_value_to_file '--body-file' "${state_dir}/pr-create-body.txt" "\$@"
  write_flag_value_to_file '--title' "${state_dir}/pr-create-title.txt" "\$@"
  printf '%s\n' "\$pr_url" > "\$(pr_state_file_for_branch "\$head_branch")"
  printf '%s\n' "\$pr_url"
  exit 0
fi

if [[ "\$#" -ge 2 && "\$1" == "pr" && "\$2" == "edit" ]]; then
  copy_flag_value_to_file '--body-file' "${state_dir}/pr-edit-body.txt" "\$@"
  write_flag_value_to_file '--title' "${state_dir}/pr-edit-title.txt" "\$@"
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
  local missing_repo="${temp_root}/init-missing"
  local readme_repo="${temp_root}/init-readme"
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
  assert_path_not_exists "${missing_repo}/README.md"
  assert_path_not_exists "${missing_repo}/docs/README.md"

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
  local doctor_failure_log="${state_dir}/doctor-failure.log"
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

run_run_codex_smoke() {
  log 'running run_codex.sh mode smoke'

  write_prompt="${prompt_dir}/write.prompt.md"
  read_prompt="${prompt_dir}/read.prompt.md"
  printf 'write prompt\n' > "${write_prompt}"
  printf 'read prompt\n' > "${read_prompt}"

  write_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" write "${write_prompt}"
  )"
  read_output="$(
    PATH="${stub_dir}:$PATH" "${repo_dir}/${FIXTURE_ENGINE_CODEX_PATH}/run_codex.sh" read "${read_prompt}"
  )"

  assert_equals 'stub codex ok' "${write_output}" 'write mode stdout'
  assert_equals 'stub codex ok' "${read_output}" 'read mode stdout'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=xhigh'
  assert_file_contains "${state_dir}/codex.log" 'args: exec --sandbox danger-full-access --config model_reasoning_effort=medium'

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

  assert_equals $'write-profile=write\nwrite-sandbox=danger-full-access\nwrite-reasoning=xhigh\nread-profile=read\nread-sandbox=danger-full-access\nread-reasoning=medium' "${profile_report}" 'profile resolution output'

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
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=xhigh
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
readonly CODEX_FLOW_PROFILE_WRITE_REASONING=xhigh
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
Read AGENTS.md if present, then README.md, then docs/README.md if present.
Then read .work/issues/${ISSUE_NUMBER}.md.

You are the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md if present
2. README.md
3. docs/README.md if present and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

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
Read AGENTS.md if present, then README.md, then docs/README.md if present.
Then read .work/issues/${ISSUE_NUMBER}.md and .work/codex/checks.log.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md if present
2. README.md
3. docs/README.md if present and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

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
Read AGENTS.md if present, then README.md, then docs/README.md if present.
Then read .work/issues/${ISSUE_NUMBER}.md, .work/codex/review.diff, and .work/codex/review.untracked.txt.

You are the review session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md if present
2. README.md
3. docs/README.md if present and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

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
Read AGENTS.md if present, then README.md, then docs/README.md if present.
Then read .work/issues/${ISSUE_NUMBER}.md and .work/codex/review.txt.

You are continuing the implementation session for issue #${ISSUE_NUMBER}.

Priority order:
1. AGENTS.md if present
2. README.md
3. docs/README.md if present and source-of-truth docs
4. the GitHub issue body and provided .work artifacts
5. this prompt

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

run_issue_queue_smoke() {
  local queue_log="${state_dir}/issue-queue.log"
  local first_branch="issue/${QUEUE_FIRST_ISSUE_NUMBER}-queue-first-issue"
  local second_branch="issue/${QUEUE_SECOND_ISSUE_NUMBER}-queue-second-issue"
  local pr_create_count

  log 'running run_issue_queue.sh smoke'
  clear_command_logs
  reset_flow_counters
  mkdir -p "${repo_dir}/.work/codex"
  printf 'stale queue artifact\n' > "${repo_dir}/.work/codex/stale-sentinel.txt"

  if ! (
    cd "${repo_dir}"
    PATH="${stub_dir}:$PATH" \
      SMOKE_CHECKS_COUNT_FILE="${state_dir}/checks-count.txt" \
      SMOKE_RUN_CHANGED_ARGS_FILE="${state_dir}/run-changed-args.txt" \
      "./${FIXTURE_ENGINE_CODEX_PATH}/run_issue_queue.sh" \
        "${QUEUE_FIRST_ISSUE_NUMBER}" \
        "${QUEUE_SECOND_ISSUE_NUMBER}"
  ) > "${queue_log}" 2>&1; then
    fail 'run_issue_queue.sh should succeed for two explicit issue numbers'
  fi

  assert_line_order \
    "${queue_log}" \
    "[queue] starting issue ${QUEUE_FIRST_ISSUE_NUMBER} (1/2)" \
    "[queue] starting issue ${QUEUE_SECOND_ISSUE_NUMBER} (2/2)" \
    'queue issues should run in input order'
  assert_line_order \
    "${state_dir}/gh.log" \
    "issue view ${QUEUE_FIRST_ISSUE_NUMBER}" \
    "issue view ${QUEUE_SECOND_ISSUE_NUMBER}" \
    'queue gh issue views should run in input order'

  assert_file_contains "${state_dir}/gh.log" "issue view ${QUEUE_FIRST_ISSUE_NUMBER} --json title --jq .title"
  assert_file_contains "${state_dir}/gh.log" "issue view ${QUEUE_SECOND_ISSUE_NUMBER} --json title --jq .title"
  assert_file_contains "${state_dir}/gh.log" "issue view ${QUEUE_FIRST_ISSUE_NUMBER} --json number,title,body,url --template"
  assert_file_contains "${state_dir}/gh.log" "issue view ${QUEUE_SECOND_ISSUE_NUMBER} --json number,title,body,url --template"

  pr_create_count="$(grep -Fc 'pr create ' "${state_dir}/gh.log" || true)"
  assert_equals '2' "${pr_create_count}" 'queue PR create count'
  assert_file_contains "${state_dir}/gh.log" "pr create --draft --base main --head ${first_branch}"
  assert_file_contains "${state_dir}/gh.log" "pr create --draft --base main --head ${second_branch}"

  assert_equals "${QUEUE_SECOND_ISSUE_NUMBER}" "$(< "${repo_dir}/.work/current_issue")" 'queue final current issue'
  assert_equals "${second_branch}" "$(< "${repo_dir}/.work/current_branch")" 'queue final current branch'
  assert_equals "${second_branch}" "$("${REAL_GIT}" -C "${repo_dir}" branch --show-current)" 'queue checked-out branch'
  assert_file_exists "${repo_dir}/.work/issues/${QUEUE_FIRST_ISSUE_NUMBER}.md"
  assert_file_exists "${repo_dir}/.work/issues/${QUEUE_SECOND_ISSUE_NUMBER}.md"
  assert_file_contains "${repo_dir}/.work/issues/${QUEUE_FIRST_ISSUE_NUMBER}.md" "Title: ${QUEUE_FIRST_ISSUE_TITLE}"
  assert_file_contains "${repo_dir}/.work/issues/${QUEUE_SECOND_ISSUE_NUMBER}.md" "Title: ${QUEUE_SECOND_ISSUE_TITLE}"
  assert_path_not_exists "${repo_dir}/.work/codex/stale-sentinel.txt"

  assert_file_contains "${queue_log}" "[flow] pushing branch ${first_branch}"
  assert_file_contains "${queue_log}" "[flow] pushing branch ${second_branch}"
  assert_file_contains "${queue_log}" "[flow] created PR: https://example.test/pr/${QUEUE_FIRST_ISSUE_NUMBER}"
  assert_file_contains "${queue_log}" "[flow] created PR: https://example.test/pr/${QUEUE_SECOND_ISSUE_NUMBER}"
  assert_file_contains "${state_dir}/git.log" "push --set-upstream origin ${first_branch}"
  assert_file_contains "${state_dir}/git.log" "push --set-upstream origin ${second_branch}"
}

run_vendor_worktree_visibility_smoke() {
  local status_log="${state_dir}/vendor-visibility.status.txt"
  local review_diff_log="${state_dir}/vendor-visibility.review.diff"
  local review_untracked_log="${state_dir}/vendor-visibility.review.untracked.txt"
  local staged_log="${state_dir}/vendor-visibility.staged.txt"

  log 'running vendor visibility smoke'
  printf 'tracked dirty change\n' >> "${repo_dir}/vendor/tracked.txt"
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
  assert_diff_file_excludes_path_regex "${review_diff_log}" '\.work' '.work'
  assert_diff_file_excludes_path_regex "${review_diff_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_file_contains "${review_untracked_log}" 'vendor/other.txt'
  assert_path_list_excludes_path_regex "${review_untracked_log}" '\.work' '.work'
  assert_path_list_excludes_path_regex "${review_untracked_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_file_contains "${staged_log}" 'vendor/other.txt'
  assert_file_contains "${staged_log}" 'vendor/tracked.txt'
  assert_path_list_excludes_path_regex "${staged_log}" '\.work' '.work'
  assert_path_list_excludes_path_regex "${staged_log}" 'vendor/issue_forge' 'vendor/issue_forge'
  assert_staging_uses_concrete_pathspecs "${state_dir}/git.log"
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
  run_pr_body_utf8_smoke
  run_pr_body_review_count_smoke
  run_doctor_smoke
  run_invalid_consumer_root_smoke
  run_run_codex_smoke
  run_codex_profile_smoke
  run_review_output_validation_smoke
  run_issue_flow_smoke
  run_restart_issue_flow_smoke
  run_continue_after_review_smoke
  run_issue_queue_smoke
  run_vendor_worktree_visibility_smoke
  log 'all smoke scenarios passed'
}

main "$@"
