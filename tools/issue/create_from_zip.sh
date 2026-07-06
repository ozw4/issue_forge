#!/usr/bin/env bash
set -euo pipefail

repo=''
zip_file=''
work_parent=''
extract_root=''
dry_run=0
keep_work_dir=0
auto_login=0
create_labels=1

declare -a labels=()
declare -a create_label_names=()
declare -a create_label_colors=()
declare -a create_label_descriptions=()
declare -a issue_files=()
declare -a label_args=()

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: create_from_zip.sh [options] <issues.zip>

Create GitHub issues from every .md file in a zip archive.
The first '# ...' heading in each markdown file is used as the issue title;
if no such heading exists, the markdown filename is used instead.

Options:
  --repo OWNER/REPO                 Target GitHub repository. If omitted, the
                                    current gh repository is used.
  --label LABEL                     Apply an existing label to every issue.
                                    May be repeated.
  --create-label NAME COLOR DESC    Create/update a label with gh label create
                                    --force, and apply it to every issue.
                                    COLOR may be 6 hex digits with or without #.
                                    May be repeated.
  --no-create-labels                Do not create/update labels; still applies
                                    labels named by --create-label/--label.
  --work-dir DIR                    Parent directory for zip extraction.
                                    A fresh child directory is created inside it.
  --keep-work-dir                   Do not delete the extraction directory.
  --dry-run                         Print planned label and issue operations
                                    without calling gh label/issue create.
  --login                           Run gh auth login if gh auth status fails.
  -h, --help                        Show this help.

Example:
  create_from_zip.sh \
    --repo ozw4/seis_hypo \
    --create-label refactor 1D76DB "Refactoring task" \
    --create-label codex 5319E7 "Task prepared for Codex" \
    --create-label strict-proc-layout D93F0B "Move project code out of proc and enforce data/configs/runs layout" \
    strict_proc_to_src_migration_issues_codex.zip
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

absolute_file_path() {
  local input_path="$1"
  local input_dir
  local input_base

  input_dir="$(dirname -- "$input_path")"
  input_base="$(basename -- "$input_path")"

  if ! input_dir="$(cd "$input_dir" 2>/dev/null && pwd)"; then
    fail "Invalid path: $input_path"
  fi

  printf '%s/%s\n' "$input_dir" "$input_base"
}

validate_no_newline() {
  local value="$1"
  local field_name="$2"

  case "$value" in
    *$'\n'*|*$'\r'*)
      fail "${field_name} must not contain newlines"
      ;;
  esac
}

normalize_label_color() {
  local color="$1"

  color="${color#\#}"
  if [[ ! "$color" =~ ^[0-9A-Fa-f]{6}$ ]]; then
    fail "Label color must be 6 hexadecimal digits: $1"
  fi

  printf '%s\n' "$color"
}

add_label() {
  local label="$1"
  local existing

  if [[ -z "$label" ]]; then
    fail 'Label name must not be empty'
  fi
  validate_no_newline "$label" 'Label name'

  for existing in "${labels[@]}"; do
    if [[ "$existing" == "$label" ]]; then
      return 0
    fi
  done

  labels+=("$label")
}

add_label_to_create() {
  local name="$1"
  local color="$2"
  local description="$3"

  if [[ -z "$name" ]]; then
    fail 'Label name must not be empty'
  fi
  validate_no_newline "$name" 'Label name'
  validate_no_newline "$description" 'Label description'
  color="$(normalize_label_color "$color")"

  create_label_names+=("$name")
  create_label_colors+=("$color")
  create_label_descriptions+=("$description")
  add_label "$name"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ "$#" -ge 2 ]] || fail 'Missing value for --repo'
        repo="$2"
        shift 2
        ;;
      --label)
        [[ "$#" -ge 2 ]] || fail 'Missing value for --label'
        add_label "$2"
        shift 2
        ;;
      --create-label)
        [[ "$#" -ge 4 ]] || fail 'Missing values for --create-label NAME COLOR DESC'
        add_label_to_create "$2" "$3" "$4"
        shift 4
        ;;
      --no-create-labels)
        create_labels=0
        shift
        ;;
      --work-dir)
        [[ "$#" -ge 2 ]] || fail 'Missing value for --work-dir'
        work_parent="$2"
        shift 2
        ;;
      --keep-work-dir)
        keep_work_dir=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --login)
        auto_login=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        fail "Unknown option: $1"
        ;;
      *)
        if [[ -n "$zip_file" ]]; then
          fail "Only one zip file may be supplied: $zip_file and $1"
        fi
        zip_file="$1"
        shift
        ;;
    esac
  done

  while [[ "$#" -gt 0 ]]; do
    if [[ -n "$zip_file" ]]; then
      fail "Only one zip file may be supplied: $zip_file and $1"
    fi
    zip_file="$1"
    shift
  done

  [[ -n "$zip_file" ]] || fail 'Missing issues.zip argument'
}

resolve_repo() {
  local resolved_repo

  if [[ -n "$repo" ]]; then
    validate_no_newline "$repo" 'Repository'
    if [[ "$repo" != */* || "$repo" =~ [[:space:]] ]]; then
      fail "Repository must look like OWNER/REPO or HOST/OWNER/REPO: $repo"
    fi
    return 0
  fi

  require_command gh
  if ! resolved_repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    fail 'Could not resolve target repository from current directory; pass --repo OWNER/REPO.'
  fi

  [[ -n "$resolved_repo" ]] || fail 'gh repo view returned an empty repository name; pass --repo OWNER/REPO.'
  repo="$resolved_repo"
}

ensure_gh_auth() {
  if [[ "$dry_run" -eq 1 ]]; then
    return 0
  fi

  require_command gh
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$auto_login" -eq 1 ]]; then
    gh auth login
    gh auth status >/dev/null 2>&1 || fail 'GitHub CLI authentication still failed after gh auth login.'
    return 0
  fi

  fail 'GitHub CLI is not authenticated. Run gh auth login first, or pass --login to run it from this script.'
}

validate_zip_entries() {
  local entry
  local listing
  local part
  local -a parts=()

  if ! listing="$(unzip -Z1 -- "$zip_file")"; then
    fail "Failed to read zip entries: $zip_file"
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    case "$entry" in
      /*|[A-Za-z]:*)
        fail "Unsafe zip entry path: $entry"
        ;;
      *\\*)
        fail "Unsafe zip entry contains a backslash path separator: $entry"
        ;;
    esac

    IFS='/' read -r -a parts <<< "$entry"
    for part in "${parts[@]}"; do
      if [[ "$part" == '..' ]]; then
        fail "Unsafe zip entry contains '..': $entry"
      fi
    done
  done <<< "$listing"
}

prepare_extract_dir() {
  local parent_template

  if [[ -z "$work_parent" ]]; then
    work_parent="${TMPDIR:-/tmp}"
  fi

  mkdir -p -- "$work_parent"
  parent_template="${work_parent%/}/issue_forge_issues.XXXXXX"
  extract_root="$(mktemp -d "$parent_template")"
}

cleanup() {
  if [[ "$keep_work_dir" -eq 0 && -n "$extract_root" ]]; then
    rm -rf -- "$extract_root"
  fi
}

extract_zip() {
  validate_zip_entries
  prepare_extract_dir
  unzip -q -o -- "$zip_file" -d "$extract_root"
}

collect_issue_files() {
  mapfile -t issue_files < <(find "$extract_root" -type f -name '*.md' | LC_ALL=C sort)

  if [[ "${#issue_files[@]}" -eq 0 ]]; then
    fail "No markdown issue files found in zip: $zip_file"
  fi
}

issue_title_from_file() {
  local file="$1"
  local title
  local base_name

  title="$(awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /^# /) {
        sub(/^# /, "", $0)
        sub(/^[[:space:]]+/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print $0
        exit
      }
    }
  ' "$file")"

  if [[ -n "$title" ]]; then
    printf '%s\n' "$title"
    return 0
  fi

  base_name="$(basename -- "$file")"
  printf '%s\n' "${base_name%.md}"
}

prepare_label_args() {
  local label

  label_args=()
  for label in "${labels[@]}"; do
    label_args+=(--label "$label")
  done
}

create_or_update_labels() {
  local index
  local label_name
  local label_color
  local label_description

  if [[ "$create_labels" -eq 0 ]]; then
    return 0
  fi

  for index in "${!create_label_names[@]}"; do
    label_name="${create_label_names[$index]}"
    label_color="${create_label_colors[$index]}"
    label_description="${create_label_descriptions[$index]}"

    if [[ "$dry_run" -eq 1 ]]; then
      printf 'DRY-RUN label: create/update %s on %s (#%s)\n' "$label_name" "$repo" "$label_color"
      continue
    fi

    printf 'Creating/updating label: %s\n' "$label_name"
    gh label create "$label_name" \
      --repo "$repo" \
      --description "$label_description" \
      --color "$label_color" \
      --force >/dev/null
  done
}

create_issues() {
  local file
  local title
  local relative_path

  for file in "${issue_files[@]}"; do
    title="$(issue_title_from_file "$file")"
    relative_path="${file#"$extract_root"/}"

    if [[ "$dry_run" -eq 1 ]]; then
      printf 'DRY-RUN issue: %s <- %s\n' "$title" "$relative_path"
      continue
    fi

    printf 'Creating issue: %s\n' "$title"
    gh issue create \
      --repo "$repo" \
      --title "$title" \
      --body-file "$file" \
      "${label_args[@]}"
  done
}

main() {
  parse_args "$@"

  require_command unzip
  require_command find
  require_command sort
  require_command awk
  require_command mktemp

  zip_file="$(absolute_file_path "$zip_file")"
  [[ -f "$zip_file" ]] || fail "Zip file not found: $zip_file"

  resolve_repo
  ensure_gh_auth
  trap cleanup EXIT

  extract_zip
  collect_issue_files
  prepare_label_args

  printf 'Target repo: %s\n' "$repo"
  printf 'Extracted zip: %s\n' "$extract_root"
  printf 'Markdown issue files: %s\n' "${#issue_files[@]}"

  create_or_update_labels
  create_issues

  if [[ "$keep_work_dir" -eq 1 ]]; then
    printf 'Kept extraction directory: %s\n' "$extract_root"
  fi
}

main "$@"
