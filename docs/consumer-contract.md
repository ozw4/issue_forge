# Codex Engine / Consumer Contract

Status:

- current v1 contract for using `issue_forge` as a shared shell engine
- focused on direct vendor usage from a consumer repo
- preserves existing `.work` layout, history naming, branch naming, review format, and GitHub issue / PR behavior

## 1. Contract Summary

`issue_forge` is a shared shell engine. External consumers use it directly from `vendor/issue_forge`; they do not need local wrapper scripts under `./tools/codex` or `./tools/issue`. Consumers may opt in to local convenience files for `run 5` style usage, but those files are not required for the engine contract.

This repository still self-hosts the engine and therefore keeps checked-in entrypoints under `tools/codex/` and `tools/issue/` for engine development, smoke coverage, and local verification.

## 2. Consumer Entry Points

External consumer-facing entrypoints are:

| Path | Arguments | Role |
| --- | --- | --- |
| `vendor/issue_forge/tools/consumer/init.sh` | `[--scaffold-checks\|--scaffold-run] [consumer-root]` | First-time consumer setup: update `.gitignore`, create `.issue_forge/project.sh` if missing, warn about missing consumer-owned checks/README files by default, and optionally scaffold a starter checks hook or local run convenience files |
| `vendor/issue_forge/tools/issue/create_from_zip.sh` | `[options] <issues.zip>` | Create GitHub issues from markdown files inside a zip archive; title comes from the first `# ...` heading or the markdown filename |
| `vendor/issue_forge/tools/issue/start_from_issue.sh` | `<issue_number>` | Bootstrap issue context, create branch, initialize `.work/codex` for the new Issue, and write `.work/base_commit`, `.work/current_issue`, `.work/current_branch`, `.work/issues/<issue>.md` |
| `vendor/issue_forge/tools/codex/doctor.sh` | none | Preflight required commands, GitHub auth, consumer config, base ref, prompt path, and checks command |
| `vendor/issue_forge/tools/codex/run_issue_flow.sh` | `[issue_number]` | Run implementation, checks/fix loop, review/fix loop, commit, push, and PR create/update |
| `vendor/issue_forge/tools/codex/run_issue_queue.sh` | `[options] <issue_number> [issue_number...]` | Local-only sequential issue queue: process issues linearly on batch branches, run strict batch review, create one batch PR per batch, and optionally request auto-merge |
| `vendor/issue_forge/tools/codex/restart_issue_flow.sh` | `[--hard] [issue_number]` | Delete `.work/codex`, optionally discard dirty changes outside `.work`, and rerun the flow |
| `vendor/issue_forge/tools/codex/continue_after_review.sh` | `[issue_number]` | Commit current changes as review follow-up, delete `.work/codex`, and rerun the flow |
| `vendor/issue_forge/tools/codex/make_pr_only.sh` | `[issue_number]` | Create or sync the PR title/body for the current issue branch without pushing new commits |
| `vendor/issue_forge/tools/codex/run_codex.sh` | `<write\|read> <prompt_file>` | Invoke `codex exec` with the mode-specific sandbox and reasoning profile |

`vendor/issue_forge/tools/issue/create_from_zip.sh` is a GitHub Issue creation helper, not an implementation/PR flow. It does not modify `.work/`, create branches, run Codex, or publish PRs. It requires `unzip`, `find`, `sort`, `awk`, and `mktemp`, and it requires `gh` plus a successful `gh auth status` for non-dry-run issue creation. `--login` may be used to run `gh auth login` when auth status fails.

The zip importer extracts to a fresh temporary child directory, rejects unsafe zip entries with absolute paths, drive-letter absolute paths, backslash separators, or `..` path components, then imports every regular `*.md` file sorted by path. For each file, the first `# ...` heading becomes the issue title; if no such heading exists, the `.md` filename without extension becomes the title. `--create-label NAME COLOR DESCRIPTION` creates or updates a label with `gh label create --force` and applies it to every issue. `--label LABEL` applies an existing label. `--no-create-labels` skips label creation while keeping labels in issue creation arguments. `--dry-run` prints planned operations without calling `gh label create` or `gh issue create`.

For this repository only, self-hosting entrypoints under `tools/codex/` and `tools/issue/` remain supported.

## 3. Minimal Consumer-Owned Files

Consumer-owned paths are:

| Path | Required | Notes |
| --- | --- | --- |
| `.issue_forge/project.sh` | yes | May be empty; engine applies defaults before validation; `tools/consumer/init.sh` creates a minimal default file when missing |
| `.issue_forge/checks/run_changed.sh` | yes | Default checks hook path; must be executable; `tools/consumer/init.sh` only warns when it is missing unless `--scaffold-checks` is explicitly passed |
| `.issue_forge/shell.sh` | no | Optional consumer-owned shell snippet generated only by `tools/consumer/init.sh --scaffold-run`; source it manually to define a `run` function |
| `AGENTS.md` | yes | Consumer-owned repo instructions |
| `README.md` | recommended | Primary consumer documentation entrypoint; `tools/consumer/init.sh` warns when it is missing but does not create it |
| `docs/README.md` | optional | Optional consumer docs index for additional source-of-truth docs; `tools/consumer/init.sh` does not warn when it is missing and does not create it |
| `tools/run_issue.sh` | no | Optional consumer-owned wrapper generated only by `tools/consumer/init.sh --scaffold-run`; it delegates to direct vendor entrypoints |
| `vendor/issue_forge` | yes | Bind-mounted or symlinked engine root; not committed by the consumer repo |

First-time consumer initialization may be done by running:

```bash
./vendor/issue_forge/tools/consumer/init.sh [--scaffold-checks|--scaffold-run] [consumer-root]
```

With no flags, that command:

- updates consumer `.gitignore` with `.work`, `.work/`, `vendor/issue_forge`, and `vendor/issue_forge/`
- creates `.issue_forge/project.sh` when it is missing
- warns about missing `.issue_forge/checks/run_changed.sh`
- warns about missing `README.md`
- does not warn about missing `docs/README.md`
- does not create checks, `README.md`, or `docs/README.md`
- does not create `tools/run_issue.sh` or `.issue_forge/shell.sh`
- does not stage or commit changes

When `--scaffold-checks` is explicitly passed, the same entrypoint creates `.issue_forge/checks/run_changed.sh` only if that file is missing, creates the parent directory when needed, makes the file executable, and suppresses the missing-checks warning after creation. Existing checks files are consumer-owned and are never overwritten; init logs that the file already exists. The starter hook is intentionally minimal: it collects changed files relative to the supplied base ref while excluding `.work` and consumer-local `vendor/issue_forge`, runs `shellcheck -x` only when changed shell files exist, and runs `pytest -q` only when Python-related files change. Consumers may edit the starter for their own repo after generation.

This opt-in scaffold does not change `CODEX_FLOW_CHECKS_COMMAND`, does not add config toggles, and does not change `doctor.sh` or engine-wide required commands.

When `--scaffold-run` is explicitly passed, the same entrypoint creates `tools/run_issue.sh` and `.issue_forge/shell.sh` only when those files are missing, creates parent directories when needed, and makes `tools/run_issue.sh` executable. Existing files are consumer-owned and are never overwritten; init logs that they already exist. This scaffold does not create checks or docs and does not suppress the normal missing checks/README warnings.

The generated `tools/run_issue.sh` is a convenience wrapper. It resolves the consumer repo root from its own `tools/` directory, requires `.issue_forge/project.sh`, sources `vendor/issue_forge/tools/codex/lib/config.sh` and `vendor/issue_forge/tools/codex/lib/flow_state.sh`, validates the issue with `require_numeric_issue_number`, verifies a clean worktree with `ensure_clean_worktree`, syncs `${CODEX_FLOW_BASE_BRANCH}` from origin, then delegates to `vendor/issue_forge/tools/issue/start_from_issue.sh <issue>` and `vendor/issue_forge/tools/codex/run_issue_flow.sh <issue>`. It does not duplicate issue bootstrap state or publish behavior.

The generated `.issue_forge/shell.sh` is a source-only snippet that defines `run()`. After a user manually runs `source .issue_forge/shell.sh`, `run 5` resolves the current git worktree root from any subdirectory and forwards arguments to `${root}/tools/run_issue.sh`. Init does not source this file, edit shell startup files such as `~/.bashrc`, `~/.zshrc`, or `~/.profile`, or modify global `PATH`.

Optional consumer overrides:

- custom prompt templates via `CODEX_FLOW_PROMPTS_DIR`
- non-default checks command via `CODEX_FLOW_CHECKS_COMMAND`
- non-default base branch / base ref / branch prefix / draft policy / profile settings via `.issue_forge/project.sh`

External consumers do not need:

- `./tools/run_issue.sh`
- `./tools/codex/*.sh`
- `./tools/issue/*.sh`
- `./tools/codex/prompts/*.prompt.md.tmpl`

## 4. Runtime Roots

Runtime distinguishes engine root from consumer root.

| Variable | Meaning |
| --- | --- |
| `ISSUE_FORGE_ENGINE_ROOT` | The logical engine root as invoked, such as `./vendor/issue_forge` |
| `ISSUE_FORGE_ENGINE_CODEX_DIR` | `${ISSUE_FORGE_ENGINE_ROOT}/tools/codex` |
| `ISSUE_FORGE_ENGINE_ISSUE_DIR` | `${ISSUE_FORGE_ENGINE_ROOT}/tools/issue` |
| `CODEX_FLOW_REPO_ROOT` | Consumer repository root |

The engine path must preserve logical vendor behavior. Do not canonicalize it with `realpath` or `pwd -P` in a way that loses `vendor/issue_forge` from the path later used for git exclusion.

## 5. Consumer Root Resolution

`tools/codex/lib/config.sh` resolves `CODEX_FLOW_REPO_ROOT` in this order:

1. If `ISSUE_FORGE_CONSUMER_ROOT` is set:
   - resolve it to an absolute path
   - require `.issue_forge/project.sh` to exist there
   - otherwise fail immediately
2. Use the current working directory git root when it contains `.issue_forge/project.sh` and it is not the engine root
3. If the engine root is under a `vendor/` directory, use the git root of that vendor parent when it contains `.issue_forge/project.sh`
4. Use the engine root git root when it contains `.issue_forge/project.sh`
5. Otherwise fail with a clear message instructing the user to run from the consumer repo root or set `ISSUE_FORGE_CONSUMER_ROOT`

Invalid explicit configuration is a hard error. The engine does not silently fall back to another consumer root after a bad `ISSUE_FORGE_CONSUMER_ROOT`.

## 6. Consumer Config Defaults

After sourcing `.issue_forge/project.sh`, the engine applies these defaults before validation:

| Setting | Default |
| --- | --- |
| `CODEX_FLOW_BASE_BRANCH` | `main` |
| `CODEX_FLOW_BASE_REF` | `origin/${CODEX_FLOW_BASE_BRANCH}` |
| `CODEX_FLOW_BRANCH_PREFIX` | `issue/` |
| `CODEX_FLOW_CHECKS_COMMAND` | `./.issue_forge/checks/run_changed.sh` |
| `CODEX_FLOW_PROMPTS_DIR` | `${ISSUE_FORGE_ENGINE_ROOT}/tools/codex/prompts` |
| `CODEX_FLOW_PR_DRAFT_DEFAULT` | `1` |
| `CODEX_FLOW_PROFILE_WRITE_SANDBOX` | `danger-full-access` |
| `CODEX_FLOW_PROFILE_WRITE_REASONING` | `high` |
| `CODEX_FLOW_PROFILE_READ_SANDBOX` | `danger-full-access` |
| `CODEX_FLOW_PROFILE_READ_REASONING` | `medium` |
| `CODEX_FLOW_IMPLEMENTATION_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` |
| `CODEX_FLOW_CHECK_FIX_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` |
| `CODEX_FLOW_REVIEW_REASONING` | `${CODEX_FLOW_PROFILE_READ_REASONING}` |
| `CODEX_FLOW_REVIEW_FIX_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` |
| `CODEX_FLOW_BATCH_BRANCH_PREFIX` | `batch/` |
| `CODEX_FLOW_QUEUE_REVIEW_EVERY` | `3` |
| `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW` | `1` |
| `CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT` | `0` |
| `CODEX_FLOW_BATCH_REVIEW_REASONING` | `xhigh` |
| `CODEX_FLOW_BATCH_FIX_REASONING` | `xhigh` |
| `CODEX_FLOW_BATCH_CHECK_FIX_REASONING` | `xhigh` |
| `CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS` | `5` |
| `CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS` | `5` |
| `CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS` | `900` |
| `CODEX_FLOW_AUTO_MERGE_POLL_SECONDS` | `15` |

Validation still runs after defaults. Missing or malformed values after defaulting remain hard errors.

Only the queue variables in this table are consumer configuration. Guard depth, guard file descriptors, ownership-assertion recursion state, guard callbacks, and other `QUEUE_STATE_*` / `ISSUE_FORGE_INTERNAL_QUEUE_*` names are private process state. The queue clears imported legacy private names before loading consumer configuration, initializes the internal names from literals, and fails before touching `.work/queue` if `.issue_forge/project.sh` supplies a private name that cannot be safely neutralized. Failpoints, barriers, and pauses are test hooks, not consumer configuration; they are accepted only when the invocation explicitly imports `CODEX_FLOW_QUEUE_TEST_MODE=1`. Production invocations reject configured test hooks.

The single-issue flow always passes explicit per-phase reasoning to `run_codex.sh`: implementation uses `CODEX_FLOW_IMPLEMENTATION_REASONING`, checks repair uses `CODEX_FLOW_CHECK_FIX_REASONING`, review uses `CODEX_FLOW_REVIEW_REASONING`, and review repair uses `CODEX_FLOW_REVIEW_FIX_REASONING`. These values must be non-empty and contain no whitespace after defaults are applied. The defaults preserve the prior write/read profile behavior while allowing consumers to lower normal implementation effort and keep repair phases stricter.

`CODEX_RUN_REASONING_EFFORT` is a narrow per-invocation override for `run_codex.sh`. When set, it must be non-empty and contain no whitespace; it replaces the selected profile reasoning value for that invocation only and does not change sandbox selection or mutate profile config.

This repository’s own `.issue_forge/project.sh` may continue to set explicit self-hosted values such as:

```sh
CODEX_FLOW_CHECKS_COMMAND='./tools/checks/run_changed.sh'
CODEX_FLOW_PROMPTS_DIR='tools/codex/prompts'
```

That self-hosting detail is not part of the external consumer requirement.

## 7. Prompts and Checks

Prompt behavior:

- default prompt templates are engine-owned and live at `vendor/issue_forge/tools/codex/prompts/`
- consumers may optionally override `CODEX_FLOW_PROMPTS_DIR`
- `.work/codex/*.prompt.md` output paths are unchanged
- Issue and batch review prompts receive the authoritative checks manifest path as an artifact; a missing manifest means checks evidence is not available yet, and raw check logs are not embedded in the prompt
- consumers with custom `CODEX_FLOW_PROMPTS_DIR` need the batch prompt templates when they use `run_issue_queue.sh`; missing batch templates are a hard queue error
- when `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW` is non-zero, queue mode also requires `review-light.prompt.md.tmpl`; missing light review templates are a hard queue error

Checks behavior:

- default checks hook is `./.issue_forge/checks/run_changed.sh`
- invocation is `./.issue_forge/checks/run_changed.sh <fixed_base_commit>` unless explicitly overridden
- stdout/stderr are captured into `.work/codex/checks.log`
- exit `0` means pass; non-zero enters the fix-from-checks loop
- the checks hook must be non-interactive and validation-only
- `tools/consumer/init.sh --scaffold-checks` can create a minimal consumer-owned starter at that default path; the starter runs `shellcheck -x` for changed shell files and `pytest -q` for Python-related changes only

Each checks invocation is authoritative as an immutable, snapshot-bound attempt. A standalone Issue flow stores attempts below `.work/codex/check-attempts/issue-checks/` and rows in `.work/codex/checks.manifest.tsv`. An attempt is created as `attempt-NNNN.running/`, captures the existing review-snapshot schema immediately before execution, and is renamed once to `attempt-NNNN/` only after `request.state`, `snapshot.state`, ordered `argv.tsv`, `combined.log`, `result.state`, and `artifacts.sha256` are complete. Existing terminal and `.running` directories are never overwritten; later execution uses the next ID.

`request.state` schema version 1 binds `check_id`, Issue or Batch scope and identity, `issue-checks` or `batch-checks` operation, round, attempt ID, `consumer-hook` kind, `consumer-check-hook` requirement, fixed base commit, a SHA-256 fingerprint of the excluded-path-aware porcelain status, and start timestamp. The status fingerprint supplements rather than replaces the existing review snapshot and detects staging-only changes whose worktree tree is unchanged. `argv.tsv` records the configured checks executable as argv index 0 and the base commit as argv index 1 without parsing a command string. Literal tabs, CR, and LF are rejected. `result.state` schema version 1 records `passed`, `failed`, `interrupted`, or `invalid`, process exit status and signal classification, start/finish/duration, snapshot match, and the combined-log SHA-256. Only exit 0 with an unchanged snapshot and status fingerprint is `passed`; 130 and 143 are `interrupted`; any tracked, staged, or untracked repository change outside the standard exclusions is `invalid` even when the command exits 0. The engine does not revert a mutating check.

The strict checks manifest columns are:

```text
check_id\tscope\tscope_id\toperation\tround\tattempt_id\tkind\trequirement_id\tbase_commit\tsnapshot_head\tsnapshot_tree\tstatus\texit_status\tsignal\tstarted_at\tfinished_at\tduration_ms\tlog_path\tlog_sha256
```

Manifest publication uses a sibling temporary file and atomic rename. Readers reject malformed headers, column counts, enums, timestamps, hashes, non-normalized repository-relative paths, duplicate check/attempt identities, missing terminal directories, mismatched request/result/snapshot fields, and log or artifact hash drift. `.running` attempts are not manifest rows. `.work/codex/checks.log` remains a compatibility and PR-summary view, atomically copied only from a terminal `combined.log`; check round history is copied from that same immutable log. Neither legacy file is the source of truth for pass/fail or provenance.

## 8. PR Publish Behavior

PR publishing uses one shared engine helper for full flow publishing and `make_pr_only.sh`.

When an open PR already exists for the current issue branch and configured base branch, the engine synchronizes only title/body:

```bash
gh pr edit <existing-pr-url> --title <issue-title> --body-file <generated-body>
```

It does not change draft/open state, reviewers, labels, or other PR metadata.

When no open PR exists, the engine creates one with `gh pr create`, still honoring `CODEX_FLOW_PR_DRAFT_DEFAULT`.

The generated PR body is deterministic and assembled from local issue/git/artifact state:

```text
Closes #<issue>

## Summary
- <issue title from .work/issues/<issue>.md>

## Changed files
- `<path>`

## Checks
- `.work/codex/checks.log`: <last non-empty line>

## Review
- `.work/codex/review.txt`: accept: yes/no
- findings: blocker <n>, major <n>, minor <n>
```

If checks or review artifacts do not exist yet, their section says `not available yet`. The summary and checks line are emitted as-is rather than byte-truncated, so UTF-8 issue titles and check output remain intact.

Changed files come from the PR branch diff against the saved fixed base commit in `.work/base_commit`. This intentionally ignores uncommitted worktree-only state and avoids the moving-base problem when `origin/main` advances after issue bootstrap. The same worktree exclusion contract applies, so `.work/` and consumer-local `vendor/issue_forge` are not listed.

## 9. Local Sequential Queue

`run_issue_queue.sh` is local-only. It does not install or depend on GitHub Actions workflows, does not invoke Copilot review, does not request human reviewers, and does not add labels or projects.

Queue ownership is local to one checkout. Before any `.work/queue` or Git-common-dir queue path is created or inspected, the queue resolves and normalizes `git rev-parse --path-format=absolute --git-dir` and `--git-common-dir`. The two paths must be identical. A linked worktree, whose Git directory is worktree-specific while its common directory is shared, is rejected for fresh and resume invocations with direction to use the primary worktree or a separate clone. A primary worktree remains supported when other linked worktrees are merely registered. Separate clones and machines are not coordinated by this local lease.

Usage:

```bash
vendor/issue_forge/tools/codex/run_issue_queue.sh [options] <issue_number> [issue_number...]
vendor/issue_forge/tools/codex/run_issue_queue.sh --resume <run_id|current> [--take-over-lease]
```

Options:

- `--review-every <positive_integer>` sets the number of issues per batch PR; the default is `CODEX_FLOW_QUEUE_REVIEW_EVERY=3`
- `--batch-review-effort <value>` overrides `CODEX_FLOW_BATCH_REVIEW_REASONING` for that queue run
- `--batch-fix-effort <value>` overrides both `CODEX_FLOW_BATCH_FIX_REASONING` and `CODEX_FLOW_BATCH_CHECK_FIX_REASONING` for that queue run
- `--auto-merge` requests auto-merge for each batch PR and waits for it to merge before starting the next batch
- `--draft` creates draft batch PRs; it cannot be combined with `--auto-merge`
- `--resume <run_id|current>` resumes unfinished work only from the immutable manifest identified by the run ID, or performs cleanup-only finalization for a completed run. It rejects Issue arguments and all queue-shaping options.
- `--take-over-lease` is valid only with `--resume`; it is required for a lease owned by another or unverifiable host. A dead same-host owner is recoverable without this option only by explicit resume of the lease's same run ID. A live same-host owner always blocks takeover. By using different-host takeover, the operator asserts that the displaced process has stopped; elapsed time alone is never proof of death.

The queue processes issues strictly in the input order. It creates one deterministic batch branch per batch, named `${CODEX_FLOW_BATCH_BRANCH_PREFIX}<first_issue>-<last_issue>`; with defaults this is `batch/<first_issue>-<last_issue>`. After fetching `origin/${CODEX_FLOW_BASE_BRANCH}`, it resolves `CODEX_FLOW_BASE_REF` to an exact commit and persists that intended base before branch creation. The branch is created only from the saved SHA. A resumed branch-ready boundary accepts an existing branch only when its HEAD equals that SHA; unexplained commits and local/remote disagreement fail closed.

The queue never calls `tools/issue/start_from_issue.sh`. In standalone use, that entrypoint removes the prior `.work/codex` only after the new Issue branch has been created successfully, so review, check, log, and finding artifacts start at the new Issue boundary. For each queued issue, the queue fetches issue context with the existing issue bootstrap helper, writes `.work/current_issue`, `.work/current_branch`, and `.work/base_commit`, records the current batch branch as `.work/current_branch`, records the current `HEAD` before that issue as `.work/base_commit`, and then runs:

```bash
CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_LIGHT_ISSUE_REVIEW=<0-or-1> vendor/issue_forge/tools/codex/run_issue_flow.sh <issue_number>
```

`CODEX_FLOW_SKIP_PUBLISH=1` keeps the normal issue implementation, checks, review, fix loops, and commit behavior, but skips the issue branch push and issue PR creation. Queue mode derives `CODEX_FLOW_LIGHT_ISSUE_REVIEW` from `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW` for each per-issue flow: non-zero sets `1`, so `.work/codex/review.prompt.md` is rendered from `review-light.prompt.md.tmpl`; `0` sets `0`, so full strict per-issue review is used even if the parent environment already has `CODEX_FLOW_LIGHT_ISSUE_REVIEW=1`. Single-issue flow remains strict unless the caller explicitly sets `CODEX_FLOW_LIGHT_ISSUE_REVIEW` for that invocation.

After each issue, `.work/codex` is archived authoritatively under `.work/queue/runs/<run_id>/archives/batch-<first>-<last>/issues/<issue>/<commit>/`. The archive contains `codex/` plus an ownership/content manifest with the exact run, batch, Issue, commit, and sorted SHA-256 hashes. Run-owned Issue check provenance remains below `batches/<batch>/check-attempts/issue-<issue>/` and `batches/<batch>/checks/issue-<issue>.manifest.tsv`; a validated copy of its attempts and manifest is included below the authoritative Issue archive's `codex/`. `.work/queue/batches/batch-<first>-<last>/issues/<issue>/codex/` is only a non-authoritative compatibility copy. Batch artifacts also include `issues.txt`, `base_commit`, `head_commit`, `changed-files.txt`, `batch.diff`, `batch.untracked.txt`, `batch.summary.txt`, `checks.log`, batch review/fix prompts and logs, and `history/`. Authoritative Batch check provenance lives below the run-owned Batch state as `check-attempts/batch/` and `checks/batch.manifest.tsv`, not only in the compatibility Batch directory. `issues.txt` is rebuilt atomically in immutable manifest order from hashed run-owned Issue contexts; it is never trusted as incrementally appended state.

Every queue-owned Codex invocation also records an immutable Agent attempt below `.work/queue/runs/<run_id>/batches/<batch_id>/attempts/`. Issue operations use `issue-<issue_number>/<operation>/attempt-NNNN/`; batch operations use `batch/<operation>/attempt-NNNN/`. Each terminal attempt contains `request.state`, the exact `prompt.md`, the combined stdout/stderr `agent.log`, and `result.state`. A process that stops before terminal finalization may leave `attempt-NNNN.running/`; later invocations preserve it and allocate a new attempt ID. Terminal attempt directories are never overwritten. Existing `.work/codex` and batch legacy log paths remain available as compatibility views: logs using the `combined` policy receive `agent.log`, while Issue and batch raw review logs using the `stdout` policy receive stdout only. A standalone `run_issue_flow.sh` invocation does not enable the attempt store by default.

Each Issue and batch review round captures the consumer repository as its `HEAD` commit plus a Git tree for the current worktree, using the normal worktree exclusions. The flow verifies that review snapshot after the Reviewer exits and again before the rejected-review fix cycle begins; a mismatch stops Agent processing. Each active Fixer captures a separate fresh snapshot immediately before its invocation, so the next Fixer is bound to the state produced by earlier active Fixers. Issue mode publishes the current Fixer snapshot at `.work/codex/fix-from-review.snapshot.state`; Batch uses the corresponding compatibility snapshot path in its Batch artifact directory while preserving the original review snapshot as the commit-reconciliation boundary. When the attempt store is enabled, every review and Fixer attempt contains the immutable `snapshot.state` actually supplied to that invocation.

Every accepted queue invocation creates a collision-resistant, filesystem-safe run ID and authoritative state at `.work/queue/runs/<run_id>/` before branch creation or Issue fetching. Existing `.work/queue/batches/batch-<first>-<last>/` paths remain non-authoritative artifact paths, so repeated Issue ranges have distinct authoritative state.

Queue state schema version `3` uses strict `key<TAB>value` data files that are never sourced. Versions `1` and `2` are unsupported and fail explicitly rather than being guessed or migrated:

| File | Required keys |
| --- | --- |
| `manifest.state` | `schema_version`, `run_id`, `created_at`, ordered comma-separated `issues`, `review_every`, `draft_pr`, `auto_merge`, `light_issue_review`, `batch_review_reasoning`, `batch_fix_reasoning`, `batch_check_fix_reasoning`, `batch_branch_prefix`, `base_branch`, `base_ref`, `repository_identity` |
| `run.state` | `schema_version`, `run_id`, `state`, `updated_at` |
| `batches/batch-<first>-<last>/batch.state` | `schema_version`, `run_id`, `batch_id`, `first_issue`, `last_issue`, `branch`, `base_commit`, `accepted_head`, `artifact_path`, `state`, `updated_at` |
| `batches/batch-<first>-<last>/issues/<issue>.state` | `schema_version`, `run_id`, `batch_id`, `issue_number`, `context_path`, `context_sha256`, `base_commit`, `commit_sha`, `artifact_path`, `archive_manifest_sha256`, `state`, `updated_at` |
| `current` | `schema_version`, `run_id`, `owner_token`, `lease_generation`, `updated_at` |
| `lease.lock/owner.<token>.state` | `schema_version`, `run_id`, unpredictable `owner_token`, monotonic `lease_generation`, `owner_pid`, `owner_host`, `process_start`, `acquired_at`, and displaced-lease audit identity |
| `<git-common-dir>/issue-forge/queue/active-process.state` | `schema_version`, `run_id`, `phase`, controlled `child_pid`, `child_pgid`, child `process_start`, queue `owner_pid`, owner process-start identity, `owner_token`, `lease_generation`, and `started_at` |
| `<git-common-dir>/issue-forge/queue/worker.<identity>.registration` / `.authorization` | Exact run, worker PID/PGID/start identity, parent PID/start identity, owner token/generation, and publication timestamp |
| `<git-common-dir>/issue-forge/queue/worker.<identity>.result` | The same exact identities plus terminal phase, exit status/signal, and completion timestamp |
| `<git-common-dir>/issue-forge/queue/completion-cleanup.state` | Completed run ID, owner token/generation, whether a lease audit is required, captured `current_batch`, monotonic cleanup phase, and update timestamp |
| `runs/<run_id>/completion-cleanup.state` | The same identity with terminal `completed` phase, proving that this run's control plane was finalized |

The manifest is immutable. Initial unavailable SHA/artifact values are `none`. Run states are `planned`, `running`, `interrupted`, `failed`, `manual_review_required`, and `completed`; batch states are `planned`, `base_resolved`, `branch_ready`, `issues_running`, `checks_running`, `review_running`, `accepted`, `publishing`, and `completed`; Issue states are `planned`, `leased`, `running`, `committed`, `artifacts_archived`, and `acknowledged`. Transitions are adjacent-only, and every state has strict field invariants. In particular, `running` has an exact base, `committed` adds its commit, archived/acknowledged add the run-owned archive identity, and accepted/publishing/completed batches have an immutable accepted head.

State publication writes and validates a complete sibling temporary file and then performs one atomic no-directory-target rename (`mv -T`); an interrupted pre-rename publication leaves the prior authoritative file intact. Every singleton state read, replacement, and removal rejects symlinks, directories, FIFOs/devices/sockets, and unexpected hard links. A directory target can therefore never capture the sibling temporary file as a nested child. The next state-store operation removes abandoned `.queue-state.tmp.*` siblings deterministically. Parsing rejects unknown, duplicate, missing, or malformed fields. Mutable transitions require the expected current state and stale transitions fail without modification. Timestamps are diagnostic only; durable IDs and transitions determine correctness.

All queue control-plane critical sections use an exclusive kernel `flock` on `<git-common-dir>/issue-forge/queue/control.guard`, outside the agent-writable `.work` artifact tree. The engine creates the control directory and file with modes `0700` and `0600`, rejects symlinks/non-regular files, and verifies that the opened descriptor and pathname still identify the same inode after acquisition. User-facing acquisition waits at most one second. A busy result reports the durable lease and active-process identity where available plus an exact safe recovery action; it never blocks indefinitely. Lease acquisition, takeover, release, authoritative state replacement, `current` publication/removal, and each repository/GitHub-mutating batch phase all use this guard from durable-owner validation through the mutation or phase.

Before fresh lease acquisition, the queue serially publishes the immutable manifest and minimal planned `run.state`. Under the guard, acquisition removes an empty incomplete `lease.lock` left by a crash, creates the claim directory, and publishes exactly one token-matching owner record before releasing the guard. A crash at the empty-directory boundary is therefore deterministically recoverable, and a complete visible lease always names an existing resumable run. Takeover validates the sole owner record, uses a no-nesting directory rename to a unique audit path, increments the generation, and publishes the complete replacement while still holding the guard. Release revalidates the complete run/token/generation/PID/host/process-start identity and removes only that exact record and generation under the guard.

The queue publishes the strict `.work/queue/current` pointer only after immutable manifest, minimal `run.state`, and complete lease-owner publication. Explicit run-ID resume validates and republishes a nonterminal run; a different nonterminal pointer is a conflict. Completion uses the same cleanup-only finalizer as recovery. Queue startup sources `.issue_forge/project.sh` to resolve the consumer boundary, so a shell syntax error remains fatal, but initially does not apply defaults or validate work-only settings. A completed run is identified and finalized from this minimal bootstrap. Only a fresh run or nonterminal resume applies the normal defaults and validates checks, prompts, reasoning, review interval, branch/draft policy, and merge timing. Explicitly configured empty work values remain invalid for those work paths. The finalizer validates the strict immutable manifest, manifest/run identity, `run.state=completed`, canonical repository identity, and cleanup fencing identity. It deliberately does not compare or validate the completed manifest's base branch/ref, reasoning, checks, review interval, draft policy, auto-merge policy, merge timing, or prompt location against current execution configuration, and it does not reconstruct or execute the old work settings.

Before its first cleanup mutation, the finalizer atomically publishes `<git-common-dir>/issue-forge/queue/completion-cleanup.state`. Its monotonic phases are `planned`, `lease_retired`, `batch_pointer_removed`, `current_removed`, and `completed`. The global marker remains discoverable by `--resume current` even after `current` and the lease are absent. Under `control.guard`, every phase validates or reconciles the filesystem postcondition it claims:

| Phase | Enforced postcondition |
| --- | --- |
| `planned` | No removal is assumed. An exact existing finalized audit is validated and adopted; otherwise the validated same-run dead/self-owned lease is retired once. |
| `lease_retired` and later | `lease_required=1` requires the exact valid finalized audit and no lease path. `lease_required=0` permits neither a same-run lease nor that audit. A missing required audit or remaining lease is an invariant failure. |
| `batch_pointer_removed` and later | `current_batch` is absent. An exact captured value that reappeared is removed idempotently; a different value fails without mutation. |
| `current_removed` and later | `current` is absent. An exact same-run token/generation pointer that reappeared is removed idempotently; a different run or fencing identity fails without mutation. |
| `completed` | The audit exists iff required, and no lease, captured `current_batch`, same-run `current`, or same-run active-process record remains. The per-run terminal identity must exactly match the global transaction. |

The finalizer retires the exact same-run lease once to `lease.finalized.<generation>.<token>`, removes only the captured same-run `current_batch`, and removes the fencing-matching `current` last. It performs the complete terminal verification before publishing or accepting the per-run terminal cleanup state and removes the global discovery marker only afterward. A retry reconciles a mutation completed just before a phase update, never creates another lease generation or audit directory, and invokes no Issue, Codex, checks, review, Git publication, PR, or merge phase.

Pointer and lease identities for the completed run must agree on token and generation, and the lease owner filename must match its embedded token. Contradictions fail without mutation. Active-process reconciliation occurs only after same-run cleanup ownership is proven and never removes another run's record. A pending cleanup transaction refuses a different run's pointer or lease. A per-run terminal state is not sufficient by itself for the fast path: the finalizer first checks for a same-run global marker, pointer, lease, active record, missing/forbidden audit, and an otherwise-unowned exact captured batch pointer. Same-run residue acquires the guard and is reconciled or rejected. If only valid different-run B ownership is present, explicit `--resume A` returns successful no-op without acquiring B's busy guard or modifying B's pointer, lease, active process, or state. `--resume current` never reports finalization complete while a strict nonterminal global cleanup marker remains.

The manifest, minimal planned run, and complete planned entity graph form a durable pre-lease candidate before branch creation or Issue fetch. Normal startup does not advertise that candidate as resumable: the authoritative resume command is emitted only after the complete lease and matching `current` pointer are published. A losing fresh contender removes only its unadvertised candidate while holding the guard. If a real failure, `SIGINT`, or `SIGTERM` occurs after minimal publication but before acquisition, the candidate is retained and the exit handler emits its explicit run-ID recovery command; `SIGKILL` may leave the discoverable candidate without having advertised it. Resume derives the exact batch/Issue graph from ordered manifest Issues and `review_every`, rejects missing, duplicate, unexpected, cross-run, cross-batch, or cross-Issue authoritative entities, and validates completed batches as acknowledged-only before repository or GitHub mutation.

Each batch executes in a dedicated process group while the queue parent and that group intentionally share the guard open-file description. The worker first records its exact PID/PGID/start identity together with the exact parent PID/start identity and lease token/generation. It verifies continuously during registration and authorization waits that the same parent process is still alive. The parent rejects a worker PGID equal to its own, validates the exact registration, durably publishes `active-process.state`, and only then publishes the matching authorization. No repository or GitHub mutation begins before authorization validation. A parent death before registration makes the worker exit promptly without mutation; after registration the identified worker retains fencing briefly enough for the bounded busy diagnostic and then self-terminates if authorization cannot be obtained. Stale registration/authorization files cannot authorize a different worker or generation.

After authorization, the parent closes rather than explicitly unlocks the descriptor, so an unaccounted mutating descendant keeps the guard fenced. `SIGINT`/`SIGTERM` captures the durable active phase, terminates and waits for the verified distinct controlled group, reads the worker result, and only then releases ownership. On normal or failed worker exit, the terminal result transfers the final phase and exit/signal status to the parent before `active-process.state` is removed; the abnormal run checkpoint therefore records the actual controlled phase rather than the parent's startup value. If the queue parent receives `SIGKILL` after mutation begins, a live child or descendant keeps the guard busy and the next invocation promptly identifies the orphan and refuses takeover. Once the group is gone, same-run dead-owner resume removes the stale active record, rotates the token, increments the lease generation once, and proceeds without guard deletion. A completed Issue-context fetch left in leased state is validated and adopted rather than fetched again; incomplete context fails rather than duplicating the external call.

Repository identity is canonical and credential-free. SCP-style SSH, URL-style SSH on port 22, HTTPS on port 443, and HTTP on port 80 normalize to the same standard `host/owner/repository` endpoint. Userinfo and credentials are stripped. Non-default ports are preserved as `host:port/owner/repository`, so custom services cannot collapse into the standard endpoint. Legacy schema-v1 `lease.state` and raw `current` artifacts are explicit unsupported/manual-migration errors.

Every externally visible queue phase records `before` and `after` checkpoints. Issues advance only `planned -> leased -> running -> committed -> artifacts_archived -> acknowledged`. The common fresh/resume commit validator requires the expected batch branch, a clean consumer worktree, the exact subject `chore: address issue #<number>`, exactly one parent equal to the saved Issue base, exactly one commit in `<base>..<commit>`, and reachability from the expected branch. It runs before `committed` and again before acknowledgement. Resume always scans immutable Issue order. A commit present after the fresh-commit failpoint is adopted once without rerunning implementation. Archive publication copies to a sibling temporary directory, validates the complete manifest, and uses one atomic rename; an existing destination is adopted only when ownership, content, and saved manifest hash agree. Dirty interrupted Codex/check/review phases become `manual_review_required`, preserve the worktree, record run/phase/dirty paths, and print exact recovery instructions; only a clean interrupted boundary may rerun.

When batch review accepts, the exact branch head is saved as `accepted_head`. Accepted, publishing, and completed paths require both the local branch and publication input to remain at that SHA; resume never replaces it with current `HEAD`.

Batch checks call `CODEX_FLOW_CHECKS_COMMAND` with the batch base commit. If checks fail, Codex runs in write mode with the batch checks fix prompt and the configured batch check fix reasoning. A fix round that produces no repository changes is a hard error. Batch review runs in read mode against the combined batch diff and issue material, verifies that the review did not modify repository files, extracts the standard review output format, and validates it with the same review schema and acceptance semantics as normal review. The batch review prompt is stricter by requiring findings to consider correctness, regressions, cross-issue interaction, scope consistency, tests and coverage, architecture and maintainability, docs and consumer contract consistency, shell safety and failure behavior, and security, token, GitHub CLI, and merge-risk behavior.

Issue and Batch checks use the same check-attempt helper and schema. Queue resume preserves run-owned `.running` attempts and allocates the next ID. Issue archive publication validates the copied checks manifest and every terminal artifact in addition to hashing them in `archive.manifest`. Completed-Batch integrity validation revalidates the authoritative Batch checks manifest and terminal artifacts before the next Git boundary or finalization.

If batch review returns `accept: no`, the engine selects and runs one write-mode Fixer for each active finding before creating the existing single Batch review-fix commit. When files changed, it creates that one commit, enters full Batch Checks once, and then reruns Batch Reviewer. When no files changed, any cumulative `fixed` claim is a hard error; if every claim is `false_positive` or `cannot_fix`, the engine skips the commit and Checks and returns to Reviewer. Failed full Checks continue through the existing Batch checks-fix loop. `CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS` continues to bound rejected review cycles, and `CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS` bounds check-fix rounds.

The queue creates one batch PR per batch. The PR title is:

```text
Batch: address issues #<first_issue>-#<last_issue>
```

The PR body includes one `Closes #<issue_number>` line per issue plus an issue list with titles from local issue context. If an open PR already exists for the batch branch and base branch, the queue reuses it and syncs the title/body.

If the issue list requires more than one batch, `--auto-merge` is required. Without it, the queue fails before modifying the repository because the next batch must start from the base branch after the previous batch has merged. Auto-merge uses:

```bash
gh pr merge <pr_number> --auto --squash --delete-branch --match-head-commit <head_sha>
```

It does not use `--admin`. The queue polls `gh pr view <pr_number> --json state,mergedAt`; a closed unmerged PR or timeout is a hard error. After a batch PR merges, the queue fetches `origin/${CODEX_FLOW_BASE_BRANCH}` before creating the next batch branch.

## 10. Git / Worktree Exclusion Contract

The flow must explicitly exclude internal paths from git operations instead of relying on `.gitignore`.

`CODEX_FLOW_WORKTREE_EXCLUDE_PATHS` includes:

- `:(exclude).work`
- `:(exclude)vendor/issue_forge` when the engine root is inside the consumer repo at that logical path

Current operations that must honor the full exclude array include:

- `git status --porcelain --untracked-files=all -- . ...`
- `git diff --no-ext-diff <base> -- . ...`
- `git ls-files --others --exclude-standard -- . ...`
- `git diff --name-only -z -- . ...`
- `git diff --name-only -z --cached -- . ...`
- `git ls-files --others --exclude-standard -z -- . ...`

The positive pathspec `.` stays before the exclude pathspecs for those discovery commands.

Review diff artifacts are text diffs and must not include `GIT binary patch` payloads. Binary changes are represented in the supplemental review summaries with `git diff --stat`, `git diff --name-status`, `git diff --numstat`, untracked byte sizes, and an explicit binary-file section derived from numstat/name-status data.

Staging then passes only the concrete returned paths to `git add -A --pathspec-from-file=<tmp> --pathspec-file-nul`. The staging pathspec file must not include `:(exclude)...` entries, so ignored managed paths such as `.work` and `vendor/issue_forge` are never passed back to `git add` directly.

`git clean` is handled separately so the engine mount is preserved without hiding consumer-owned `vendor/` content from normal worktree operations. When `vendor/issue_forge` is inside the consumer repo, the clean command protects it with a dedicated exclude argument such as:

- `git clean -fd -e vendor/issue_forge -- . :(exclude).work`

Consumer git hygiene should ignore:

```gitignore
.work
.work/
vendor/issue_forge
vendor/issue_forge/
```

That recommendation is separate from the explicit runtime exclusions above.

## 11. Stable Invariants

The following remain part of the v1 behavior contract:

- `.work/current_issue`
- `.work/current_branch`
- `.work/base_commit`
- `.work/issues/<issue>.md`
- `.work/codex/implementation.prompt.md`
- `.work/codex/fix-from-checks.prompt.md`
- `.work/codex/review.prompt.md`
- `.work/codex/fix-from-review.prompt.md`
- `.work/codex/checks.log`
- `.work/codex/checks.manifest.tsv`
- `.work/codex/check-attempts/issue-checks/attempt-NNNN[.running]/`
- `.work/codex/implementation.log`
- `.work/codex/fix-from-checks.log`
- `.work/codex/review.diff`
- `.work/codex/review.untracked.txt`
- `.work/codex/review.summary.txt`
- `.work/codex/review.raw.txt`
- `.work/codex/review.txt`
- `.work/codex/review-details.tsv`
- `.work/codex/pending-findings.tsv`
- `.work/codex/pending-finding-details.tsv`
- `.work/codex/active-finding.tsv`
- `.work/codex/active-finding-details.tsv`
- `.work/codex/fix-resolution.tsv`
- `.work/codex/review-verification.tsv`
- `.work/codex/fix-from-review.snapshot.state`
- `.work/codex/fix-from-review.log`
- `.work/codex/history/<stem>.round-<NN>.<ext>`
- `.work/queue/lock`
- `.work/queue/current_batch`
- `.work/queue/batches/batch-<first_issue>-<last_issue>/`

Additional invariants:

- issue branch name shape is `issue/<issue_number>-<slug>`
- slug generation remains lowercase, dash-collapsed, trimmed, and capped at 48 characters
- review output format is:

```text
accept: no

blocker:
- none

major:
- Resume adoption does not verify ownership by the current run.

minor:
- none

details:
- finding: Resume adoption does not verify ownership by the current run.
  severity: major
  evidence: The adoption path accepts the expected commit frontier without matching it to run-owned resolution history.
  impact: Resume can adopt work that is not authoritative for the current queue run.
  required_outcome: Adoption succeeds only when the candidate commit is proven to belong to the resumed run.
  constraints: Do not change the queue state schema or add fallback recovery.
  validation: Exercise an ancestry-compatible commit that lacks matching run-owned history.

verification:
- none
```

- `details:` appears after `minor:` and before `verification:` in Issue, light Issue, and Batch reviews. Each current blocker, major, or minor finding has exactly one detail record whose fields are exactly `finding`, `severity`, `evidence`, `impact`, `required_outcome`, `constraints`, and `validation` in that order.
- each concise finding remains a short single sentence suitable for stable matching. Detailed evidence or impact, transient line numbers, Reviewer-local IDs, patch steps, concrete edit commands, and test implementation instructions belong neither in that sentence nor in ledger identity
- `finding` must exactly equal the concise current finding text, and `severity` must equal the section that contains it. Every field is one non-empty line and contains no literal tab. `severity` is `blocker`, `major`, or `minor`; `constraints` is exactly `none` when there is no special constraint.
- `evidence` records only code, diff, state transition, check result, or documentation inconsistency the Reviewer actually observed; `impact` records the resulting incorrect behavior or broken invariant; `required_outcome` records a verifiable postcondition rather than an implementation method; `constraints` records specifications and scope that must be preserved; and `validation` records a test, reproduction scenario, or check that can confirm the outcome
- When there are no current findings, the entire section is `details:` followed by exactly `- none`. A review with current findings cannot use that placeholder, and a no-finding review cannot contain a real detail record. Findings that appear only as `resolved` or `invalid` verification records need no details; an `unresolved` finding repeated in a current severity section does.
- the Reviewer remains read-only. Reviewer details are not a patch design: except where the repository contract admits only one implementation, they do not prescribe function signatures, commands, data structures, or other concrete edits
- validated Issue reviews publish the current Issue ledger at `.work/codex/findings.tsv`; validated batch reviews publish their source-of-truth ledger at `.work/queue/runs/<run_id>/batches/<batch>/findings.tsv` and copy it to `.work/queue/batches/<batch>/findings.tsv` for compatibility; each uses the fixed TSV schema `finding_id`, `severity`, `first_round`, `last_seen_round`, `status`, `resolution`, `text`
- concise blocker, major, and minor text remains the sole source of truth for acceptance, ledger identity and severity, pending finding generation, and unresolved matching; details never participate in those decisions
- finding IDs are ledger-local `FNNNN` sequences; an ID is reused only when normalized concise finding text matches exactly across rounds, where normalization removes the leading bullet marker, removes a trailing CR, and replaces each literal tab with one space. Changing only a detail record never allocates a new ID
- `status` records observation (`present` or `not_observed`), while `resolution` records lifecycle state (`unresolved`, `resolved`, or `invalid`); new and reappearing findings are `unresolved`
- each validated Issue review writes `.work/codex/review-details.tsv` and archives the same round at `.work/codex/history/review-details.round-NN.tsv`; both use this fixed header:

```text
severity	finding	evidence	impact	required_outcome	constraints	validation
```

- a no-current-finding review produces a header-only details TSV. The artifact contains only validated current details and does not change the finding ledger header or identity
- review details describe the same captured review snapshot as the concise findings. The post-Reviewer and pre-cycle snapshot checks remain mandatory; each active Fixer then receives a fresh snapshot captured immediately before that invocation
- before a fix, current `present` and `unresolved` findings are written to `pending-findings.tsv`; the engine joins them to the validated review details by exact concise text and writes `.work/codex/pending-finding-details.tsv` with this fixed header:

```text
finding_id	severity	text	evidence	impact	required_outcome	constraints	validation
```

- pending detail rows use ledger-assigned IDs, preserve `pending-findings.tsv` order, and have exactly one row per pending ID. The join never creates an ID from details and rejects an unknown or duplicate ID, an unknown or duplicate detail, a severity or text mismatch, and a missing detail
- validated Batch details are authoritative at `.work/queue/runs/<run_id>/batches/<batch>/review-details.tsv`, `.work/queue/runs/<run_id>/batches/<batch>/history/review-details.round-NN.tsv`, and `.work/queue/runs/<run_id>/batches/<batch>/pending-finding-details.tsv`. The Batch `active-finding.tsv`, `active-finding-details.tsv`, and cumulative `fix-resolution.tsv` in that run-owned directory are also authoritative. Files below `.work/queue/batches/<batch>/` are compatibility views only; the engine never reads them as run-owned finding state
- when a fix is pending, missing or malformed validated details, pending findings, ledger state, or their required mapping is a hard error. The engine does not synthesize details from concise findings and does not silently fall back to an older or compatibility artifact
- for each rejected-review cycle, the scheduler selects one unprocessed pending ID by `blocker`, `major`, then `minor`, preserving `pending-findings.tsv` order within one severity. It atomically publishes matching header-plus-zero-or-one-row `active-finding.tsv` and `active-finding-details.tsv` artifacts and rejects missing, unknown, duplicate, or inconsistent mappings
- active artifacts use these fixed headers:

```text
finding_id	severity	text
finding_id	severity	text	evidence	impact	required_outcome	constraints	validation
```

- each pending ID receives at most one Fixer attempt in that rejected-review cycle. Fixers run sequentially; multi-agent and parallel Fixer execution are not part of this contract. Immediately before each invocation, the engine hashes the scheduler-owned `pending-findings.tsv`, `pending-finding-details.tsv`, `fix-resolution.tsv`, `active-finding.tsv`, `active-finding-details.tsv`, and generated Fixer prompt. It verifies all six again immediately after the Fixer exits and before parsing its resolution or appending a claim. A missing, replaced, non-regular, or byte-modified artifact is a hard error
- the Fixer treats the active concise row and source-of-truth documentation as normative. The active detail row is auxiliary context: the Fixer verifies evidence in the repository as needed, satisfies `required_outcome` and `constraints`, uses `validation` as guidance, and chooses the smallest safe implementation. Reviewer `validation` text is never executable shell input
- each Fixer should run only the smallest directly relevant validation when practical and must not routinely run configured repository-wide Checks or full `pytest -q`. Focused validation is not a substitute for full Checks
- each Fixer must report exactly one `fixed`, `false_positive`, or `cannot_fix` action for its active ID; the existing resolution output syntax is unchanged:

```text
resolution:
- F0001 | fixed | One-line explanation.
```

- `fix-resolution.tsv` accumulates those one-row reports in processing order for the current rejected-review cycle and is reinitialized before a later rejected cycle. A header-only report contains no claims and requires `verification: - none`. A Fixer action is only a claim and never closes a finding; the next Reviewer must return one `resolved`, `invalid`, or `unresolved` verification per reported ID, and an unresolved verification must repeat the exact ledger text in the current finding sections
- after every active ID has received its one attempt, standalone Issue and changed Batch cycles enter configured full Checks once and only then rerun Reviewer. If full Checks fail, the existing checks-fix loop may perform further check attempts. An unchanged Batch cycle with only `false_positive` or `cannot_fix` claims skips commit and Checks. The applicable full Checks result, not a Fixer's focused validation, is the acceptance evidence
- findings absent from the current round remain as `not_observed`; resolved or invalid findings that reappear with the same normalized text retain their ID and return to `unresolved`
- each current ledger is copied after publication to `history/findings.round-NN.tsv` using the existing round-history naming rule; batch source history is run-owned and is then copied to the compatibility history path
- Issue lifecycle artifacts are `.work/codex/review-details.tsv`, `.work/codex/history/review-details.round-NN.tsv`, `.work/codex/pending-findings.tsv`, `.work/codex/pending-finding-details.tsv`, `.work/codex/active-finding.tsv`, `.work/codex/active-finding-details.tsv`, `.work/codex/fix-from-review.snapshot.state`, `.work/codex/fix-resolution.tsv`, `.work/codex/history/fix-resolution.round-NN.tsv`, and `.work/codex/review-verification.tsv`
- Batch details, pending artifacts, active artifacts, cumulative resolution, resolution history, and verification are run-owned below `.work/queue/runs/<run_id>/batches/<batch>/`. Active artifacts have no compatibility copy. Pending artifacts, cumulative resolution, resolution history, and verification are copied below `.work/queue/batches/<batch>/` where documented, while the current Batch Fixer snapshot exists only at `.work/queue/batches/<batch>/fix-from-batch-review.snapshot.state`; none of these compatibility paths is authoritative input
- resuming a queue run continues that run's ledger, while a different run over the same batch range starts a separate ledger and never reads the compatibility copy as finding state
- each run-owned Batch directory has a fixed version-1 `review-lifecycle.state` TSV containing `review_round`, `fix_round`, `next_action` (`review`, `fix`, or `complete`), and `updated_at`; resume continues that saved action and logical round, and `complete` prevents Reviewer or Fixer reruns before the outer `batch_review after` checkpoint
- `review-lifecycle.state` is the Batch review/fix loop's commit-point control state after successful artifacts and checks; it is separate from Agent attempts and the finding ledger, has no compatibility copy, and does not change queue state schema version 3
- queued Batch Fixer invocation numbers come only from run-owned attempt and cumulative-resolution evidence, never compatibility logs. If an existing run-owned Fixer attempt is not matched by cumulative resolution state, resume fails closed instead of attempting that active ID again
- if a Batch review fix commit is durable before that commit point, resume adopts it only when the worktree is clean, the current HEAD is a linear descendant of the saved review snapshot HEAD containing the expected review/check-fix commit subjects, the current run-owned cumulative resolution exactly matches that round's valid resolution history and covers every pending ID, and the run-owned pending detail mapping still validates exactly; it reruns checks without rerunning the Fixer before advancing the lifecycle
- malformed review output is a hard error
- `accept: yes` must still fail if `blocker:` or `major:` contain real findings
- `accept: no` must have at least one current finding in `blocker:`, `major:`, or `minor:`; verification records do not count as current findings or rejection reasons
- `accept: no` remains allowed; acceptance still uses the current review finding sections rather than scanning the full ledger
- raw Codex review logs remain byte-for-byte debugging artifacts; before extracting and validating `.work/codex/review.txt` or batch review output, only the exact known `[codex]` launcher progress lines and Codex runtime/session log lines matching `^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* (ERROR|WARN|INFO|DEBUG|TRACE) codex_core::session:` are ignored
- pure review output must still start with `accept: yes` or `accept: no`; for recognizable `codex exec` transcript output, the engine requires the final `accept: yes` or `accept: no` candidate to be a valid structured review block and drops transcript headers, prompt text, tool calls, token summaries, earlier duplicated review blocks, and runtime session logs. It never falls back to an earlier valid block when the final candidate has invalid details; after that final block, only blank lines and the existing exact token-usage tail are allowed, while arbitrary trailing prose is malformed
- arbitrary non-review text before or after a pure structured review remains malformed output

## 12. Self-Hosting and Verification

This repository itself must still support:

- `./tools/codex/doctor.sh`
- `./tools/codex/smoke_harness.sh`
- `python -m pytest -q`

Regression coverage for the direct vendor contract lives in:

- `tools/codex/smoke_harness.sh`
- `tests/test_codex_smoke_harness.py`

The smoke harness must prove that a fixture consumer with no `tools/codex` and no `tools/issue` can run the full flow through `./vendor/issue_forge/tools/...`.
It also covers `./vendor/issue_forge/tools/consumer/init.sh`, including `.gitignore` initialization, minimal `.issue_forge/project.sh` creation, no-flag warning-only behavior for missing checks/`README.md`, no warning for missing `docs/README.md`, no creation of `tools/run_issue.sh` or `.issue_forge/shell.sh` without opt-in, idempotent reruns, opt-in `--scaffold-checks` creation of the starter checks hook, opt-in `--scaffold-run` creation and preservation of the run wrapper and shell snippet, source-snippet `run 5` forwarding from a subdirectory, and preservation of existing consumer-owned checks files.
It covers PR body generation for create and existing-PR update paths, including changed files, checks, review, and missing-artifact sections.
It covers `CODEX_RUN_REASONING_EFFORT`, `CODEX_FLOW_SKIP_PUBLISH=1`, one-batch queue processing, batch review/fix effort selection, batch PR body generation, fail-fast multi-batch behavior without `--auto-merge`, and the absence of generated GitHub workflow files.
