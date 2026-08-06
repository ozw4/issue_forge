#!/usr/bin/env bash

readonly CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION='1'

queue_state_error() { printf '[queue-state] %s\n' "$1" >&2; return 1; }
queue_state_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

queue_state_cleanup_temporary_files() {
  local directory="$1" path
  [[ -d "$directory" ]] || return 0
  while IFS= read -r path; do rm -f -- "$path"; done \
    < <(find "$directory" -maxdepth 1 -type f -name '.queue-state.tmp.*' -print | LC_ALL=C sort)
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

queue_state_parse_file() {
  local file="$1" schema="$2" output_name="$3" line key value
  local -n output="$output_name"
  local -A allowed=()
  local -a required=()
  case "$schema" in
    manifest) required=(schema_version run_id created_at issues review_every draft_pr auto_merge batch_review_reasoning batch_fix_reasoning batch_check_fix_reasoning base_branch base_ref) ;;
    run) required=(schema_version run_id state updated_at) ;;
    batch) required=(schema_version run_id batch_id first_issue last_issue branch base_commit artifact_path state updated_at) ;;
    issue) required=(schema_version run_id batch_id issue_number commit_sha artifact_path state updated_at) ;;
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
  else queue_state_require_timestamp "$schema" "${fields[updated_at]}" || return 1; fi
  case "$schema" in
    manifest)
      queue_state_require_issues "${fields[issues]}" || return 1
      [[ "${fields[review_every]}" =~ ^[1-9][0-9]*$ ]] || { queue_state_error "Malformed review_every: ${fields[review_every]}"; return 1; }
      queue_state_enum_contains "${fields[draft_pr]}" 0 1 || { queue_state_error "Malformed draft policy: ${fields[draft_pr]}"; return 1; }
      queue_state_enum_contains "${fields[auto_merge]}" 0 1 || { queue_state_error "Malformed auto-merge policy: ${fields[auto_merge]}"; return 1; }
      [[ "${fields[draft_pr]}:${fields[auto_merge]}" != 1:1 ]] || { queue_state_error 'Draft and auto-merge policies are incompatible'; return 1; }
      queue_state_require_token 'batch review reasoning' "${fields[batch_review_reasoning]}" || return 1
      queue_state_require_token 'batch fix reasoning' "${fields[batch_fix_reasoning]}" || return 1
      queue_state_require_token 'batch check fix reasoning' "${fields[batch_check_fix_reasoning]}" || return 1
      queue_state_require_path 'base branch' "${fields[base_branch]}" || return 1
      queue_state_require_path 'base ref' "${fields[base_ref]}" || return 1
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
      [[ "${fields[commit_sha]}" == none || "${fields[commit_sha]}" =~ ^[0-9a-fA-F]{40,64}$ ]] || { queue_state_error "Malformed Issue commit SHA: ${fields[commit_sha]}"; return 1; }
      [[ "${fields[artifact_path]}" == none ]] || queue_state_require_path 'Issue artifact' "${fields[artifact_path]}" || return 1
      queue_state_enum_contains "${fields[state]}" planned leased running committed artifacts_archived acknowledged failed \
        || { queue_state_error "Malformed Issue state: ${fields[state]}"; return 1; }
      ;;
  esac
}

queue_state_publish_file() {
  local target="$1" schema="$2" content_file="$3" directory temporary_file
  directory="$(dirname "$target")"; mkdir -p "$directory"
  queue_state_cleanup_temporary_files "$directory"
  temporary_file="$(mktemp "${directory}/.queue-state.tmp.XXXXXX")"
  cp "$content_file" "$temporary_file"
  if ! queue_state_validate_file "$temporary_file" "$schema"; then rm -f "$temporary_file"; return 1; fi
  if [[ "${QUEUE_STATE_TEST_INTERRUPT_BEFORE_MV:-0}" == 1 ]]; then
    queue_state_error "State publication interrupted before atomic replacement: ${target}"; return 1
  fi
  mv -f "$temporary_file" "$target"
}

queue_state_write_content() {
  local target="$1" schema="$2" staging status
  shift 2; staging="$(mktemp)"; printf '%s\n' "$@" > "$staging"
  queue_state_publish_file "$target" "$schema" "$staging"; status=$?; rm -f "$staging"; return "$status"
}

queue_state_generate_run_id() {
  local runs_dir="${1:-$CODEX_FLOW_QUEUE_RUNS_DIR}" unique_dir suffix
  mkdir -p "$runs_dir"; queue_state_cleanup_temporary_files "$runs_dir"
  unique_dir="$(mktemp -d "${runs_dir}/.run-id.XXXXXX")"; suffix="${unique_dir##*.run-id.}"; rmdir "$unique_dir"
  printf '%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$suffix"
}

queue_state_create_manifest() {
  local dir="$1" id="$2" issue_csv="$3" every="$4" draft="$5" merge="$6" review="$7" fix="$8" check_fix="$9" base_branch="${10}" base_ref="${11}"
  [[ ! -e "${dir}/manifest.state" ]] || { queue_state_error "Immutable run manifest already exists: ${dir}/manifest.state"; return 1; }
  queue_state_write_content "${dir}/manifest.state" manifest \
    "schema_version	${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}" "run_id	${id}" "created_at	$(queue_state_now)" \
    "issues	${issue_csv}" "review_every	${every}" "draft_pr	${draft}" "auto_merge	${merge}" \
    "batch_review_reasoning	${review}" "batch_fix_reasoning	${fix}" "batch_check_fix_reasoning	${check_fix}" \
    "base_branch	${base_branch}" "base_ref	${base_ref}"
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
    "issue_number	$4" "commit_sha	none" "artifact_path	none" "state	planned" "updated_at	$(queue_state_now)"
}

queue_state_read_field() {
  local file="$1" schema="$2" requested="$3"
  local -A fields=()
  queue_state_cleanup_temporary_files "$(dirname "$file")"
  queue_state_parse_file "$file" "$schema" fields || return 1; queue_state_validate_file "$file" "$schema" || return 1
  [[ -v "fields[$requested]" ]] || { queue_state_error "Unknown requested ${schema} field: ${requested}"; return 1; }
  printf '%s\n' "${fields[$requested]}"
}

queue_state_transition() {
  local target="$1" schema="$2" entity="$3" expected="$4" requested="$5" key staging status
  local -A fields=()
  queue_state_cleanup_temporary_files "$(dirname "$target")"
  queue_state_parse_file "$target" "$schema" fields || return 1; queue_state_validate_file "$target" "$schema" || return 1
  if [[ "${fields[state]}" != "$expected" ]]; then
    queue_state_error "Cannot transition ${entity}: expected state '${expected}', actual state '${fields[state]}', requested target state '${requested}'"; return 1
  fi
  case "$schema" in
    run) queue_state_enum_contains "$requested" planned running interrupted failed manual_review_required completed ;;
    batch) queue_state_enum_contains "$requested" planned branch_ready issues_running checks_running review_running accepted publishing completed failed ;;
    issue) queue_state_enum_contains "$requested" planned leased running committed artifacts_archived acknowledged failed ;;
    *) queue_state_error "Unsupported transition schema: ${schema}"; return 1 ;;
  esac || {
    queue_state_error "Cannot transition ${entity}: expected state '${expected}', actual state '${fields[state]}', requested target state '${requested}' is invalid"
    return 1
  }
  fields[state]="$requested"; fields[updated_at]="$(queue_state_now)"; staging="$(mktemp)"
  case "$schema" in
    run) for key in schema_version run_id state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    batch) for key in schema_version run_id batch_id first_issue last_issue branch base_commit artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    issue) for key in schema_version run_id batch_id issue_number commit_sha artifact_path state updated_at; do printf '%s\t%s\n' "$key" "${fields[$key]}"; done > "$staging" ;;
    *) rm -f "$staging"; queue_state_error "Unsupported transition schema: ${schema}"; return 1 ;;
  esac
  queue_state_publish_file "$target" "$schema" "$staging"; status=$?; rm -f "$staging"; return "$status"
}
