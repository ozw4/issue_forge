attempt_store_publication_test_hook() {
  return 0
}

attempt_store_atomic_write_readonly() {
  local target_path="$1"
  local target_dir
  local temporary_path
  local status=1
  shift

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  temporary_path="$(mktemp "${target_dir}/.attempt-store.tmp.XXXXXX")" || return 1

  if printf '%s\n' "$@" > "$temporary_path" \
    && chmod 0444 "$temporary_path" \
    && mv -T -f -- "$temporary_path" "$target_path"; then
    status=0
  fi

  rm -f -- "$temporary_path" 2>/dev/null || true
  return "$status"
}

attempt_store_freeze_before_result() {
  local attempt_dir="$1"
  local stderr_policy="$2"
  local parsed_artifact="$3"
  local output_log="${attempt_dir}/output.log"
  local stderr_log="${attempt_dir}/stderr.log"

  [[ -f "$output_log" && ! -L "$output_log" ]] || {
    attempt_store_error "Attempt output is unavailable: ${output_log}"
    return 1
  }
  chmod 0444 "$output_log" || return 1

  if [[ "$stderr_policy" == stdout ]]; then
    [[ -f "$stderr_log" && ! -L "$stderr_log" ]] || {
      attempt_store_error "Attempt stderr is unavailable: ${stderr_log}"
      return 1
    }
    chmod 0444 "$stderr_log" || return 1
  fi

  if [[ "$parsed_artifact" != none ]]; then
    [[ "$(dirname "$parsed_artifact")" == "$attempt_dir" \
       && -f "$parsed_artifact" && ! -L "$parsed_artifact" ]] || {
      attempt_store_error "Parsed review artifact is unavailable: ${parsed_artifact}"
      return 1
    }
    chmod 0444 "$parsed_artifact" || return 1
  fi
}

attempt_store_verify_terminal_artifacts() {
  local attempt_dir="$1"
  local output_sha="$2"
  local stderr_sha="$3"
  local parsed_path="$4"
  local parsed_sha="$5"
  local output_log="${attempt_dir}/output.log"
  local stderr_log="${attempt_dir}/stderr.log"
  local parsed_artifact

  [[ -f "$output_log" && ! -L "$output_log" \
     && "$(attempt_store_sha256_file "$output_log")" == "$output_sha" ]] || {
    attempt_store_error "Attempt output does not match its terminal result: ${output_log}"
    return 1
  }
  chmod 0444 "$output_log" || return 1

  if [[ "$stderr_sha" != none ]]; then
    [[ -f "$stderr_log" && ! -L "$stderr_log" \
       && "$(attempt_store_sha256_file "$stderr_log")" == "$stderr_sha" ]] || {
      attempt_store_error "Attempt stderr does not match its terminal result: ${stderr_log}"
      return 1
    }
    chmod 0444 "$stderr_log" || return 1
  fi

  if [[ "$parsed_path" != none ]]; then
    attempt_store_require_phase "$parsed_path" || return 1
    parsed_artifact="${attempt_dir}/${parsed_path}"
    [[ -f "$parsed_artifact" && ! -L "$parsed_artifact" \
       && "$(attempt_store_sha256_file "$parsed_artifact")" == "$parsed_sha" ]] || {
      attempt_store_error "Parsed review artifact does not match its terminal result: ${parsed_artifact}"
      return 1
    }
    chmod 0444 "$parsed_artifact" || return 1
  elif [[ "$parsed_sha" != none ]]; then
    attempt_store_error 'Parsed review hash exists without a parsed artifact path'
    return 1
  fi
}

attempt_store_complete_pending_publication() {
  local attempts_root="$1"
  local pending_file="$2"
  local attempt_id phase round compatibility_output parsed_compatibility
  local attempt_dir input_file result_file output_log parsed_artifact latest_file
  local status_name exit_status parser_status output_sha stderr_sha parsed_sha parsed_path

  [[ -f "$pending_file" && ! -L "$pending_file" ]] || {
    attempt_store_error "Pending publication is unavailable: ${pending_file}"
    return 1
  }
  [[ "$(attempt_store_read_field "$pending_file" schema_version)" == "$CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION" ]] || {
    attempt_store_error "Unsupported pending publication schema: ${pending_file}"
    return 1
  }
  attempt_id="$(attempt_store_read_field "$pending_file" attempt_id)" || return 1
  phase="$(attempt_store_read_field "$pending_file" phase)" || return 1
  round="$(attempt_store_read_field "$pending_file" round)" || return 1
  compatibility_output="$(attempt_store_read_field "$pending_file" compatibility_output)" || return 1
  parsed_compatibility="$(attempt_store_read_field "$pending_file" parsed_compatibility)" || return 1

  attempt_store_require_phase "$attempt_id" || return 1
  attempt_store_require_phase "$phase" || return 1
  attempt_store_require_round "$round" || return 1
  attempt_store_require_scalar 'compatibility output path' "$compatibility_output" || return 1
  attempt_store_require_scalar 'parsed compatibility path' "$parsed_compatibility" || return 1
  [[ "${pending_file##*/}" == "${phase}.state" ]] || {
    attempt_store_error "Pending publication filename does not match phase ${phase}: ${pending_file}"
    return 1
  }

  attempt_dir="${attempts_root}/${attempt_id}"
  input_file="${attempt_dir}/input.state"
  result_file="${attempt_dir}/result.state"
  output_log="${attempt_dir}/output.log"
  latest_file="${attempts_root}/latest/${phase}.state"

  [[ -d "$attempt_dir" && ! -L "$attempt_dir" \
     && -f "$input_file" && ! -L "$input_file" ]] || {
    attempt_store_error "Pending publication attempt is unavailable: ${attempt_dir}"
    return 1
  }
  [[ "$(attempt_store_read_field "$input_file" attempt_id)" == "$attempt_id" \
     && "$(attempt_store_read_field "$input_file" phase)" == "$phase" \
     && "$(attempt_store_read_field "$input_file" round)" == "$round" \
     && "$(attempt_store_read_field "$input_file" compatibility_output)" == "$compatibility_output" ]] || {
    attempt_store_error "Pending publication does not match attempt input: ${attempt_dir}"
    return 1
  }

  if [[ ! -e "$result_file" && ! -L "$result_file" ]]; then
    rm -f -- "$pending_file"
    return 0
  fi
  [[ -f "$result_file" && ! -L "$result_file" \
     && "$(attempt_store_read_field "$result_file" schema_version)" == "$CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION" \
     && "$(attempt_store_read_field "$result_file" attempt_id)" == "$attempt_id" ]] || {
    attempt_store_error "Attempt result does not match pending publication: ${result_file}"
    return 1
  }

  status_name="$(attempt_store_read_field "$result_file" status)" || return 1
  exit_status="$(attempt_store_read_field "$result_file" exit_status)" || return 1
  parser_status="$(attempt_store_read_field "$result_file" parser_status)" || return 1
  output_sha="$(attempt_store_read_field "$result_file" output_sha256)" || return 1
  stderr_sha="$(attempt_store_read_field "$result_file" stderr_sha256)" || return 1
  parsed_sha="$(attempt_store_read_field "$result_file" parsed_sha256)" || return 1
  parsed_path="$(attempt_store_read_field "$result_file" parsed_path)" || return 1

  case "$status_name" in
    succeeded) [[ "$exit_status" -eq 0 ]] || return 1 ;;
    failed) [[ "$exit_status" -ne 0 ]] || return 1 ;;
    *) attempt_store_error "Invalid publishable attempt status: ${status_name}"; return 1 ;;
  esac
  case "$parser_status" in
    succeeded)
      [[ "$status_name" == succeeded && "$parsed_path" != none \
         && "$compatibility_output" == *.raw.txt \
         && "$parsed_compatibility" == "${compatibility_output%.raw.txt}.txt" ]] || {
        attempt_store_error 'Successful review publication has inconsistent compatibility paths'
        return 1
      }
      ;;
    not_applicable)
      [[ "$parsed_path" == none && "$parsed_sha" == none && "$parsed_compatibility" == none ]] || {
        attempt_store_error 'Non-review publication unexpectedly contains parsed review artifacts'
        return 1
      }
      ;;
    *) attempt_store_error "Invalid publishable parser status: ${parser_status}"; return 1 ;;
  esac

  attempt_store_verify_terminal_artifacts \
    "$attempt_dir" "$output_sha" "$stderr_sha" "$parsed_path" "$parsed_sha" || return 1
  chmod 0444 "$result_file" || return 1
  parsed_artifact="${attempt_dir}/${parsed_path}"

  if [[ "$parsed_compatibility" != none ]]; then
    attempt_store_atomic_copy "$parsed_artifact" "$parsed_compatibility" || return 1
  fi
  if [[ "$compatibility_output" != none ]]; then
    attempt_store_atomic_copy "$output_log" "$compatibility_output" || return 1
  fi

  issue_forge_attempt_store_atomic_write_original "$latest_file" \
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
  rm -f -- "$pending_file"
}

attempt_store_reconcile_publications() {
  local attempts_root="$1"
  local pending_dir="${attempts_root}/pending"
  local pending_file

  [[ ! -e "$pending_dir" ]] && return 0
  [[ -d "$pending_dir" && ! -L "$pending_dir" ]] || {
    attempt_store_error "Pending publication root is invalid: ${pending_dir}"
    return 1
  }
  while IFS= read -r pending_file; do
    [[ -n "$pending_file" ]] || continue
    attempt_store_complete_pending_publication "$attempts_root" "$pending_file" || return 1
  done < <(find "$pending_dir" -maxdepth 1 -type f -name '*.state' -print | LC_ALL=C sort)
  rmdir -- "$pending_dir" 2>/dev/null || true
}
