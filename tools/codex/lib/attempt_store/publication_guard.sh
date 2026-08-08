issue_forge_attempt_store_capture_function() {
  local source_name="$1"
  local target_name="$2"
  local definition

  definition="$(declare -f "$source_name")" || return 1
  definition="${definition/#${source_name} /${target_name} }"
  eval "$definition"
}

issue_forge_attempt_store_capture_function \
  attempt_store_atomic_write issue_forge_attempt_store_atomic_write_original || return 1
issue_forge_attempt_store_capture_function \
  attempt_store_finalize issue_forge_attempt_store_finalize_original || return 1
issue_forge_attempt_store_capture_function \
  run_logged_attempt issue_forge_run_logged_attempt_original || return 1

attempt_store_atomic_write() {
  if [[ "${1##*/}" == result.state ]]; then
    attempt_store_atomic_write_readonly "$@"
  else
    issue_forge_attempt_store_atomic_write_original "$@"
  fi
}

attempt_store_finalize() {
  local attempt_dir="$1"
  local attempts_root="$2"
  local phase="$3"
  local round="$4"
  local compatibility_output="$5"
  local stderr_policy="$6"
  local publish_attempt="${9:-1}"
  local parsed_artifact="${11:-none}"
  local parsed_compatibility="${12:-none}"
  local pending_file="${attempts_root}/pending/${phase}.state"
  local status

  attempt_store_freeze_before_result "$attempt_dir" "$stderr_policy" "$parsed_artifact" || return 1

  if [[ "$publish_attempt" -eq 1 ]]; then
    [[ ! -e "$pending_file" && ! -L "$pending_file" ]] || {
      attempt_store_error "Pending publication already exists: ${pending_file}"
      return 1
    }
    attempt_store_atomic_write_readonly "$pending_file" \
      $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
      $'attempt_id\t'"${attempt_dir##*/}" \
      $'phase\t'"${phase}" \
      $'round\t'"${round}" \
      $'compatibility_output\t'"${compatibility_output}" \
      $'parsed_compatibility\t'"${parsed_compatibility}" \
      $'updated_at\t'"$(attempt_store_now)" || return 1
    attempt_store_publication_test_hook after_pending "$attempt_dir" "$pending_file" || return 1
  fi

  if issue_forge_attempt_store_finalize_original "$@"; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 0 ]] || return "$status"

  if [[ "$publish_attempt" -eq 1 ]]; then
    attempt_store_publication_test_hook after_finalize "$attempt_dir" "$pending_file" || return 1
    rm -f -- "$pending_file"
  fi
}

run_logged_attempt() {
  local attempts_root="$3"

  attempt_store_reconcile_publications "$attempts_root" || return 1
  issue_forge_run_logged_attempt_original "$@"
}
