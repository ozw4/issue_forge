# shellcheck shell=bash

run_logged_attempt() {
  local -n attempt_dir_ref="$1"
  local -n attempt_log_ref="$2"
  local attempts_root="$3"
  local phase="$4"
  local round="$5"
  local mode="$6"
  local reasoning="$7"
  local prompt_file="$8"
  local compatibility_output="$9"
  local stderr_policy="${10}"
  shift 10

  local attempt_path
  local output_log
  local stderr_log
  local command_status
  local operation_status
  local publish_status
  local result_status
  local publish_attempt
  local parser_status
  local parsed_temp
  local parsed_artifact
  local parsed_compatibility
  local review_fingerprint_before=''
  local review_fingerprint_after=''
  local review_retry_count=0
  local review_retry_limit="${CODEX_FLOW_REVIEW_RETRY_LIMIT:-$CODEX_FLOW_REVIEW_RETRY_LIMIT_DEFAULT}"
  local review_phase=0
  local review_changed=0
  local review_fingerprint_failed=0

  if [[ "${1:-}" != -- ]]; then
    attempt_store_error 'Attempt command separator is missing'
    return 1
  fi
  shift
  [[ "$#" -gt 0 ]] || { attempt_store_error 'Attempt command is empty'; return 1; }
  if [[ ( "$phase" == review || "$phase" == batch-review ) \
     && "${CODEX_FLOW_ATTEMPT_SCOPE:-standalone}" != standalone ]]; then
    review_phase=1
    [[ "$review_retry_limit" =~ ^[0-9]+$ ]] || {
      attempt_store_error "Invalid review retry limit: ${review_retry_limit}"
      return 1
    }
    declare -F review_repository_fingerprint >/dev/null 2>&1 || {
      attempt_store_error 'Review repository fingerprint helper is unavailable'
      return 1
    }
    declare -F review_refresh_material_after_change >/dev/null 2>&1 || {
      attempt_store_error 'Review material refresh helper is unavailable'
      return 1
    }
  fi

  while true; do
    publish_status=0
    result_status=''
    publish_attempt=1
    parser_status='not_applicable'
    parsed_temp=''
    parsed_artifact='none'
    parsed_compatibility='none'
    review_changed=0
    review_fingerprint_failed=0

    if [[ "$review_phase" -eq 1 ]]; then
      review_fingerprint_before="$(review_repository_fingerprint)" || {
        attempt_store_error "Cannot fingerprint repository before ${phase} round ${round}"
        return 1
      }
    fi

    attempt_store_create attempt_path "$attempts_root" "$phase" "$round" "$mode" "$reasoning" \
      "$prompt_file" "$compatibility_output" "$stderr_policy" "$@" || return 1
    output_log="${attempt_path}/output.log"
    stderr_log="${attempt_path}/stderr.log"
    attempt_dir_ref="$attempt_path"
    attempt_log_ref="$output_log"

    case "$stderr_policy" in
      combined)
        if "$@" > "$output_log" 2>&1; then command_status=0; else command_status=$?; fi
        ;;
      stdout)
        if "$@" > "$output_log" 2> "$stderr_log"; then command_status=0; else command_status=$?; fi
        cat -- "$stderr_log" >&2 || true
        ;;
    esac
    operation_status="$command_status"

    if [[ "$review_phase" -eq 1 ]]; then
      if ! review_fingerprint_after="$(review_repository_fingerprint)"; then
        attempt_store_error "Cannot fingerprint repository after ${phase} round ${round}"
        result_status=invalid
        publish_attempt=0
        operation_status=1
        review_fingerprint_failed=1
      elif [[ "$review_fingerprint_before" != "$review_fingerprint_after" ]]; then
        result_status=invalid
        publish_attempt=0
        operation_status=1
        review_changed=1
      fi
    fi

    if [[ "$review_phase" -eq 1 && "$publish_attempt" -eq 0 ]]; then
      if ! attempt_store_finalize "$attempt_path" "$attempts_root" "$phase" "$round" \
        "$compatibility_output" "$stderr_policy" "$command_status" "$result_status" 0 \
        not_applicable none none; then
        return 1
      fi

      if [[ "$review_fingerprint_failed" -eq 1 ]]; then
        return 1
      fi
      if [[ "$review_changed" -ne 1 ]]; then
        return "$operation_status"
      fi
      if [[ "$review_retry_count" -ge "$review_retry_limit" ]]; then
        attempt_store_error \
          "Repository changed during ${phase} round ${round} after ${review_retry_limit} retries"
        return 1
      fi

      review_retry_count=$((review_retry_count + 1))
      printf '[attempt-store] repository changed during %s round %s; rerunning review (%s/%s)\n' \
        "$phase" "$round" "$review_retry_count" "$review_retry_limit" >&2
      review_refresh_material_after_change "$phase" "$round" || return 1
      review_update_outer_status_baseline || return 1
      continue
    fi

    if [[ "$review_phase" -eq 1 ]]; then
      if [[ "$command_status" -ne 0 ]]; then
        result_status=failed
        publish_attempt=0
      elif declare -F extract_structured_review_output_file >/dev/null 2>&1; then
        parsed_temp="$(mktemp)" || return 1
        if [[ "$compatibility_output" != *.raw.txt ]]; then
          attempt_store_error "Review compatibility output must end with .raw.txt: ${compatibility_output}"
          parser_status=failed
          result_status=invalid
          publish_attempt=0
          operation_status=1
        elif extract_structured_review_output_file "$output_log" "$parsed_temp"; then
          parsed_artifact="${attempt_path}/parsed-review.txt"
          parsed_compatibility="${compatibility_output%.raw.txt}.txt"
          if ! attempt_store_atomic_copy "$parsed_temp" "$parsed_artifact" \
            || ! chmod 0444 "$parsed_artifact"; then
            rm -f -- "$parsed_temp"
            return 1
          fi
          parser_status=succeeded
          result_status=succeeded
        else
          attempt_store_error "Review output could not be parsed for ${phase} round ${round}"
          parser_status=failed
          result_status=invalid
          publish_attempt=0
          operation_status=1
        fi
      elif [[ -n "${CODEX_FLOW_CODEX_DIR:-}" ]]; then
        attempt_store_error "Review parser is unavailable for ${phase} round ${round}"
        parser_status=failed
        result_status=invalid
        publish_attempt=0
        operation_status=1
      fi
    fi

    if ! attempt_store_finalize "$attempt_path" "$attempts_root" "$phase" "$round" \
      "$compatibility_output" "$stderr_policy" "$command_status" "$result_status" "$publish_attempt" \
      "$parser_status" "$parsed_artifact" "$parsed_compatibility"; then
      publish_status=1
    fi
    rm -f -- "$parsed_temp" 2>/dev/null || true

    if [[ "$publish_status" -ne 0 ]]; then
      return "$publish_status"
    fi
    return "$operation_status"
  done
}
