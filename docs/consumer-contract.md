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
| `vendor/issue_forge/tools/issue/start_from_issue.sh` | `<issue_number>` | Bootstrap issue context, create branch, write `.work/base_commit`, `.work/current_issue`, `.work/current_branch`, `.work/issues/<issue>.md` |
| `vendor/issue_forge/tools/codex/doctor.sh` | none | Preflight required commands, GitHub auth, consumer config, base ref, prompt path, and checks command |
| `vendor/issue_forge/tools/codex/run_issue_flow.sh` | `[issue_number]` | Run implementation, checks/fix loop, review/fix loop, commit, push, and PR create/update |
| `vendor/issue_forge/tools/codex/run_issue_queue.sh` | `[options] <issue_number> [issue_number...]` | Local-only sequential issue queue: process issues linearly on batch branches, run strict batch review, create one batch PR per batch, and optionally request auto-merge |
| `vendor/issue_forge/tools/codex/restart_issue_flow.sh` | `[--hard] [issue_number]` | Delete `.work/codex`, optionally discard dirty changes outside `.work`, and rerun the flow |
| `vendor/issue_forge/tools/codex/continue_after_review.sh` | `[issue_number]` | Commit current changes as review follow-up, delete `.work/codex`, and rerun the flow |
| `vendor/issue_forge/tools/codex/make_pr_only.sh` | `[issue_number]` | Create or sync the PR title/body for the current issue branch without pushing new commits |
| `vendor/issue_forge/tools/codex/run_codex.sh` | `<write\|read> <prompt_file>` | Invoke `codex exec` with the mode-specific sandbox and reasoning profile |

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
| `CODEX_FLOW_PROFILE_WRITE_REASONING` | `xhigh` |
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
- consumers with custom `CODEX_FLOW_PROMPTS_DIR` need the batch prompt templates when they use `run_issue_queue.sh`; missing batch templates are a hard queue error
- when `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW` is non-zero, queue mode also requires `review-light.prompt.md.tmpl`; missing light review templates are a hard queue error

Checks behavior:

- default checks hook is `./.issue_forge/checks/run_changed.sh`
- invocation is `./.issue_forge/checks/run_changed.sh <fixed_base_commit>` unless explicitly overridden
- stdout/stderr are captured into `.work/codex/checks.log`
- exit `0` means pass; non-zero enters the fix-from-checks loop
- the checks hook must be non-interactive and validation-only
- `tools/consumer/init.sh --scaffold-checks` can create a minimal consumer-owned starter at that default path; the starter runs `shellcheck -x` for changed shell files and `pytest -q` for Python-related changes only

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

Usage:

```bash
vendor/issue_forge/tools/codex/run_issue_queue.sh [options] <issue_number> [issue_number...]
```

Options:

- `--review-every <positive_integer>` sets the number of issues per batch PR; the default is `CODEX_FLOW_QUEUE_REVIEW_EVERY=3`
- `--batch-review-effort <value>` overrides `CODEX_FLOW_BATCH_REVIEW_REASONING` for that queue run
- `--batch-fix-effort <value>` overrides both `CODEX_FLOW_BATCH_FIX_REASONING` and `CODEX_FLOW_BATCH_CHECK_FIX_REASONING` for that queue run
- `--auto-merge` requests auto-merge for each batch PR and waits for it to merge before starting the next batch
- `--draft` creates draft batch PRs; it cannot be combined with `--auto-merge`

The queue processes issues strictly in the input order. It creates one deterministic batch branch per batch, named `${CODEX_FLOW_BATCH_BRANCH_PREFIX}<first_issue>-<last_issue>`; with defaults this is `batch/<first_issue>-<last_issue>`. The branch is created from `CODEX_FLOW_BASE_REF` after fetching `origin/${CODEX_FLOW_BASE_BRANCH}`. If the planned branch already exists locally or remotely, the queue fails before creating it.

The queue never calls `tools/issue/start_from_issue.sh`. For each issue, it fetches issue context with the existing issue bootstrap helper, writes `.work/current_issue`, `.work/current_branch`, and `.work/base_commit`, records the current batch branch as `.work/current_branch`, records the current `HEAD` before that issue as `.work/base_commit`, and then runs:

```bash
CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_LIGHT_ISSUE_REVIEW=<0-or-1> vendor/issue_forge/tools/codex/run_issue_flow.sh <issue_number>
```

`CODEX_FLOW_SKIP_PUBLISH=1` keeps the normal issue implementation, checks, review, fix loops, and commit behavior, but skips the issue branch push and issue PR creation. Queue mode derives `CODEX_FLOW_LIGHT_ISSUE_REVIEW` from `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW` for each per-issue flow: non-zero sets `1`, so `.work/codex/review.prompt.md` is rendered from `review-light.prompt.md.tmpl`; `0` sets `0`, so full strict per-issue review is used even if the parent environment already has `CODEX_FLOW_LIGHT_ISSUE_REVIEW=1`. Single-issue flow remains strict unless the caller explicitly sets `CODEX_FLOW_LIGHT_ISSUE_REVIEW` for that invocation.

After each issue, `.work/codex` is archived under `.work/queue/batches/batch-<first_issue>-<last_issue>/issues/<issue_number>/codex/`. Batch artifacts also include `issues.txt`, `base_commit`, `head_commit`, `changed-files.txt`, `batch.diff`, `batch.untracked.txt`, `batch.summary.txt`, `checks.log`, batch review/fix prompts and logs, and `history/`.

Batch checks call `CODEX_FLOW_CHECKS_COMMAND` with the batch base commit. If checks fail, Codex runs in write mode with the batch checks fix prompt and the configured batch check fix reasoning. A fix round that produces no repository changes is a hard error. Batch review runs in read mode against the combined batch diff and issue material, verifies that the review did not modify repository files, extracts the standard review output format, and validates it with the same review schema and acceptance semantics as normal review. The batch review prompt is stricter by requiring findings to consider correctness, regressions, cross-issue interaction, scope consistency, tests and coverage, architecture and maintainability, docs and consumer contract consistency, shell safety and failure behavior, and security, token, GitHub CLI, and merge-risk behavior.

If batch review returns `accept: no`, Codex runs in write mode with the batch review fix prompt, commits any resulting changes, reruns batch checks, and reruns batch review. `CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS` and `CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS` bound the loops.

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
- `.work/codex/implementation.log`
- `.work/codex/fix-from-checks.log`
- `.work/codex/review.diff`
- `.work/codex/review.untracked.txt`
- `.work/codex/review.summary.txt`
- `.work/codex/review.raw.txt`
- `.work/codex/review.txt`
- `.work/codex/fix-from-review.log`
- `.work/codex/history/<stem>.round-<NN>.<ext>`
- `.work/queue/lock`
- `.work/queue/current_batch`
- `.work/queue/batches/batch-<first_issue>-<last_issue>/`

Additional invariants:

- issue branch name shape is `issue/<issue_number>-<slug>`
- slug generation remains lowercase, dash-collapsed, trimmed, and capped at 48 characters
- review output format remains:

```text
accept: yes/no

blocker:
- ...

major:
- ...

minor:
- ...
```

- malformed review output is a hard error
- `accept: yes` must still fail if `blocker:` or `major:` contain real findings
- `accept: no` remains allowed
- raw Codex review logs remain byte-for-byte debugging artifacts; before extracting and validating `.work/codex/review.txt` or batch review output, only known Codex runtime/session log lines matching `^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* (ERROR|WARN|INFO|DEBUG|TRACE) codex_core::session:` are ignored
- pure review output must still start with `accept: yes` or `accept: no`; for recognizable `codex exec` transcript output, the engine extracts the last valid structured review block and drops transcript headers, prompt text, tool calls, token summaries, duplicated review blocks, and runtime session logs
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
