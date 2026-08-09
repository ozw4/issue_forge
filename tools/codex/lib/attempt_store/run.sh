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
  local publish_status=0
  local result_status=''
  local publish_attempt=1
  local parser_status='not_applicable'
  local parsed_temp=''
  local parsed_artifact='none'
  local parsed_compatibility='none'

  if [[ "${1:-}" != -- ]]; then
    attempt_store_error 'Attempt command separator is missing'
    return 1
  fi
  shift
  [[ "$#" -gt 0 ]] || { attempt_store_error 'Attempt command is empty'; return 1; }

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

  if [[ "$phase" == review || "$phase" == batch-review ]]; then
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
        if ! attempt_store_atomic_copy "$parsed_temp" "$parsed_artifact" || ! chmod 0444 "$parsed_artifact"; then
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
}
