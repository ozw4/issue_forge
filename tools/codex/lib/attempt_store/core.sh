readonly CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION='1'

attempt_store_error() {
  printf '[attempt-store] %s\n' "$1" >&2
  return 1
}

attempt_store_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

attempt_store_require_scalar() {
  local label="$1"
  local value="$2"

  if [[ -z "$value" || "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    attempt_store_error "Invalid ${label}"
    return 1
  fi
}

attempt_store_require_phase() {
  local value="$1"

  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    attempt_store_error "Invalid attempt phase: ${value}"
    return 1
  fi
}

attempt_store_require_round() {
  local value="$1"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    attempt_store_error "Invalid attempt round: ${value}"
    return 1
  fi
}

attempt_store_require_identity() {
  local run_id="$1"
  local scope="$2"
  local scope_id="$3"

  attempt_store_require_scalar 'attempt run ID' "$run_id" || return 1
  attempt_store_require_scalar 'attempt scope' "$scope" || return 1
  attempt_store_require_scalar 'attempt scope ID' "$scope_id" || return 1

  case "$scope" in
    standalone)
      [[ "$run_id" == none && "$scope_id" == none ]] || {
        attempt_store_error 'Standalone attempt identity must use run_id=none and scope_id=none'
        return 1
      }
      ;;
    issue)
      [[ "$scope_id" != none ]] || {
        attempt_store_error 'Issue attempt identity requires a scope ID'
        return 1
      }
      ;;
    batch)
      [[ "$run_id" != none && "$scope_id" != none ]] || {
        attempt_store_error 'Batch attempt identity requires run and scope IDs'
        return 1
      }
      ;;
    *)
      attempt_store_error "Invalid attempt scope: ${scope}"
      return 1
      ;;
  esac
}

attempt_store_sha256_file() {
  local path="$1"

  sha256sum -- "$path" | awk '{ print $1 }'
}

attempt_store_sha256_argv() {
  printf '%s\0' "$@" | sha256sum | awk '{ print $1 }'
}

attempt_store_atomic_copy() {
  local source_path="$1"
  local target_path="$2"
  local target_dir
  local temporary_path
  local status=1

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  temporary_path="$(mktemp "${target_dir}/.attempt-store.tmp.XXXXXX")" || return 1

  if cp -- "$source_path" "$temporary_path" \
    && chmod 0644 "$temporary_path" \
    && mv -T -f -- "$temporary_path" "$target_path"; then
    status=0
  fi

  rm -f -- "$temporary_path" 2>/dev/null || true
  return "$status"
}

attempt_store_atomic_write() {
  local target_path="$1"
  local target_dir
  local temporary_path
  local status=1
  shift

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  temporary_path="$(mktemp "${target_dir}/.attempt-store.tmp.XXXXXX")" || return 1

  if printf '%s\n' "$@" > "$temporary_path" && mv -T -f -- "$temporary_path" "$target_path"; then
    status=0
  fi

  rm -f -- "$temporary_path" 2>/dev/null || true
  return "$status"
}

attempt_store_read_field() {
  local state_file="$1"
  local requested="$2"

  awk -F '\t' -v requested="$requested" '$1 == requested { print $2; found = 1; exit } END { if (!found) exit 1 }' "$state_file"
}

attempt_store_create() {
  local -n output_ref="$1"
  local attempts_root="$2"
  local phase="$3"
  local round="$4"
  local mode="$5"
  local reasoning="$6"
  local prompt_file="$7"
  local compatibility_output="$8"
  local stderr_policy="$9"
  shift 9

  local created_dir
  local attempt_id
  local input_file
  local prompt_sha='none'
  local prompt_copy='none'
  local command_sha
  local formatted_round
  local identity_run_id="${CODEX_FLOW_ATTEMPT_RUN_ID:-none}"
  local identity_scope="${CODEX_FLOW_ATTEMPT_SCOPE:-standalone}"
  local identity_scope_id="${CODEX_FLOW_ATTEMPT_SCOPE_ID:-none}"

  attempt_store_require_phase "$phase" || return 1
  attempt_store_require_round "$round" || return 1
  attempt_store_require_scalar 'attempt mode' "$mode" || return 1
  attempt_store_require_scalar 'attempt reasoning' "$reasoning" || return 1
  attempt_store_require_scalar 'prompt path' "$prompt_file" || return 1
  attempt_store_require_scalar 'compatibility output path' "$compatibility_output" || return 1
  attempt_store_require_identity "$identity_run_id" "$identity_scope" "$identity_scope_id" || return 1
  case "$stderr_policy" in
    combined|stdout) ;;
    *) attempt_store_error "Invalid stderr policy: ${stderr_policy}"; return 1 ;;
  esac
  [[ "$#" -gt 0 ]] || { attempt_store_error 'Attempt command is empty'; return 1; }

  if [[ "$prompt_file" != none ]]; then
    [[ -f "$prompt_file" ]] || { attempt_store_error "Attempt prompt not found: ${prompt_file}"; return 1; }
    prompt_sha="$(attempt_store_sha256_file "$prompt_file")" || return 1
    prompt_copy='prompt.md'
  fi
  command_sha="$(attempt_store_sha256_argv "$@")" || return 1

  if [[ -e "$attempts_root" && ( ! -d "$attempts_root" || -L "$attempts_root" ) ]]; then
    attempt_store_error "Attempt root is not a regular directory: ${attempts_root}"
    return 1
  fi
  mkdir -p "$attempts_root" || return 1
  formatted_round="$(printf '%04d' "$round")"
  created_dir="$(mktemp -d "${attempts_root}/${phase}.round-${formatted_round}.attempt-XXXXXX")" || return 1
  attempt_id="${created_dir##*/}"
  input_file="${created_dir}/input.state"

  if ! attempt_store_atomic_write "$input_file" \
    $'schema_version\t'"${CODEX_FLOW_ATTEMPT_STORE_SCHEMA_VERSION}" \
    $'attempt_id\t'"${attempt_id}" \
    $'run_id\t'"${identity_run_id}" \
    $'scope\t'"${identity_scope}" \
    $'scope_id\t'"${identity_scope_id}" \
    $'phase\t'"${phase}" \
    $'round\t'"${round}" \
    $'mode\t'"${mode}" \
    $'reasoning\t'"${reasoning}" \
    $'stderr_policy\t'"${stderr_policy}" \
    $'prompt_path\t'"${prompt_file}" \
    $'prompt_sha256\t'"${prompt_sha}" \
    $'prompt_copy\t'"${prompt_copy}" \
    $'compatibility_output\t'"${compatibility_output}" \
    $'command_argv_sha256\t'"${command_sha}" \
    $'started_at\t'"$(attempt_store_now)"; then
    rm -rf -- "$created_dir"
    return 1
  fi
  if [[ "$prompt_file" != none ]]; then
    attempt_store_atomic_copy "$prompt_file" "${created_dir}/${prompt_copy}" || return 1
    chmod 0444 "${created_dir}/${prompt_copy}" || return 1
  fi
  chmod 0444 "$input_file" || return 1
  output_ref="$created_dir"
}

attempt_store_signal_from_status() {
  local status="$1"

  if [[ "$status" -ge 129 && "$status" -le 192 ]]; then
    printf '%s\n' "$((status - 128))"
  else
    printf 'none\n'
  fi
}
