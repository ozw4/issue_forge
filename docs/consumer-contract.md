# Codex Engine / Consumer Contract

Status:

- current v1 contract for using `issue_forge` as a shared shell engine
- focused on direct vendor usage from a consumer repo
- preserves existing `.work` layout, history naming, branch naming, review format, and GitHub issue / PR behavior

## 1. Contract Summary

`issue_forge` is a shared shell engine. External consumers use it directly from `vendor/issue_forge`; they do not need local wrapper scripts under `./tools/codex` or `./tools/issue`.

This repository still self-hosts the engine and therefore keeps checked-in entrypoints under `tools/codex/` and `tools/issue/` for engine development, smoke coverage, and local verification.

## 2. Consumer Entry Points

External consumer-facing entrypoints are:

| Path | Arguments | Role |
| --- | --- | --- |
| `vendor/issue_forge/tools/consumer/init.sh` | `[consumer-root]` | First-time consumer setup: update `.gitignore`, create `.issue_forge/project.sh` if missing, and warn about missing consumer-owned checks/docs files |
| `vendor/issue_forge/tools/issue/start_from_issue.sh` | `<issue_number>` | Bootstrap issue context, create branch, write `.work/base_commit`, `.work/current_issue`, `.work/current_branch`, `.work/issues/<issue>.md` |
| `vendor/issue_forge/tools/codex/doctor.sh` | none | Preflight required commands, GitHub auth, consumer config, base ref, prompt path, and checks command |
| `vendor/issue_forge/tools/codex/run_issue_flow.sh` | `[issue_number]` | Run implementation, checks/fix loop, review/fix loop, commit, push, and PR creation |
| `vendor/issue_forge/tools/codex/restart_issue_flow.sh` | `[--hard] [issue_number]` | Delete `.work/codex`, optionally discard dirty changes outside `.work`, and rerun the flow |
| `vendor/issue_forge/tools/codex/continue_after_review.sh` | `[issue_number]` | Commit current changes as review follow-up, delete `.work/codex`, and rerun the flow |
| `vendor/issue_forge/tools/codex/make_pr_only.sh` | `[issue_number]` | Create or report the PR for the current issue branch without pushing new commits |
| `vendor/issue_forge/tools/codex/run_codex.sh` | `<write\|read> <prompt_file>` | Invoke `codex exec` with the mode-specific sandbox and reasoning profile |

For this repository only, self-hosting entrypoints under `tools/codex/` and `tools/issue/` remain supported.

## 3. Minimal Consumer-Owned Files

External consumers must provide these files:

| Path | Required | Notes |
| --- | --- | --- |
| `.issue_forge/project.sh` | yes | May be empty; engine applies defaults before validation; `tools/consumer/init.sh` creates a minimal default file when missing |
| `.issue_forge/checks/run_changed.sh` | yes | Default checks hook path; must be executable; `tools/consumer/init.sh` only warns when it is missing |
| `AGENTS.md` | yes | Consumer-owned repo instructions |
| `docs/README.md` | yes | Consumer-owned docs entrypoint; `tools/consumer/init.sh` only warns when it is missing |
| `vendor/issue_forge` | yes | Bind-mounted or symlinked engine root; not committed by the consumer repo |
| `README.md` | recommended | Consumer repo overview; not required by engine logic but expected by smoke fixture and normal repo hygiene |

First-time consumer initialization may be done by running:

```bash
./vendor/issue_forge/tools/consumer/init.sh
```

That command:

- updates consumer `.gitignore` with `.work`, `.work/`, `vendor/issue_forge`, and `vendor/issue_forge/`
- creates `.issue_forge/project.sh` when it is missing
- warns about missing `.issue_forge/checks/run_changed.sh`
- warns about missing `docs/README.md`
- does not create checks or docs files
- does not stage or commit changes

Optional consumer overrides:

- custom prompt templates via `CODEX_FLOW_PROMPTS_DIR`
- non-default checks command via `CODEX_FLOW_CHECKS_COMMAND`
- non-default base branch / base ref / branch prefix / draft policy / profile settings via `.issue_forge/project.sh`

External consumers do not need:

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

Validation still runs after defaults. Missing or malformed values after defaulting remain hard errors.

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

Checks behavior:

- default checks hook is `./.issue_forge/checks/run_changed.sh`
- invocation is `./.issue_forge/checks/run_changed.sh <fixed_base_commit>` unless explicitly overridden
- stdout/stderr are captured into `.work/codex/checks.log`
- exit `0` means pass; non-zero enters the fix-from-checks loop
- the checks hook must be non-interactive and validation-only

## 8. Git / Worktree Exclusion Contract

The flow must explicitly exclude internal paths from git operations instead of relying on `.gitignore`.

`CODEX_FLOW_WORKTREE_EXCLUDE_PATHS` includes:

- `:(exclude).work`
- `:(exclude)vendor/issue_forge` when the engine root is inside the consumer repo at that logical path

Current operations that must honor the full exclude array include:

- `git status --porcelain --untracked-files=all -- . ...`
- `git diff --no-ext-diff --binary <base> -- . ...`
- `git ls-files --others --exclude-standard -- . ...`
- `git add -A -- . ...`

The positive pathspec `.` stays before the exclude pathspecs.

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

## 9. Stable Invariants

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
- `.work/codex/review.raw.txt`
- `.work/codex/review.txt`
- `.work/codex/fix-from-review.log`
- `.work/codex/history/<stem>.round-<NN>.<ext>`

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

## 10. Self-Hosting and Verification

This repository itself must still support:

- `./tools/codex/doctor.sh`
- `./tools/codex/smoke_harness.sh`
- `python -m pytest -q`

Regression coverage for the direct vendor contract lives in:

- `tools/codex/smoke_harness.sh`
- `tests/test_codex_smoke_harness.py`

The smoke harness must prove that a fixture consumer with no `tools/codex` and no `tools/issue` can run the full flow through `./vendor/issue_forge/tools/...`.
It also covers `./vendor/issue_forge/tools/consumer/init.sh`, including `.gitignore` initialization, minimal `.issue_forge/project.sh` creation, warning-only behavior for missing checks/docs, and idempotent reruns.
