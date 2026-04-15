# Codex Engine / Consumer Contract

Status:

- v1 contract draft for extracting the current shell-based Codex automation flow into a shared engine repository
- grounded in the current `tools/codex/`, `tools/issue/`, `tools/checks/`, and smoke-harness implementation in this repository
- focused on extraction and behavior preservation, not on changing the workflow

## 1. Purpose and Scope

This split is being done because the current automation flow already contains a reusable shell engine plus repository-specific inputs, but both are still co-located in this repository. The current code is partially refactored already: orchestration entrypoints are thin, most reusable behavior lives in `tools/codex/lib/*.sh`, and the remaining repo-specific pieces are prompts, docs, checks, and repository policy.

In this document:

- shared engine means the reusable shell implementation that drives issue bootstrap, Codex execution, state management, checks/review loops, history capture, and GitHub publish behavior
- consumer repo means a repository that keeps its own prompts, docs, checks hook, project policy, and stable user-facing wrapper paths while delegating reusable flow logic to the shared engine
- this repository is the first consumer and therefore defines v1 compatibility targets

v1 in scope:

- extract the existing reusable shell flow into a separate shared engine repository
- keep this repository working through the current user-facing script paths
- preserve the current `.work` layout, prompt file names, history naming, branch naming, base ref/base branch expectations, review output format, and PR creation behavior
- split ownership of engine code vs consumer assets without changing runtime behavior

v1 intentionally out of scope:

- workflow redesign
- path renames
- entrypoint renames
- non-shell reimplementation
- multi-provider issue or PR abstractions
- prompt schema redesign beyond what is required to preserve current parsing
- plugin or skill packaging
- requiring a new framework or package manager

## 2. Current-State Inventory

Current refactor state:

- the flow is already decomposed into thin entrypoints plus reusable shell libraries under `tools/codex/lib/`
- prompt text is already separated into template files under `tools/codex/prompts/`
- regression coverage already exists via `tools/codex/smoke_harness.sh` and `tests/test_codex_smoke_harness.py`
- configuration is split between `tools/codex/lib/engine_defaults.sh` (engine defaults) and `.issue_forge/project.sh` loaded via `tools/codex/lib/consumer_config.sh` (consumer policy)

Current reusable flow components in this repository:

| Area | Current files | Current role |
| --- | --- | --- |
| Orchestration entrypoints | `tools/codex/run_issue_flow.sh`, `tools/codex/restart_issue_flow.sh`, `tools/codex/continue_after_review.sh`, `tools/codex/make_pr_only.sh`, `tools/issue/start_from_issue.sh` | User-facing scripts that sequence bootstrap, Codex sessions, checks, review, commit, push, and PR creation |
| Codex execution wrapper | `tools/codex/run_codex.sh`, `tools/codex/lib/codex_profiles.sh`, `tools/codex/lib/engine_defaults.sh`, `tools/codex/lib/consumer_config.sh`, `.issue_forge/project.sh` | Resolves `write` vs `read` execution settings, invokes `codex exec`, and retries transient provider-capacity failures |
| Issue bootstrap logic | `tools/codex/lib/issue_bootstrap.sh` | Fetches issue title/body via `gh`, slugifies branch names, creates issue branches, and writes `.work` issue state |
| Publish / PR logic | `tools/codex/lib/publish_helpers.sh` | Stages and commits changes, pushes the branch, discovers existing PRs, and creates draft PRs via `gh pr create` |
| Flow state helpers | `tools/codex/lib/flow_state.sh`, `tools/codex/lib/history_helpers.sh` | Enters repo root, validates current issue/branch state, computes `.work` paths, excludes `.work` from worktree status, and archives round artifacts |
| Checks / review / history helpers | `tools/codex/lib/checks_review_helpers.sh` | Runs repo checks, generates review material, validates structured review output, drives fix loops, and enforces read-only review sessions |
| Prompt template rendering | `tools/codex/lib/prompt_templates.sh` | Resolves template paths, replaces placeholders, and renders prompts into `.work/codex/*.prompt.md` |
| Prompt templates | `tools/codex/prompts/implementation.prompt.md.tmpl`, `fix-from-checks.prompt.md.tmpl`, `review.prompt.md.tmpl`, `fix-from-review.prompt.md.tmpl` | Consumer-specific prompt text that tells Codex which docs and `.work` artifacts to read |
| Repo-specific checks | `tools/checks/run_changed.sh` | Consumer hook that decides which lint/type/test/build commands run for the changed files and base ref |
| Docs / AGENTS inputs used by prompts | `AGENTS.md`, `docs/README.md`, indirectly `docs/codex_working_rules.md` and other docs selected by `docs/README.md` | Consumer-owned repository instructions and source-of-truth reading order consumed by Codex sessions |
| Regression harness | `tools/codex/smoke_harness.sh`, `tests/test_codex_smoke_harness.py`, `tools/codex/README.md` | Network-independent fixture-based regression guard for the current shell contract |

## 3. Responsibility Split

v1 boundary:

| Item | v1 classification | Notes |
| --- | --- | --- |
| `run_issue_flow` orchestration | shared engine implementation, consumer wrapper path | The orchestration logic is reusable; this repository should keep `tools/codex/run_issue_flow.sh` as the stable consumer entrypoint path |
| `run_codex` execution wrapper | shared engine implementation, consumer wrapper path | Mode resolution, retries, and `codex exec` invocation are engine behavior; the consumer path must stay stable |
| State file handling | shared engine | `.work` state read/write rules are engine logic |
| Issue provider integration | shared engine, GitHub-only in v1 | Current implementation is `gh issue view`; v1 does not introduce provider abstraction |
| PR publish integration | shared engine, GitHub-only in v1 | Current implementation is `gh pr list` and `gh pr create`; v1 keeps that behavior |
| Prompt template files | consumer | Templates encode repo-specific instructions and docs references |
| `AGENTS.md` | consumer | Repository-specific normative instructions for Codex sessions |
| `docs/README.md` and `docs/codex_working_rules.md` | consumer | Repository-specific docs reading order and engineering rules; engine must not own or rewrite them |
| Repo-specific checks command | consumer | `tools/checks/run_changed.sh` is consumer policy and toolchain integration |
| `.work` path conventions | shared contract | Engine owns reads/writes; consumer must reserve the path and not repurpose it |
| `.codex/config.toml` | consumer-owned optional project config | No such file exists in the current repo; v1 engine must not require it |
| Smoke tests / contract tests | split | Engine owns generic behavior tests; consumer owns integration tests for prompts, checks, docs presence, and stable wrapper paths |

Additional boundary rules:

- the shared engine repository owns reusable shell libraries, engine-side defaults, and engine-level smoke coverage
- the consumer repository owns prompts, project policy, repository docs, repository checks, any optional project-scoped Codex config, and the stable entrypoint paths used by contributors in this repo
- v1 extraction should keep the current shell architecture; it should not introduce a service, daemon, plugin runtime, or language rewrite

## 4. Contract Surface

### 4.1 Stable Consumer-Facing Entrypoints

These paths are part of the v1 preservation contract for this repository. Future extraction work should keep them callable from the consumer repo root.

| Path | Arguments | Current role |
| --- | --- | --- |
| `tools/issue/start_from_issue.sh` | `<issue_number>` | Bootstrap issue context, create branch, write `.work/current_issue`, `.work/current_branch`, `.work/issues/<issue>.md` |
| `tools/codex/run_issue_flow.sh` | `[issue_number]` | Run implementation, checks/fix loop, review/fix loop, commit, push, and PR publish |
| `tools/codex/restart_issue_flow.sh` | `[--hard] [issue_number]` | Delete `.work/codex`, optionally discard dirty changes outside `.work`, and rerun the issue flow |
| `tools/codex/continue_after_review.sh` | `[issue_number]` | Commit current changes as review follow-up, delete `.work/codex`, and rerun the issue flow |
| `tools/codex/make_pr_only.sh` | `[issue_number]` | Create or report the PR for the current issue branch without pushing new commits |
| `tools/codex/run_codex.sh` | `<write|read> <prompt_file>` | Invoke `codex exec` with the mode-specific sandbox and reasoning profile |

### 4.2 Consumer-Supplied Artifacts

| Artifact | Current state | v1 requirement | Current enforcement |
| --- | --- | --- | --- |
| `AGENTS.md` | Prompt input | Required consumer-owned file | Implicit today through prompt text; extracted engine should preflight it |
| `docs/README.md` | Prompt input | Required consumer-owned file | Implicit today through prompt text; extracted engine should preflight it |
| `tools/codex/prompts/implementation.prompt.md.tmpl` | Template input | Required consumer-owned file | Explicit hard error if missing |
| `tools/codex/prompts/fix-from-checks.prompt.md.tmpl` | Template input | Required consumer-owned file | Explicit hard error if missing |
| `tools/codex/prompts/review.prompt.md.tmpl` | Template input | Required consumer-owned file | Explicit hard error if missing |
| `tools/codex/prompts/fix-from-review.prompt.md.tmpl` | Template input | Required consumer-owned file | Explicit hard error if missing |
| `tools/checks/run_changed.sh` | Checks hook | Required executable consumer-owned hook | Not preflight-checked today; failure occurs on execution |
| Git worktree rooted at repo top level | Execution environment | Required | Explicit through `git rev-parse --show-toplevel` and subsequent relative paths |
| Writable `.work/` under repo root | Engine state root | Required | Not preflight-checked separately; required by normal execution |

### 4.3 Required Commands and Runtime Assumptions

The current flow is Bash-based and assumes standard Unix userland plus these required commands.

| Command / capability | Required by |
| --- | --- |
| `bash` | All entrypoints and libraries |
| `git` | All flows except prompt rendering helpers |
| `gh` | Issue bootstrap and PR publish flows |
| `codex` | `tools/codex/run_codex.sh` and anything that calls it |
| `awk` | Prompt placeholder validation and review-output extraction/validation |
| `sed` | Slugify, placeholder rendering, and review accept parsing |
| `tr`, `cut` | Branch slug generation |
| `mktemp` | Prompt rendering, `run_codex` retry temp file, PR body temp file |
| Standard shell utilities such as `cp`, `mv`, `grep`, `sleep`, `cat` | Internal helper implementation |

Git / GitHub / Codex assumptions:

- execution happens inside a git repository with a checked-out local branch
- remote `origin` exists
- the configured base ref exists locally as a resolvable ref
- `gh` is authenticated and can run `issue view`, `pr list`, and `pr create`
- `codex exec` accepts stdin prompts plus `--sandbox` and `--config model_reasoning_effort=...`
- the consumer repo keeps the stable wrapper paths and relative prompt/checks locations described in this document

### 4.4 Required Configuration Values

Current config is loaded from `tools/codex/lib/engine_defaults.sh` plus consumer config in `.issue_forge/project.sh` through `tools/codex/lib/consumer_config.sh`.

| Setting | Current value in this repo | v1 contract |
| --- | --- | --- |
| Base branch | `main` | Required consumer value for this repository |
| Base ref | `origin/main` | Required consumer value for this repository |
| Branch prefix | `issue/` | Required consumer value |
| Issue slug max length | `48` | Required consumer value |
| Work root | `.work` | Fixed v1 contract path |
| Codex work dir | `.work/codex` | Fixed v1 contract path |
| History dir | `.work/codex/history` | Fixed v1 contract path |
| Max check-fix rounds | `20` | Engine default |
| Max review-fix rounds | `19` | Engine default |
| Draft PR default | `1` | Consumer policy for this repository |
| Write mode name | `write` | Engine mode contract |
| Read mode name | `read` | Engine mode contract |
| Write sandbox | `danger-full-access` | Consumer/project policy for this repository |
| Write reasoning | `xhigh` | Consumer/project policy for this repository |
| Read sandbox | `danger-full-access` | Consumer/project policy for this repository |
| Read reasoning | `medium` | Consumer/project policy for this repository |

Optional runtime environment variables already supported:

| Variable | Current default | Contract |
| --- | --- | --- |
| `CODEX_TRANSIENT_MAX_RETRIES` | `5` | Optional; when set it must be a non-negative integer |
| `CODEX_TRANSIENT_INITIAL_DELAY_SEC` | `5` | Optional; when set it must be a non-negative integer |

Not part of the engine/consumer runtime contract:

- `SMOKE_*` variables in `tools/codex/smoke_harness.sh`; they are test-fixture controls only
- `CHECKS_VERBOSE`; it belongs to the consumer checks hook only

### 4.5 Checks Hook Contract

The shared engine expects the consumer repo to provide an executable checks hook with this behavior:

- path: `./tools/checks/run_changed.sh`
- working directory: repo root
- invocation: `./tools/checks/run_changed.sh <base_ref>`
- current argument value in this repo: `origin/main`
- stdout and stderr are captured verbatim into `.work/codex/checks.log`
- exit code `0` means checks passed
- non-zero exit means checks failed and the engine should enter the fix-from-checks loop
- the hook must be non-interactive
- the hook should act as validation, not as a source of tracked file edits

### 4.6 Hard-Error Conditions

These conditions should be treated as hard errors by the extracted engine because the current flow already fails or cannot operate correctly in these cases.

| Condition | Current status |
| --- | --- |
| Missing required CLI command (`git`, `gh`, `codex`, `awk`, `sed`, `tr`, `cut`, `mktemp`) | Explicit hard error where currently checked; otherwise a shell execution failure |
| Missing or non-numeric issue number when numeric is required | Explicit hard error |
| Missing `.work/current_issue` when issue number is omitted | Explicit hard error |
| Missing `.work/current_branch` when branch state is required | Explicit hard error |
| Current checked-out branch does not match `.work/current_branch` | Explicit hard error |
| Missing issue context file `.work/issues/<issue>.md` | Explicit hard error |
| Missing configured base ref | Explicit hard error |
| Dirty worktree outside `.work` before `start_from_issue.sh` or `run_issue_flow.sh` | Explicit hard error |
| Dirty worktree outside `.work` during `restart_issue_flow.sh` without `--hard` | Explicit hard error |
| Existing local or remote issue branch | Explicit hard error |
| Missing prompt template | Explicit hard error |
| Unresolved prompt template placeholders after rendering | Explicit hard error |
| Missing `.work/codex/review.txt` before `continue_after_review.sh` | Explicit hard error |
| Review session changes repository files | Explicit hard error |
| Review material is empty | Explicit hard error |
| Structured review output is missing or malformed | Explicit hard error |
| Initial implementation session produces no file changes outside `.work` | Explicit hard error |
| No repository changes exist when a commit is required | Explicit hard error |
| Check-fix or review-fix round limit is exhausted | Explicit hard error |
| Invalid retry env var values for `run_codex.sh` | Explicit hard error |
| Missing consumer-owned prompt docs inputs such as `AGENTS.md` or `docs/README.md` | Implicit today; extracted engine should make this explicit |

## 5. Path and File Invariants

These invariants must not change during extraction unless the contract and smoke coverage are updated deliberately.

| Path or pattern | Producer | Consumer / downstream use | v1 status |
| --- | --- | --- | --- |
| `.work/current_issue` | issue bootstrap | Default issue source for later entrypoints | Contract |
| `.work/current_branch` | issue bootstrap | Branch identity check for later entrypoints | Contract |
| `.work/issues/<issue>.md` | issue bootstrap | Prompt input for all Codex sessions | Contract |
| `.work/codex/implementation.prompt.md` | prompt renderer | Input to `run_codex.sh write` | Contract |
| `.work/codex/fix-from-checks.prompt.md` | prompt renderer | Input to `run_codex.sh write` for check failures | Contract |
| `.work/codex/review.prompt.md` | prompt renderer | Input to `run_codex.sh read` | Contract |
| `.work/codex/fix-from-review.prompt.md` | prompt renderer | Input to `run_codex.sh write` for accepted review findings | Contract |
| `.work/codex/checks.log` | checks hook | Prompt input for fix-from-checks | Contract |
| `.work/codex/implementation.log` | implementation run | Archived history and failure diagnosis | Contract |
| `.work/codex/fix-from-checks.log` | fix-from-checks run | Archived history and failure diagnosis | Contract |
| `.work/codex/review.diff` | review material generator | Prompt input for review session | Contract |
| `.work/codex/review.untracked.txt` | review material generator | Prompt input for review session | Contract |
| `.work/codex/review.raw.txt` | review session | Source for structured extraction and failure diagnosis | Contract |
| `.work/codex/review.txt` | review extractor | Parsed review result consumed by `continue_after_review.sh` and fix-from-review prompt | Contract |
| `.work/codex/fix-from-review.log` | fix-from-review run | Archived history and failure diagnosis | Contract |
| `.work/codex/history/<stem>.round-<NN>.<ext>` | history archiver | Regression guard and debugging artifacts | Contract |

History naming invariants:

- file name shape is `<stem>.round-%02d<extension>`
- implementation history starts at `implementation.round-00.log`
- check and review loops start at round `01`
- currently used stems are `implementation`, `checks`, `fix-from-checks`, `review-diff`, `review-untracked`, `review-raw`, `review`, and `fix-from-review`

Issue context and branch invariants:

- issue branch name shape is `issue/<issue_number>-<slug>`
- `<slug>` comes from the GitHub issue title, lowercased, non-alphanumeric runs collapsed to `-`, trimmed, and cut to `48` characters
- if slug generation produces an empty string, the fallback slug is `issue`
- this repository currently requires base ref `origin/main` and base branch `main`; extraction must preserve those values for this consumer

Contract vs current implementation detail:

- contract: the paths and file names listed above, the branch naming rule, and the base ref/base branch values for this repository
- current implementation detail: internal shell variable names, use of `mktemp`, exact helper function names, and smoke-only fixture files under temporary directories

## 6. Configuration Contract

Current state:

- engine defaults are in `tools/codex/lib/engine_defaults.sh`
- consumer policy is in `.issue_forge/project.sh` and loaded by `tools/codex/lib/consumer_config.sh`
- there is no `.codex/` directory and no `.codex/config.toml` in this repository today

v1 split target:

| Config location | What should live there |
| --- | --- |
| Shared engine defaults | Stable engine defaults that are not consumer-specific: `.work` state root, `.work/codex` layout, history naming rules, round limits, mode names, retry env var defaults |
| Consumer repo config | Repo-specific policy: base branch/ref, branch prefix, issue slug length, PR draft policy, prompt template directory, checks hook path, and mode-specific sandbox/reasoning values |
| Project-scoped Codex config | Optional consumer-owned `.codex/config.toml` or equivalent project Codex CLI config; engine must treat it as opaque and optional in v1 |
| `AGENTS.md` / repository docs | Human-readable repo policy and source-of-truth reading order for Codex sessions; not machine config, but required session context |

Recommended v1 shape for engine-side defaults:

```sh
# shared engine defaults
CODEX_ENGINE_WORK_ROOT=.work
CODEX_ENGINE_CODEX_SUBDIR=codex
CODEX_ENGINE_HISTORY_SUBDIR=history
CODEX_ENGINE_MAX_CHECK_FIX_ROUNDS=20
CODEX_ENGINE_MAX_REVIEW_FIX_ROUNDS=19
CODEX_ENGINE_MODE_WRITE=write
CODEX_ENGINE_MODE_READ=read
```

Recommended v1 shape for consumer-side config:

```sh
# consumer repo config for this repository
CODEX_FLOW_BASE_BRANCH=main
CODEX_FLOW_BASE_REF=origin/main
CODEX_FLOW_BRANCH_PREFIX=issue/
CODEX_FLOW_ISSUE_SLUG_MAX_LENGTH=48
CODEX_FLOW_PR_DRAFT_DEFAULT=1
CODEX_FLOW_PROMPTS_DIR=tools/codex/prompts
CODEX_FLOW_CHECKS_COMMAND=./tools/checks/run_changed.sh
CODEX_FLOW_WRITE_PROFILE=write
CODEX_FLOW_READ_PROFILE=read
CODEX_FLOW_WRITE_SANDBOX=danger-full-access
CODEX_FLOW_WRITE_REASONING=xhigh
CODEX_FLOW_READ_SANDBOX=danger-full-access
CODEX_FLOW_READ_REASONING=medium
```

Recommended v1 shape for repo-specific Codex profiles:

- keep the engine-visible modes as `write` and `read`
- let the consumer map those modes to sandbox and reasoning values
- do not make `.codex/config.toml` mandatory in v1
- if a future consumer wants Codex CLI model aliases in `.codex/config.toml`, that remains consumer-owned and outside the engine contract

Recommended v1 shape for prompt template and checks configuration:

- prompt template directory stays consumer-owned at `tools/codex/prompts/`
- checks hook stays consumer-owned at `tools/checks/run_changed.sh`
- the engine should read these paths from consumer config even if this first consumer keeps the current values

## 7. Prompt and Documentation Contract

Prompt generation after extraction should treat template text as consumer-owned and rendering behavior as engine-owned.

Template ownership and placeholder contract:

| Template | Consumer-owned path | Required placeholders | Engine dependency |
| --- | --- | --- | --- |
| Implementation | `tools/codex/prompts/implementation.prompt.md.tmpl` | `ISSUE_FILE`, `ISSUE_NUMBER` | Engine renders and passes to `run_codex.sh write` |
| Fix from checks | `tools/codex/prompts/fix-from-checks.prompt.md.tmpl` | `ISSUE_FILE`, `CHECKS_LOG`, `ISSUE_NUMBER` | Engine renders and passes to `run_codex.sh write` |
| Review | `tools/codex/prompts/review.prompt.md.tmpl` | `ISSUE_FILE`, `REVIEW_DIFF`, `REVIEW_UNTRACKED`, `ISSUE_NUMBER` | Engine renders and expects the structured review output described below |
| Fix from review | `tools/codex/prompts/fix-from-review.prompt.md.tmpl` | `ISSUE_FILE`, `REVIEW_OUTPUT`, `ISSUE_NUMBER` | Engine renders and passes to `run_codex.sh write` |

Why prompts remain consumer-owned:

- they encode repo-specific reading order and scope rules
- they refer to consumer docs and issue context files by relative path
- the acceptable implementation and review language is repository policy, not engine policy

Why `AGENTS.md` and repository docs remain consumer-owned:

- they define the repository’s source-of-truth hierarchy and engineering rules
- they can change independently of the engine
- the engine should assume they exist, not embed copies of them

What the engine may assume exists:

- `AGENTS.md` at repo root
- `docs/README.md` under `docs/`
- prompt templates at the configured consumer prompt directory
- `.work/issues/<issue>.md` and `.work/codex/*` files generated by the engine itself

What must stay customizable per repo:

- prompt wording
- which docs are treated as source-of-truth
- issue scope interpretation language
- repo-specific checks hook behavior
- sandbox and reasoning policy for Codex modes
- whether PRs default to draft

Structured review output is part of the engine contract and must not change in v1:

```text
accept: yes|no

blocker:
- ...

major:
- ...

minor:
- ...
```

More precisely:

- line 1 must be `accept: yes` or `accept: no`
- line 2 must be blank
- section headers must appear in this order: `blocker:`, `major:`, `minor:`
- section items are zero or more `- ` bullet lines
- the exact ordering is parsed by the engine and validated today in `tools/codex/lib/checks_review_helpers.sh`

## 8. Testing Contract

Validation after extraction should be split between engine-level behavior tests and consumer-level integration tests.

| Validation target | Owner after split | Scope |
| --- | --- | --- |
| Shell engine behavior with fixture repo | Shared engine repo | Generic orchestration, state paths, history naming, GitHub CLI integration shape, Codex mode mapping, review parsing, restart/continue semantics |
| Consumer prompts, checks, docs, and wrapper paths | Consumer repo | Repo-specific prompt content, docs references, checks hook contract, wrapper path stability, current consumer config values |
| End-to-end behavior-preservation smoke | Consumer repo | Proves that this repository still behaves the same while consuming the shared engine |

Existing `tools/codex/smoke_harness.sh` behaviors that belong to engine-level validation:

- `start_from_issue.sh` writes `.work/current_issue`, `.work/current_branch`, and `.work/issues/<issue>.md`
- issue branch naming follows `issue/<number>-<slug>`
- `run_codex.sh` preserves the current `write` and `read` mode mapping and invalid-mode failure
- Codex profile resolution fails on missing or invalid profile settings
- `run_issue_flow.sh` produces the current `.work/codex/*` file set and history naming pattern
- review sessions are read-only with respect to repository files
- review output extraction and validation preserve the current accept/blocker/major/minor format
- `restart_issue_flow.sh --hard` discards dirty changes outside `.work`
- `continue_after_review.sh` creates the intermediate `wip: address review feedback for issue #<n>` commit before rerunning
- `make_pr_only.sh` creates or returns the PR without pushing the branch

Existing behaviors that are consumer-specific after extraction:

- the exact prompt template contents
- the exact docs references inside prompts
- the repo-specific checks command and toolchain selection in `tools/checks/run_changed.sh`
- the consumer values for base ref/base branch, branch prefix, PR draft policy, and mode-specific sandbox/reasoning
- the continued presence of stable wrapper paths under `tools/codex/` and `tools/issue/`

What must remain true to claim behavior preservation:

- all current user-facing entrypoint paths still work from the consumer repo root
- `.work` files and history artifacts keep the same names and relative locations
- `run_changed.sh` is still invoked with the configured base ref and its output is still captured in `.work/codex/checks.log`
- review acceptance still depends on the same structured text format
- the first consumer still uses base ref `origin/main`, base branch `main`, and branch prefix `issue/`
- `make_pr_only.sh`, `run_issue_flow.sh`, `restart_issue_flow.sh`, and `continue_after_review.sh` keep the current PR/commit behavior

`tests/test_codex_smoke_harness.py` should remain as the top-level consumer assertion that the smoke harness passes end-to-end. The shared engine repo should add its own lower-level smoke coverage instead of taking over the consumer’s integration test entirely.

## 9. Migration Plan for This Repo as First Consumer

The migration should be incremental and reversible. Each phase should complete with unchanged external behavior before the next phase starts.

| Phase | Intended code movement | What remains in this repo | Validation before continuing | Rollback safety |
| --- | --- | --- | --- | --- |
| Phase 1: contract freeze | No code movement; add this contract document and docs discoverability | Everything | Doc review only | Revert docs only |
| Phase 2: create shared engine repo | Copy engine-owned entrypoints/libraries and generic smoke coverage into a new engine repo | Current in-repo implementation remains authoritative | Engine repo smoke tests pass against fixture repo | Ignore the new repo and continue using current in-repo scripts |
| Phase 3: formalize consumer assets | Separate consumer-owned prompts, checks hook, docs, and consumer config from engine-owned code without changing path behavior | Prompts, checks, docs, stable wrapper paths, consumer config, consumer smoke tests | Current consumer smoke harness still passes with no behavior change | Revert the config/wrapper split while leaving current scripts intact |
| Phase 4: switch wrappers to shared engine | Replace current user-facing scripts in this repo with thin wrappers or shims that delegate to the shared engine while keeping the same paths and CLI | Stable wrapper paths, prompts, checks hook, docs, consumer config, smoke tests | Consumer smoke harness passes unchanged against shared engine-backed wrappers | Point wrappers back to the in-repo copy or revert wrapper commits |
| Phase 5: remove duplicated engine code from consumer repo | Delete the copied engine implementation from this repo after parity is proven | Consumer-owned assets and stable wrappers only | Engine repo tests and consumer repo smoke harness both pass | Restore the last known-good vendored engine copy or revert the deletion |

Practical migration assumptions for this repository:

- this repo keeps the current user-facing script paths under `tools/codex/` and `tools/issue/`
- this repo remains the source of prompt text, docs, and repo-specific checks behavior
- extraction must preserve the current `.work` contract because both the runtime flow and the smoke harness depend on it
- current GitHub-only provider behavior is preserved in v1; provider abstraction is deferred

## 10. Open Questions / Deferred Items

- multi-provider issue sources are deferred because the current engine is explicitly `gh issue view`-based and no second provider exists in the code today
- non-GitHub PR publish providers are deferred because v1 must preserve `gh pr list/create` behavior first
- engine distribution mechanism is deferred because the contract can be defined before choosing submodule, subtree, vendored snapshot, or release artifact consumption
- moving from shell to another implementation language is deferred because it would mix behavior preservation with a rewrite
- structured review output redesign is deferred because the current engine parses a fixed text grammar and changing it would require simultaneous parser and prompt redesign
- plugin or skill packaging is deferred because the current invocation model is direct shell execution inside a git worktree
- direct engine interpretation of `.codex/config.toml` is deferred because no such file exists in the current repo and v1 must not introduce a new mandatory config surface

## 11. Acceptance Criteria for the Contract

- shared engine responsibilities are listed separately from consumer responsibilities
- every currently relevant file group in `tools/codex/`, `tools/issue/`, `tools/checks/`, and the smoke harness is classified
- the stable consumer-facing entrypoint paths and CLI shapes are defined
- required consumer-owned files, directories, commands, and config values are defined
- `.work` path invariants, history naming, branch naming, and base ref/base branch expectations are defined
- prompt template ownership, required placeholders, and structured review output format are defined
- testing ownership is split between engine-level validation and consumer-level integration validation
- a low-risk migration sequence with validation and rollback criteria is defined
- deferred items are explicitly isolated from v1 so extraction can start without redesign work
