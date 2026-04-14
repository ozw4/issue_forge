#!/usr/bin/env bash

codex_profile_config_error() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_codex_profile_value() {
  local value="$1"
  local description="$2"

  if [[ -z "$value" ]]; then
    codex_profile_config_error "Missing Codex profile setting: ${description}"
  fi
}

resolve_codex_profile_for_mode() {
  local mode="$1"
  local profile

  case "$mode" in
    write)
      profile="$CODEX_FLOW_WRITE_PROFILE"
      ;;
    read)
      profile="$CODEX_FLOW_READ_PROFILE"
      ;;
    *)
      codex_profile_config_error "Invalid mode: ${mode}"
      ;;
  esac

  require_codex_profile_value "$profile" "mode ${mode} profile"
  printf '%s\n' "$profile"
}

resolve_codex_profile_sandbox() {
  local profile="$1"
  local sandbox_mode

  case "$profile" in
    "$CODEX_FLOW_PROFILE_WRITE")
      sandbox_mode="$CODEX_FLOW_PROFILE_WRITE_SANDBOX"
      ;;
    "$CODEX_FLOW_PROFILE_READ")
      sandbox_mode="$CODEX_FLOW_PROFILE_READ_SANDBOX"
      ;;
    *)
      codex_profile_config_error "Invalid Codex execution profile: ${profile}"
      ;;
  esac

  require_codex_profile_value "$sandbox_mode" "profile ${profile} sandbox"
  printf '%s\n' "$sandbox_mode"
}

resolve_codex_profile_reasoning() {
  local profile="$1"
  local reasoning_effort

  case "$profile" in
    "$CODEX_FLOW_PROFILE_WRITE")
      reasoning_effort="$CODEX_FLOW_PROFILE_WRITE_REASONING"
      ;;
    "$CODEX_FLOW_PROFILE_READ")
      reasoning_effort="$CODEX_FLOW_PROFILE_READ_REASONING"
      ;;
    *)
      codex_profile_config_error "Invalid Codex execution profile: ${profile}"
      ;;
  esac

  require_codex_profile_value "$reasoning_effort" "profile ${profile} reasoning"
  printf '%s\n' "$reasoning_effort"
}
