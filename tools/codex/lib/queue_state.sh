#!/usr/bin/env bash

readonly CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION='2'

queue_state_error() { printf '[queue-state] %s\n' "$1" >&2; return 1; }
queue_state_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

queue_state_guard_enter() {
  local guard="${QUEUE_STATE_SERIALIZATION_GUARD:?QUEUE_STATE_SERIALIZATION_GUARD is required}"
  if [[ "${QUEUE_STATE_GUARD_DEPTH:-0}" -gt 0 ]]; then
    QUEUE_STATE_GUARD_DEPTH=$((QUEUE_STATE_GUARD_DEPTH + 1))
    return 0
  fi
  mkdir -p "$(dirname "$guard")" || return 1
  exec {QUEUE_STATE_GUARD_FD}>"$guard" || return 1
  if ! flock -x "$QUEUE_STATE_GUARD_FD"; then
    exec {QUEUE_STATE_GUARD_FD}>&-
    unset QUEUE_STATE_GUARD_FD
    return 1
  fi
  QUEUE_STATE_GUARD_DEPTH=1
}

queue_state_guard_leave() {
  [[ "${QUEUE_STATE_GUARD_DEPTH:-0}" -gt 0 ]] || return 1
  QUEUE_STATE_GUARD_DEPTH=$((QUEUE_STATE_GUARD_DEPTH - 1))
  [[ "$QUEUE_STATE_GUARD_DEPTH" -gt 0 ]] && return 0
  flock -u "$QUEUE_STATE_GUARD_FD" || return 1
  exec {QUEUE_STATE_GUARD_FD}>&-
  unset QUEUE_STATE_GUARD_FD
}

queue_state_begin_serialized_operation() {
  queue_state_guard_enter || return 1
  if [[ -n "${QUEUE_STATE_ASSERT_OWNED_FUNCTION:-}" && "${QUEUE_STATE_ASSERT_IN_PROGRESS:-0}" -ne 1 ]]; then
    QUEUE_STATE_ASSERT_IN_PROGRESS=1
    if ! "${QUEUE_STATE_ASSERT_OWNED_FUNCTION}"; then
      QUEUE_STATE_ASSERT_IN_PROGRESS=0
      queue_state_guard_leave || true
      return 1
    fi
    QUEUE_STATE_ASSERT_IN_PROGRESS=0
  fi
}

queue_state_finish_serialized_operation() {
  local status="$1"
  queue_state_guard_leave || return 1
  return "$status"
}

queue_state_test_pause() {
  local name="$1" directory="${QUEUE_STATE_TEST_PAUSE_DIR:-}" label="${QUEUE_STATE_TEST_RUNNER_LABEL:-$$}"
  [[ -n "$directory" && "${QUEUE_STATE_TEST_PAUSE_AT:-}" == "$name" ]] || return 0
  mkdir -p "$directory" || return 1
  : > "${directory}/paused.${name}.${label}" || return 1
  while [[ ! -f "${directory}/release.${name}.${label}" ]]; do sleep 0.01; done
}

queue_state_cleanup_temporary_files() {
  local directory="$1" path listing
  [[ -d "$directory" ]] || return 0
  listing="$(find "$directory" -maxdepth 1 -type f -name '.queue-state.tmp.*' -print | LC_ALL=C sort)" || return 1
  [[ -n "$listing" ]] || return 0
  while IFS= read -r path; do rm -f -- "$path" || return 1; done <<< "$listing"
}

queue_state_enum_contains() {
  local value="$1" candidate
  shift
  for candidate in "$@"; do [[ "$value" == "$candidate" ]] && return 0; done
  return 1
}

queue_state_require_token() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || queue_state_error "Malformed ${label}: ${value}"
}

queue_state_require_path() {
  local label="$1" value="$2"
  if [[ -z "$value" || "$value" == /* || "$value" == *'//'* || ! "$value" =~ ^[A-Za-z0-9._/-]+$ || "/$value/" == *'/../'* || "/$value/" == *'/./'* ]]; then
    queue_state_error "Malformed ${label} path: ${value}"
  fi
}

queue_state_require_timestamp() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || queue_state_error "Malformed ${label} timestamp: ${value}"
}

queue_state_require_issues() {
  local value="$1" issue reconstructed
  local -a values
  [[ -n "$value" ]] || { queue_state_error 'Malformed ordered Issue list: empty'; return 1; }
  IFS=',' read -r -a values <<< "$value"
  for issue in "${values[@]}"; do
    [[ "$issue" =~ ^[0-9]+$ ]] || { queue_state_error "Malformed Issue number in ordered list: ${issue}"; return 1; }
  done
  reconstructed="$(IFS=,; printf '%s' "${values[*]}")"
  [[ "$reconstructed" == "$value" ]] || queue_state_error "Malformed ordered Issue list: ${value}"
}

queue_state_canonical_repository_identity() {
  local remote="$1" host path
  case "$remote" in
    *@*:*) host="${remote#*@}"; host="${host%%:*}"; path="${remote#*:}" ;;
    ssh://*|http://*|https://*)
      remote="${remote#*://}"; remote="${remote#*@}"; host="${remote%%/*}"; host="${host%%:*}"; path="${remote#*/}" ;;
    /*) printf 'local-path:%s\n' "$remote"; return 0 ;;
    *) queue_state_error "Unsupported repository remote URL: ${remote}"; return 1 ;;
  esac
  path="${path#/}"; path="${path%.git}"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    queue_state_error 'Cannot derive credential-free repository identity'; return 1;
  }
  printf '%s/%s\n' "${host,,}" "$path"
}

queue_state_parse_file() {
  local file="$1" schema="$2" output_name="$3" line key value
  local -n output="$output_name"
  local -A allowed=()
  local -a required=()
  case "$schema" in
    manifest) required=(schema_version run_id created_at issues review_every draft_pr auto_merge light_issue_review batch_review_reasoning batch_fix_reasoning batch_check_fix_reasoning base_branch base_ref repository_identity) ;;
    run) required=(schema_version run_id state updated_at) ;;
    batch) required=(schema_version run_id batch_id first_issue last_issue branch base_commit artifact_path state updated_at) ;;
    issue) required=(schema_version run_id batch_id issue_number base_commit commit_sha artifact_path state updated_at) ;;
    lease) required=(schema_version run_id owner_token lease_generation owner_pid owner_host process_start acquired_at displaced_run_id displaced_owner_token displaced_generation) ;;
    pointer) required=(schema_version run_id owner_token lease_generation updated_at) ;;
    checkpoint) required=(schema_version run_id entity phase status updated_at) ;;
    publish) required=(schema_version run_id batch_id pr_number pr_url head_branch base_branch head_sha state updated_at) ;;
    *) queue_state_error "Unknown state schema: ${schema}"; return 1 ;;
  esac
  for key in "${required[@]}"; do allowed["$key"]=1; done
  output=()
  [[ -f "$file" ]] || { queue_state_error "Missing ${schema} state file: ${file}"; return 1; }
  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    queue_state_error "Malformed ${schema} state file (missing final newline): ${file}"; return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" != *$'\t'* || "$line" == *$'\t'*$'\t'* || "$line" == *$'\r'* ]]; then
      queue_state_error "Malformed ${schema} state line in ${file}: ${line}"; return 1
    fi
    key="${line%%$'\t'*}"; value="${line#*$'\t'}"
    [[ -n "${allowed[$key]:-}" ]] || { queue_state_error "Unknown ${schema} state key '${key}' in ${file}"; return 1; }
    [[ ! -v "output[$key]" ]] || { queue_state_error "Duplicate ${schema} state key '${key}' in ${file}"; return 1; }
    output["$key"]="$value"
  done < "$file"
  for key in "${required[@]}"; do
    [[ -v "output[$key]" ]] || { queue_state_error "Missing required ${schema} state key '${key}' in ${file}"; return 1; }
  done
}

queue_state_validate_file() {
  local file="$1" schema="$2"
  local -A fields=()
  queue_state_parse_file "$file" "$schema" fields || return 1
  [[ "${fields[schema_version]}" == "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" ]] \
    || { queue_state_error "Unsupported ${schema} schema version: ${fields[schema_version]}"; return 1; }
  queue_state_require_token 'run ID' "${fields[run_id]}" || return 1
  if [[ "$schema" == manifest ]]; then queue_state_require_timestamp manifest "${fields[created_at]}" || return 1
  elif [[ "$schema" == lease ]]; then queue_state_require_timestamp lease "${fields[acquired_at]}" || return 1
  else queue_state_require_timestamp "$schema" "${fields[updated_at]}" || return 1; fi
  case "$schema" in
    manifest)
      queue_state_require_issues "${fields[issues]}" || return 1
      [[ "${fields[review_every]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed review_every: ${fields[review_every]}"; return 1; }
      queue_state_enum_contains "${fields[draft_pr]}" 0 1 || { queue_state_error "Malformed draft policy: ${fields[draft_pr]}"; return 1; }
      queue_state_enum_contains "${fields[auto_merge]}" 0 1 || { queue_state_error "Malformed auto-merge policy: ${fields[auto_merge]}"; return 1; }
      queue_state_enum_contains "${fields[light_issue_review]}" 0 1 || { queue_state_error "Malformed light Issue review policy: ${fields[light_issue_review]}"; return 1; }
      [[ "${fields[draft_pr]}:${fields[auto_merge]}" != 1:1 ]] || { queue_state_error 'Draft and auto-merge policies are incompatible'; return 1; }
      queue_state_require_token 'batch review reasoning' "${fields[batch_review_reasoning]}" || return 1
      queue_state_require_token 'batch fix reasoning' "${fields[batch_fix_reasoning]}" || return 1
      queue_state_require_token 'batch check fix reasoning' "${fields[batch_check_fix_reasoning]}" || return 1
      queue_state_require_path 'base branch' "${fields[base_branch]}" || return 1
      queue_state_require_path 'base ref' "${fields[base_ref]}" || return 1
      [[ -n "${fields[repository_identity]}" && "${fields[repository_identity]}" != *$'\t'* ]] || { queue_state_error 'Malformed repository identity'; return 1; }
      ;;
    run)
      queue_state_enum_contains "${fields[state]}" planned running interrupted failed manual_review_required completed \
        || { queue_state_error "Malformed run state: ${fields[state]}"; return 1; }
      ;;
    batch)
      queue_state_require_token 'batch ID' "${fields[batch_id]}" || return 1
      [[ "${fields[first_issue]}" =~ ^[0-9]+$ && "${fields[last_issue]}" =~ ^[0-9]+$ ]] || { queue_state_error 'Malformed batch Issue range'; return 1; }
      queue_state_require_path 'batch branch' "${fields[branch]}" || return 1
      [[ "${fields[base_commit]}" == none || "${fields[base_commit]}" =~ ^[0-9a-fA-F]{40,64}$ ]] || { queue_state_error "Malformed batch commit SHA: ${fields[base_commit]}"; return 1; }
      queue_state_require_path 'batch artifact' "${fields[artifact_path]}" || return 1
      queue_state_enum_contains "${fields[state]}" planned branch_ready issues_running checks_running review_running accepted publishing completed failed \
        || { queue_state_error "Malformed batch state: ${fields[state]}"; return 1; }
      ;;
    issue)
      queue_state_require_token 'batch ID' "${fields[batch_id]}" || return 1
      [[ "${fields[issue_number]}" =~ ^[0-9]+$ ]] || { queue_state_error "Malformed Issue number: ${fields[issue_number]}"; return 1; }
      [[ "${fields[base_commit]}" == none || "${fields[base_commit]}" =~ ^[0-9a-fA-F]{40,64}$ ]] || { queue_state_error "Malformed Issue base SHA: ${fields[base_commit]}"; return 1; }
      [[ "${fields[commit_sha]}" == none || "${fields[commit_sha]}" =~ ^[0-9a-fA-F]{40,64}$ ]] || { queue_state_error "Malformed Issue commit SHA: ${fields[commit_sha]}"; return 1; }
      [[ "${fields[artifact_path]}" == none ]] || queue_state_require_path 'Issue artifact' "${fields[artifact_path]}" || return 1
      queue_state_enum_contains "${fields[state]}" planned leased running committed artifacts_archived acknowledged failed \
        || { queue_state_error "Malformed Issue state: ${fields[state]}"; return 1; }
      ;;
    lease)
      queue_state_require_token 'lease owner token' "${fields[owner_token]}" || return 1
      [[ "${fields[lease_generation]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed lease generation: ${fields[lease_generation]}"; return 1; }
      [[ "${fields[owner_pid]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed lease owner PID: ${fields[owner_pid]}"; return 1; }
      queue_state_require_token 'lease owner host' "${fields[owner_host]}" || return 1
      [[ "${fields[process_start]}" == unavailable || "${fields[process_start]}" =~ ^[0-9]+$ ]] || { queue_state_error "Malformed process-start identity: ${fields[process_start]}"; return 1; }
      [[ "${fields[displaced_run_id]}" == none ]] || queue_state_require_token 'displaced run ID' "${fields[displaced_run_id]}" || return 1
      [[ "${fields[displaced_owner_token]}" == none ]] || queue_state_require_token 'displaced owner token' "${fields[displaced_owner_token]}" || return 1
      [[ "${fields[displaced_generation]}" == none || "${fields[displaced_generation]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed displaced generation: ${fields[displaced_generation]}"; return 1; }
      ;;
    pointer)
      queue_state_require_token 'current owner token' "${fields[owner_token]}" || return 1
      [[ "${fields[lease_generation]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed current lease generation: ${fields[lease_generation]}"; return 1; }
      ;;
    checkpoint)
      queue_state_require_token 'checkpoint entity' "${fields[entity]}" || return 1
      queue_state_require_token 'checkpoint phase' "${fields[phase]}" || return 1
      queue_state_enum_contains "${fields[status]}" before after interrupted failed \
        || { queue_state_error "Malformed checkpoint status: ${fields[status]}"; return 1; }
      ;;
    publish)
      queue_state_require_token 'publish batch ID' "${fields[batch_id]}" || return 1
      [[ "${fields[pr_number]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed published PR number: ${fields[pr_number]}"; return 1; }
      [[ "${fields[pr_url]}" =~ ^https?://[^[:space:]]+$ ]] || { queue_state_error "Malformed published PR URL: ${fields[pr_url]}"; return 1; }
      queue_state_require_path 'published head branch' "${fields[head_branch]}" || return 1
      queue_state_require_path 'published base branch' "${fields[base_branch]}" || return 1
      [[ "${fields[head_sha]}" =~ ^[0-9a-fA-F]{40,64}$ ]] || { queue_state_error "Malformed published head SHA: ${fields[head_sha]}"; return 1; }
      queue_state_enum_contains "${fields[state]}" open merged || { queue_state_error "Malformed publish state: ${fields[state]}"; return 1; }
      ;;
  esac
}

queue_state_publish_file() {
  local target="$1" schema="$2" content_file="$3" directory temporary_file status=1
  queue_state_begin_serialized_operation || return 1
  directory="$(dirname "$target")"
  if ! mkdir -p "$directory" || ! queue_state_cleanup_temporary_files "$directory"; then
    queue_state_finish_serialized_operation 1; return 1
  fi
  temporary_file="$(mktemp "${directory}/.queue-state.tmp.XXXXXX")" || { queue_state_finish_serialized_operation 1; return 1; }
  if ! cp "$content_file" "$temporary_file" || ! queue_state_validate_file "$temporary_file" "$schema"; then
    rm -f -- "$temporary_file" || true
    queue_state_finish_serialized_operation 1
    return 1
  fi
  if [[ "${QUEUE_STATE_TEST_INTERRUPT_BEFORE_MV:-0}" == 1 ]]; then
    queue_state_error "State publication interrupted before atomic replacement: ${target}"
    queue_state_finish_serialized_operation 1
    return 1
  fi
  if ! queue_state_test_pause before_state_replace; then queue_state_finish_serialized_operation 1; return 1; fi
  if mv -f -- "$temporary_file" "$target"; then status=0; fi
  queue_state_finish_serialized_operation "$status"
}

queue_state_write_content() {
  local target="$1" schema="$2" staging status
  shift 2
  staging="$(mktemp)" || return 1
  if ! printf '%s\n' "$@" > "$staging"; then rm -f -- "$staging" || true; return 1; fi
  if queue_state_publish_file "$target" "$schema" "$staging"; then status=0; else status=$?; fi
  rm -f -- "$staging" || status=1
  return "$status"
}

queue_state_generate_run_id() {
  local runs_dir="${1:-$CODEX_FLOW_QUEUE_RUNS_DIR}" unique_dir suffix
  queue_state_begin_serialized_operation || return 1
  if ! mkdir -p "$runs_dir" || ! queue_state_cleanup_temporary_files "$runs_dir"; then queue_state_finish_serialized_operation 1; return 1; fi
  unique_dir="$(mktemp -d "${runs_dir}/.run-id.XXXXXX")" || { queue_state_finish_serialized_operation 1; return 1; }
  suffix="${unique_dir##*.run-id.}"
  if ! rmdir "$unique_dir"; then queue_state_finish_serialized_operation 1; return 1; fi
  queue_state_finish_serialized_operation 0 || return 1
  printf '%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$suffix"
}

queue_state_create_manifest() {
  local dir="$1" id="$2" issue_csv="$3" every="$4" draft="$5" merge="$6" light_review="$7" review="$8" fix="$9" check_fix="${10}" base_branch="${11}" base_ref="${12}" repository_identity="${13}" status
  queue_state_begin_serialized_operation || return 1
  if [[ -e "${dir}/manifest.state" ]]; then
    queue_state_error "Immutable run manifest already exists: ${dir}/manifest.state"
    queue_state_finish_serialized_operation 1
    return 1
  fi
  if queue_state_write_content "${dir}/manifest.state" manifest \
    "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	${id}" "created_at	$(queue_state_now)" \
    "issues	${issue_csv}" "review_every	${every}" "draft_pr	${draft}" "auto_merge	${merge}" "light_issue_review	${light_review}" \
    "batch_review_reasoning	${review}" "batch_fix_reasoning	${fix}" "batch_check_fix_reasoning	${check_fix}" \
    "base_branch	${base_branch}" "base_ref	${base_ref}" "repository_identity	${repository_identity}"; then status=0; else status=$?; fi
  queue_state_finish_serialized_operation "$status"
}

queue_state_create_run() {
  queue_state_write_content "$1" run "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" "state	$3" "updated_at	$(queue_state_now)"
}

queue_state_create_batch() {
  queue_state_write_content "$1" batch "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" "batch_id	$3" \
    "first_issue	$4" "last_issue	$5" "branch	$6" "base_commit	none" "artifact_path	$7" "state	planned" "updated_at	$(queue_state_now)"
}

queue_state_create_issue() {
  queue_state_write_content "$1" issue "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" "batch_id	$3" \
    "issue_number	$4" "base_commit	none" "commit_sha	none" "artifact_path	none" "state	planned" "updated_at	$(queue_state_now)"
}

queue_state_read_field() {
  local file="$1" schema="$2" requested="$3" value
  local -A fields=()
  queue_state_begin_serialized_operation || return 1
  if ! queue_state_cleanup_temporary_files "$(dirname "$file")" || ! queue_state_parse_file "$file" "$schema" fields || ! queue_state_validate_file "$file" "$schema"; then
    queue_state_finish_serialized_operation 1; return 1
  fi
  if [[ ! -v "fields[$requested]" ]]; then
    queue_state_error "Unknown requested ${schema} field: ${requested}"
    queue_state_finish_serialized_operation 1; return 1
  fi
  value="${fields[$requested]}"
  queue_state_finish_serialized_operation 0 || return 1
  printf '%s\n' "$value"
}

queue_state_transition() {
  local target="$1" schema="$2" entity="$3" expected="$4" requested="$5" key staging status
  local -A fields=()
  queue_state_begin_serialized_operation || return 1
  if ! queue_state_cleanup_temporary_files "$(dirname "$target")" || ! queue_state_parse_file "$target" "$schema" fields || ! queue_state_validate_file "$target" "$schema"; then
    queue_state_finish_serialized_operation 1; return 1
  fi
  if [[ "${fields[state]}" != "$expected" ]]; then
    queue_state_error "Cannot transition ${entity}: expected state '${expected}', actual state '${fields[state]}', requested target state '${requested}'"
    queue_state_finish_serialized_operation 1; return 1
  fi
  case "$schema" in
    run) queue_state_enum_contains "$requested" planned running interrupted failed manual_review_required completed ;;
    batch) queue_state_enum_contains "$requested" planned branch_ready issues_running checks_running review_running accepted publishing completed failed ;;
    issue) queue_state_enum_contains "$requested" planned leased running committed artifacts_archived acknowledged failed ;;
    *) queue_state_error "Unsupported transition schema: ${schema}"; queue_state_finish_serialized_operation 1; return 1 ;;
  esac || {
    queue_state_error "Cannot transition ${entity}: expected state '${expected}', actual state '${fields[state]}', requested target state '${requested}' is invalid"
    queue_state_finish_serialized_operation 1
    return 1
  }
  fields[state]="$requested"; fields[updated_at]="$(queue_state_now)"; staging="$(mktemp)" || { queue_state_finish_serialized_operation 1; return 1; }
  case "$schema" in
    run) for key in schema_version run_id state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    batch) for key in schema_version run_id batch_id first_issue last_issue branch base_commit artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    issue) for key in schema_version run_id batch_id issue_number base_commit commit_sha artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    *) rm -f "$staging"; queue_state_error "Unsupported transition schema: ${schema}"; queue_state_finish_serialized_operation 1; return 1 ;;
  esac
  if queue_state_publish_file "$target" "$schema" "$staging"; then status=0; else status=$?; fi
  rm -f "$staging" || status=1
  queue_state_finish_serialized_operation "$status"
}

queue_state_update_issue() {
  local target="$1" entity="$2" expected="$3" requested="$4" commit_sha="$5" artifact_path="$6" staging status key
  local -A fields=()
  queue_state_begin_serialized_operation || return 1
  if ! queue_state_parse_file "$target" issue fields || ! queue_state_validate_file "$target" issue; then queue_state_finish_serialized_operation 1; return 1; fi
  [[ "${fields[state]}" == "$expected" ]] || { queue_state_error "Cannot update ${entity}: expected state '${expected}', actual state '${fields[state]}'"; queue_state_finish_serialized_operation 1; return 1; }
  fields[state]="$requested"; fields[commit_sha]="$commit_sha"; fields[artifact_path]="$artifact_path"; fields[updated_at]="$(queue_state_now)"
  staging="$(mktemp)" || { queue_state_finish_serialized_operation 1; return 1; }
  for key in schema_version run_id batch_id issue_number base_commit commit_sha artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging"
  if queue_state_publish_file "$target" issue "$staging"; then status=0; else status=$?; fi
  rm -f "$staging" || status=1
  queue_state_finish_serialized_operation "$status"
}

queue_state_set_issue_base() {
  local target="$1" expected="$2" base="$3" staging status key
  local -A fields=()
  queue_state_begin_serialized_operation || return 1
  if ! queue_state_parse_file "$target" issue fields || ! queue_state_validate_file "$target" issue; then queue_state_finish_serialized_operation 1; return 1; fi
  [[ "${fields[state]}" == "$expected" && "${fields[base_commit]}" == none ]] || { queue_state_error 'Issue base can only be recorded once in the expected state'; queue_state_finish_serialized_operation 1; return 1; }
  fields[base_commit]="$base"; fields[updated_at]="$(queue_state_now)"; staging="$(mktemp)" || { queue_state_finish_serialized_operation 1; return 1; }
  for key in schema_version run_id batch_id issue_number base_commit commit_sha artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging"
  if queue_state_publish_file "$target" issue "$staging"; then status=0; else status=$?; fi
  rm -f "$staging" || status=1
  queue_state_finish_serialized_operation "$status"
}

queue_state_update_batch() {
  local target="$1" entity="$2" expected="$3" requested="$4" base_commit="$5" staging status key
  local -A fields=()
  queue_state_begin_serialized_operation || return 1
  if ! queue_state_parse_file "$target" batch fields || ! queue_state_validate_file "$target" batch; then queue_state_finish_serialized_operation 1; return 1; fi
  [[ "${fields[state]}" == "$expected" ]] || { queue_state_error "Cannot update ${entity}: expected state '${expected}', actual state '${fields[state]}'"; queue_state_finish_serialized_operation 1; return 1; }
  fields[state]="$requested"; fields[base_commit]="$base_commit"; fields[updated_at]="$(queue_state_now)"
  staging="$(mktemp)" || { queue_state_finish_serialized_operation 1; return 1; }
  for key in schema_version run_id batch_id first_issue last_issue branch base_commit artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging"
  if queue_state_publish_file "$target" batch "$staging"; then status=0; else status=$?; fi
  rm -f "$staging" || status=1
  queue_state_finish_serialized_operation "$status"
}

queue_state_checkpoint() {
  queue_state_write_content "$1" checkpoint "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" \
    "entity	$3" "phase	$4" "status	$5" "updated_at	$(queue_state_now)"
}

queue_state_write_lease() {
  local target="$1" id="$2" token="$3" generation="$4" pid="$5" host="$6" process_start="$7" displaced_run="${8:-none}" displaced_token="${9:-none}" displaced_generation="${10:-none}"
  queue_state_write_content "$target" lease "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	${id}" \
    "owner_token	${token}" "lease_generation	${generation}" "owner_pid	${pid}" "owner_host	${host}" \
    "process_start	${process_start}" "acquired_at	$(queue_state_now)" "displaced_run_id	${displaced_run}" \
    "displaced_owner_token	${displaced_token}" "displaced_generation	${displaced_generation}"
}

queue_state_publish_pointer() {
  queue_state_write_content "$1" pointer "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" \
    "owner_token	$3" "lease_generation	$4" "updated_at	$(queue_state_now)"
}

queue_state_remove_pointer_if_matches() {
  local target="$1" expected_run="$2" expected_token="${3:-}" expected_generation="${4:-}" actual
  queue_state_begin_serialized_operation || return 1
  if [[ ! -f "$target" ]]; then queue_state_finish_serialized_operation 0; return 0; fi
  actual="$(queue_state_read_field "$target" pointer run_id)" || { queue_state_finish_serialized_operation 1; return 1; }
  [[ "$actual" == "$expected_run" ]] || { queue_state_error "Current pointer belongs to run ${actual}, not ${expected_run}"; queue_state_finish_serialized_operation 1; return 1; }
  if [[ -n "$expected_token" ]]; then
    [[ "$(queue_state_read_field "$target" pointer owner_token)" == "$expected_token" && "$(queue_state_read_field "$target" pointer lease_generation)" == "$expected_generation" ]] || {
      queue_state_error "Current pointer ownership changed for run ${expected_run}"; queue_state_finish_serialized_operation 1; return 1;
    }
  fi
  if ! queue_state_test_pause before_pointer_remove; then queue_state_finish_serialized_operation 1; return 1; fi
  if ! rm -- "$target"; then queue_state_finish_serialized_operation 1; return 1; fi
  queue_state_finish_serialized_operation 0
}

queue_state_record_publish() {
  queue_state_write_content "$1" publish "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	$2" "batch_id	$3" \
    "pr_number	$4" "pr_url	$5" "head_branch	$6" "base_branch	$7" "head_sha	$8" "state	$9" "updated_at	$(queue_state_now)"
}
