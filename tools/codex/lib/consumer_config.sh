issue_forge_load_consumer_config() {
  local repo_root="${1:?repo root is required}"
  local config_file="${repo_root}/.issue_forge/project.sh"

  [[ -f "${config_file}" ]] || {
    echo "missing consumer config: ${config_file}" >&2
    return 1
  }

  # shellcheck disable=SC1090
  source "${config_file}"

  : "${CODEX_FLOW_BASE_REF:?missing CODEX_FLOW_BASE_REF}"
  : "${CODEX_FLOW_BASE_BRANCH:?missing CODEX_FLOW_BASE_BRANCH}"
  : "${CODEX_FLOW_BRANCH_PREFIX:?missing CODEX_FLOW_BRANCH_PREFIX}"
  : "${CODEX_FLOW_CHECKS_COMMAND:?missing CODEX_FLOW_CHECKS_COMMAND}"
  : "${CODEX_FLOW_PROMPTS_DIR:?missing CODEX_FLOW_PROMPTS_DIR}"
  : "${CODEX_FLOW_PR_DRAFT_DEFAULT:?missing CODEX_FLOW_PR_DRAFT_DEFAULT}"
  : "${CODEX_FLOW_WRITE_PROFILE:?missing CODEX_FLOW_WRITE_PROFILE}"
  : "${CODEX_FLOW_READ_PROFILE:?missing CODEX_FLOW_READ_PROFILE}"
  : "${CODEX_FLOW_PROFILE_WRITE_SANDBOX:?missing CODEX_FLOW_PROFILE_WRITE_SANDBOX}"
  : "${CODEX_FLOW_PROFILE_WRITE_REASONING:?missing CODEX_FLOW_PROFILE_WRITE_REASONING}"
  : "${CODEX_FLOW_PROFILE_READ_SANDBOX:?missing CODEX_FLOW_PROFILE_READ_SANDBOX}"
  : "${CODEX_FLOW_PROFILE_READ_REASONING:?missing CODEX_FLOW_PROFILE_READ_REASONING}"
}
