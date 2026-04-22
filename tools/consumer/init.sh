#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: tools/consumer/init.sh [consumer-root]\n' >&2
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

  if [[ "$#" -gt 1 ]]; then
    usage
    exit 1
  fi

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

  consumer_root="$(resolve_consumer_root "$@")"
  ensure_gitignore_configured "${consumer_root}"
  ensure_project_config "${consumer_root}"
  warn_for_missing_consumer_files "${consumer_root}"
}

main "$@"
