#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: tools/consumer/init.sh [--scaffold-checks|--scaffold-run] [consumer-root]\n' >&2
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '%s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

note() {
  printf 'note: %s\n' "$1" >&2
}

resolve_consumer_root() {
  local candidate
  local git_root

  if [[ "$#" -eq 1 ]]; then
    candidate="$1"

    if [[ ! -d "${candidate}" ]]; then
      die "consumer root is not a directory: ${candidate}"
    fi

    if ! candidate="$(cd "${candidate}" && pwd)"; then
      die "failed to resolve consumer root: ${1}"
    fi
  else
    if ! candidate="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      die 'not inside a git worktree. Run from the consumer repo root or pass [consumer-root].'
    fi
  fi

  if ! git_root="$(git -C "${candidate}" rev-parse --show-toplevel 2>/dev/null)"; then
    die "not a git worktree: ${candidate}"
  fi

  printf '%s\n' "${git_root}"
}

parse_args() {
  SCAFFOLD_CHECKS=0
  SCAFFOLD_RUN=0
  CONSUMER_ROOT_ARG=''

  case "$#" in
    0)
      ;;
    1)
      case "$1" in
        --scaffold-checks)
          SCAFFOLD_CHECKS=1
          ;;
        --scaffold-run)
          SCAFFOLD_RUN=1
          ;;
        -*)
          usage
          exit 1
          ;;
        *)
          CONSUMER_ROOT_ARG="$1"
          ;;
      esac
      ;;
    2)
      case "$1" in
        --scaffold-checks)
          SCAFFOLD_CHECKS=1
          ;;
        --scaffold-run)
          SCAFFOLD_RUN=1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
      if [[ "$2" == -* ]]; then
        usage
        exit 1
      fi
      CONSUMER_ROOT_ARG="$2"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

ensure_file_ends_with_newline() {
  local path="$1"

  if [[ -s "${path}" && -n "$(tail -c 1 "${path}")" ]]; then
    if ! printf '\n' >> "${path}"; then
      die "unable to write ${path}"
    fi
  fi
}

append_gitignore_entry() {
  local gitignore_path="$1"
  local entry="$2"

  if grep -Fxq "${entry}" "${gitignore_path}"; then
    return 1
  fi

  ensure_file_ends_with_newline "${gitignore_path}"
  if ! printf '%s\n' "${entry}" >> "${gitignore_path}"; then
    die "unable to write ${gitignore_path}"
  fi

  log "added .gitignore entry: ${entry}"
  return 0
}

ensure_gitignore_configured() {
  local consumer_root="$1"
  local gitignore_path="${consumer_root}/.gitignore"
  local entry
  local added_any=0

  if [[ ! -f "${gitignore_path}" ]]; then
    if ! : > "${gitignore_path}"; then
      die "unable to write ${gitignore_path}"
    fi
    log 'created .gitignore'
  fi

  for entry in \
    '.work' \
    '.work/' \
    'vendor/issue_forge' \
    'vendor/issue_forge/'
  do
    if append_gitignore_entry "${gitignore_path}" "${entry}"; then
      added_any=1
    fi
  done

  if [[ "${added_any}" -eq 0 ]]; then
    log '.gitignore is already configured'
  fi
}

ensure_project_config() {
  local consumer_root="$1"
  local project_dir="${consumer_root}/.issue_forge"
  local project_path="${project_dir}/project.sh"

  if [[ -f "${project_path}" ]]; then
    log '.issue_forge/project.sh already exists'
    return 0
  fi

  if ! mkdir -p "${project_dir}"; then
    die "unable to create ${project_dir}"
  fi

  if ! cat > "${project_path}" <<'EOF'
# issue_forge consumer config.
# Defaults are supplied by vendor/issue_forge.
EOF
  then
    die "unable to write ${project_path}"
  fi

  log 'created .issue_forge/project.sh'
}

write_consumer_checks_starter() {
  local checks_path="$1"

  if ! cat > "${checks_path}" <<'EOF'
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
  then
    die "unable to write ${checks_path}"
  fi
}

ensure_checks_scaffold() {
  local consumer_root="$1"
  local checks_dir="${consumer_root}/.issue_forge/checks"
  local checks_path="${checks_dir}/run_changed.sh"

  if [[ -e "${checks_path}" ]]; then
    log '.issue_forge/checks/run_changed.sh already exists'
    return 0
  fi

  if ! mkdir -p "${checks_dir}"; then
    die "unable to create ${checks_dir}"
  fi

  write_consumer_checks_starter "${checks_path}"

  if ! chmod +x "${checks_path}"; then
    die "unable to make ${checks_path} executable"
  fi

  log 'created .issue_forge/checks/run_changed.sh'
}

write_consumer_run_wrapper() {
  local wrapper_path="$1"

  if ! cat > "${wrapper_path}" <<'EOF'
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
  then
    die "unable to write ${wrapper_path}"
  fi
}

write_consumer_shell_snippet() {
  local shell_path="$1"

  if ! cat > "${shell_path}" <<'EOF'
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
  then
    die "unable to write ${shell_path}"
  fi
}

ensure_run_scaffold() {
  local consumer_root="$1"
  local tools_dir="${consumer_root}/tools"
  local issue_forge_dir="${consumer_root}/.issue_forge"
  local wrapper_path="${tools_dir}/run_issue.sh"
  local shell_path="${issue_forge_dir}/shell.sh"

  if [[ -e "${wrapper_path}" ]]; then
    log 'tools/run_issue.sh already exists'
  else
    if ! mkdir -p "${tools_dir}"; then
      die "unable to create ${tools_dir}"
    fi

    write_consumer_run_wrapper "${wrapper_path}"

    if ! chmod +x "${wrapper_path}"; then
      die "unable to make ${wrapper_path} executable"
    fi

    log 'created tools/run_issue.sh'
  fi

  if [[ -e "${shell_path}" ]]; then
    log '.issue_forge/shell.sh already exists'
  else
    if ! mkdir -p "${issue_forge_dir}"; then
      die "unable to create ${issue_forge_dir}"
    fi

    write_consumer_shell_snippet "${shell_path}"
    log 'created .issue_forge/shell.sh'
  fi

  note 'one-shot: source .issue_forge/shell.sh, then run 5'
}

warn_for_missing_consumer_files() {
  local consumer_root="$1"

  if [[ ! -e "${consumer_root}/.issue_forge/checks/run_changed.sh" ]]; then
    warn 'missing .issue_forge/checks/run_changed.sh'
    note 'issue_forge defaults checks to ./.issue_forge/checks/run_changed.sh'
  fi

  if [[ ! -e "${consumer_root}/README.md" ]]; then
    warn 'missing README.md'
  fi
}

main() {
  local consumer_root
  local -a root_args=()

  parse_args "$@"
  if [[ -n "${CONSUMER_ROOT_ARG}" ]]; then
    root_args=("${CONSUMER_ROOT_ARG}")
  fi

  consumer_root="$(resolve_consumer_root "${root_args[@]}")"
  ensure_gitignore_configured "${consumer_root}"
  ensure_project_config "${consumer_root}"
  if [[ "${SCAFFOLD_CHECKS}" -eq 1 ]]; then
    ensure_checks_scaffold "${consumer_root}"
  fi
  if [[ "${SCAFFOLD_RUN}" -eq 1 ]]; then
    ensure_run_scaffold "${consumer_root}"
  fi
  warn_for_missing_consumer_files "${consumer_root}"
}

main "$@"
