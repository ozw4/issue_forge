attempt_store_finalize() {
  local attempt_dir="$1"
  local attempts_root="$2"
  local phase="$3"
  local round="$4"
  local compatibility_output="$5"
  local stderr_policy="$6"
  local exit_status="$7"
  local requested_status="${8:-}"
  local publish_attempt="${9:-1}"
  local parser_status="${10:-not_applicable}"
  local parsed_artifact="${11:-none}"
  local parsed_compatibility="${12:-none}"

  local attempt_id="${attempt_dir##*/}"
  local output_log="${attempt_dir}/output.log"
  local stderr_log="${attempt_dir}/stderr.log"
  local result_file="${attempt_dir}/result.state"
  local status_name='failed'
  local output_sha
  local stderr_sha='none'
  local parsed_sha='none'
  local parsed_path='none'
  local signal_value
  local latest_file="${attempts_root}/latest/${phase}.state"

  case "$requested_status" in
    '') [[ "$exit_status" -eq 0 ]] && status_name='succeeded' ;;
    succeeded|failed|invalid) status_name="$requested_status" ;;
    *) attempt_store_error "Invalid attempt result status: ${requested_status}"; return 1 ;;
  esac
  case "$publish_attempt" in
    0|1) ;;
    *) attempt_store_error "Invalid attempt publication flag: ${publish_attempt}"; return 1 ;;
  esac
  case "$parser_status" in
    not_applicable|succeeded|failed) ;;
    *) attempt_store_error "Invalid attempt parser status: ${parser_status}"; return 1 ;;
  esac

  [[ -f "$output_log" ]] || : > "$output_log"
  output_sha="$(attempt_store_sha256_file "$output_log")" || return 1
  if [[ "$stderr_policy" == stdout ]]; then
    [[ -f "$stderr_log" ]] || : > "$stderr_log"
    stderr_sha="$(attempt_store_sha256_file "$stderr_log")" || return 1
  fi
  if [[ "$parsed_artifact" != none ]]; then
    [[ -f "$parsed_artifact" ]] || {
      attempt_store_error "Parsed review artifact is unavailable: ${parsed_artifact}"
      return 1
    }
    parsed_sha="$(attempt_store_sha256_file "$parsed_artifact")" || return 1
    parsed_path="${parsed_artifact##*/}"
  fi
  if [[ "$parser_status" == succeeded && ( "$parsed_artifact" == none || "$parsed_compatibility" == none ) ]]; then
    attempt_store_error 'Successful review parsing requires parsed artifact and compatibility paths'
    return 1
  fi
  signal_value="$(attempt_store_signal_from_status "$exit_status")"

  if ! attempt_store_atomic_write "$result_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'status\t'"${status_name}" \
    $'exit_status\t'"${exit_status}" \
    $'signal\t'"${signal_value}" \
    $'parser_status\t'"${parser_status}" \
    $'output_sha256\t'"${output_sha}" \
    $'stderr_sha256\t'"${stderr_sha}" \
    $'parsed_sha256\t'"${parsed_sha}" \
    $'parsed_path\t'"${parsed_path}" \
    $'finished_at\t'"$(attempt_store_now)"; then
    return 1
  fi

  chmod 0444 "$output_log" "$result_file" || return 1
  if [[ "$stderr_policy" == stdout ]]; then
    chmod 0444 "$stderr_log" || return 1
  fi
  if [[ "$parsed_artifact" != none ]]; then
    chmod 0444 "$parsed_artifact" || return 1
  fi

  if [[ "$publish_attempt" -eq 0 ]]; then
    return 0
  fi
  if [[ "$parsed_compatibility" != none ]]; then
    attempt_store_atomic_copy "$parsed_artifact" "$parsed_compatibility" || return 1
  fi
  if [[ "$compatibility_output" != none ]]; then
    attempt_store_atomic_copy "$output_log" "$compatibility_output" || return 1
  fi

  attempt_store_atomic_write "$latest_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'phase\t'"${phase}" \
    $'round\t'"${round}" \
    $'status\t'"${status_name}" \
    $'exit_status\t'"${exit_status}" \
    $'parser_status\t'"${parser_status}" \
    $'attempt_path\t'"${attempt_id}" \
    $'output_path\t'"${attempt_id}/output.log" \
    $'parsed_path\t'"${parsed_path}" \
    $'result_path\t'"${attempt_id}/result.state" \
    $'updated_at\t'"$(attempt_store_now)" || return 1
}

attempt_store_publish_derived() {
  local attempt_dir="$1"
  local artifact_name="$2"
  local source_path="$3"
  local target_path
  local parser_status='not_applicable'

  if [[ ! "$artifact_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    attempt_store_error "Invalid derived artifact name: ${artifact_name}"
    return 1
  fi
  [[ -d "$attempt_dir" && ! -L "$attempt_dir" ]] || {
    attempt_store_error "Attempt directory is unavailable: ${attempt_dir}"
    return 1
  }
  [[ -f "${attempt_dir}/result.state" ]] || {
    attempt_store_error "Attempt is not terminal: ${attempt_dir}"
    return 1
  }
  [[ -f "$source_path" ]] || {
    attempt_store_error "Derived artifact source is unavailable: ${source_path}"
    return 1
  }
  target_path="${attempt_dir}/${artifact_name}"
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    parser_status="$(attempt_store_read_field "${attempt_dir}/result.state" parser_status 2>/dev/null || printf not_applicable)"
    if [[ "$parser_status" == succeeded && -f "$target_path" && ! -L "$target_path" ]] \
      && cmp -s -- "$source_path" "$target_path"; then
      return 0
    fi
    attempt_store_error "Derived artifact already exists: ${target_path}"
    return 1
  fi
  attempt_store_atomic_copy "$source_path" "$target_path" || return 1
  chmod 0444 "$target_path"
}

