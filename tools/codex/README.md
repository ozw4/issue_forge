# Codex Flow Smoke Harness

`smoke_harness.sh` is a network-independent regression guard for the checked-in shell contract.

It covers two consumer shapes:

- first-time initialization fixtures that call `./vendor/issue_forge/tools/consumer/init.sh` from a direct-vendor consumer repo
- full-flow fixtures with only `.issue_forge/project.sh`, `.issue_forge/checks/run_changed.sh`, `AGENTS.md`, `README.md`, optional `docs/README.md`, and `vendor/issue_forge`

The fixture adds `vendor/issue_forge` as an untracked symlink after the baseline commit, then verifies that the flow still works through direct vendor entrypoints, excludes `.work/` and `vendor/issue_forge`, keeps working when the consumer `.gitignore` ignores those managed paths, and still surfaces consumer-owned changes elsewhere under `vendor/`.

Covered behavior includes:

- the direct vendor consumer init entrypoint updates `.gitignore`, creates minimal `.issue_forge/project.sh`, keeps no-flag warning-only behavior for missing `.issue_forge/checks/run_changed.sh` and `README.md`, does not warn for missing `docs/README.md`, does not create docs or run convenience files without opt-in, can opt in to `--scaffold-checks`, can opt in to `--scaffold-run`, preserves existing consumer-owned scaffold files, and verifies the generated shell snippet forwards `run 5` from a subdirectory
- the direct vendor issue bootstrap entrypoint writes `.work/current_issue`, `.work/current_branch`, and the issue markdown file
- the direct vendor Codex execution entrypoint keeps the current `codex exec` defaults for `write` and `read`
- `CODEX_RUN_REASONING_EFFORT` overrides reasoning for one `run_codex.sh` invocation without changing normal write/read profile defaults
- the direct vendor issue-flow entrypoint passes phase-specific reasoning for implementation, checks repair, review, and review repair while preserving profile-derived defaults
- Codex token usage TSV artifacts are initialized for single-issue and batch flows, and token counts are recorded when Codex logs include a `tokens used` block
- queue mode defaults to a light per-issue review prompt and retains strict final batch review
- the direct vendor issue-flow entrypoint keeps the current `.work/codex/*` filenames, history round naming, review accept/format path, and worktree exclusions
- review material keeps text diffs in `review.diff`/`batch.diff`, writes compact `review.summary.txt`/`batch.summary.txt` metadata, and omits `GIT binary patch` payloads
- `CODEX_FLOW_SKIP_PUBLISH=1` keeps issue-flow commits while skipping branch push and issue PR creation
- the direct vendor issue queue processes issues sequentially in input order on one batch branch, archives per-issue Codex artifacts, runs batch checks/review/fix loops with configured reasoning effort, creates a single batch PR, and fails before modification when multiple batches are requested without `--auto-merge`
- queue control-plane coverage uses real `kill -9` owner death before worker registration, after registration, after authorization, after durable `run.state=completed`, at every completed-cleanup transaction boundary, and during a paused external child; it verifies cleanup with invalid current work settings, phase/filesystem postcondition reconciliation, terminal-residue detection, parent-liveness self-release, registration/authorization fencing, cross-run isolation, exact terminal checkpoint phases, and byte-identical Issue/Codex/Git/push/PR/merge counters across finalization retries
- queue entity-integrity coverage verifies manifest-derived graph identity, adjacent state/field invariants, saved-base branch recovery, direct-child Issue commits, the fresh-commit adoption window, atomic run-owned archive publication and tamper rejection, deterministic `issues.txt` rebuilds, accepted-head drift rejection, dirty inner-phase manual review, and distinct authoritative archives for repeated Issue ranges
- a real linked-worktree fixture verifies that fresh, explicit-resume, and current-resume queue invocations reject before local/common queue state or external side effects, while the primary worktree remains usable
- queue singleton-path coverage rejects directory, symlink, FIFO, and unexpected-hard-link state targets without nested temporary publication or side effects; private guard variables are injected through full startup/contention, and `.work/queue` is removed while the Git-common-dir guard inode continues to fence a second owner
- PR publishing generates the deterministic body format, stores body-file contents from the `gh` stub, covers the create path, and covers existing PR title/body sync through `gh pr edit`
- PR body assertions cover `Closes #<issue>`, summary, changed files, checks, review, checks/review artifacts when present, and `not available yet` when those artifacts are missing
- the harness asserts that no GitHub workflow file is created

Manual run:

```bash
./tools/codex/smoke_harness.sh
```

The harness does not call external GitHub or Codex services.

## Single-Issue Reasoning

Consumers can tune reasoning effort per phase in `.issue_forge/project.sh`:

| Setting | Default | Applied to |
| --- | --- | --- |
| `CODEX_FLOW_IMPLEMENTATION_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` | initial implementation |
| `CODEX_FLOW_CHECK_FIX_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` | fix-from-checks rounds |
| `CODEX_FLOW_REVIEW_REASONING` | `${CODEX_FLOW_PROFILE_READ_REASONING}` | review rounds |
| `CODEX_FLOW_REVIEW_FIX_REASONING` | `${CODEX_FLOW_PROFILE_WRITE_REASONING}` | fix-from-review rounds |

Each value is validated after defaults are applied and must be non-empty with no whitespace. A typical progressive-effort setup lowers normal implementation effort and keeps repair phases strict, for example:

```sh
CODEX_FLOW_IMPLEMENTATION_REASONING='high'
CODEX_FLOW_CHECK_FIX_REASONING='xhigh'
CODEX_FLOW_REVIEW_REASONING='medium'
CODEX_FLOW_REVIEW_FIX_REASONING='xhigh'
```

Batch reasoning remains controlled by the existing batch-specific variables and queue flags.

## Token Usage Metrics

Issue flows write `.work/codex/token-usage.tsv` with this header:

```text
phase	issue	round	reasoning	tokens	log
```

Batch flows write `.work/queue/batches/<batch>/token-usage.tsv` with this header:

```text
phase	issues	round	reasoning	tokens	log
```

Rows are appended after Codex calls when the corresponding Codex log contains a `tokens used` block followed by a numeric value. Comma separators are normalized, so `133,813` is recorded as `133813`. Logs without token usage leave the TSV with only its header; collection is observability-only and does not fail the flow. New rows reference the immutable attempt `output.log`, not the mutable compatibility log.

## Attempt Artifacts

Each implementation, checks, review, and repair invocation writes to a unique attempt directory before updating the established compatibility filenames.

Single-Issue attempts are stored under:

```text
.work/codex/attempts/<phase>.round-<round>.attempt-<id>/
```

Batch attempts are stored under:

```text
.work/queue/batches/<batch>/attempts/<phase>.round-<round>.attempt-<id>/
```

An attempt contains:

```text
input.state     # immutable invocation identity and input hashes
output.log      # command output; stderr is combined unless the phase uses stdout-only output
stderr.log      # present for stdout-only review phases
result.state    # terminal exit status and output hashes
```

`result.state` is created only after the command returns. Its absence means the attempt was interrupted or otherwise did not reach terminal publication. Terminal attempt files are made read-only and are never reused by a later invocation.

The existing files such as `implementation.log`, `checks.log`, `review.raw.txt`, and `batch-review.raw.txt` remain compatibility views. They are replaced atomically only after an attempt reaches a terminal result, so an interrupted attempt does not overwrite the last published compatibility output. `attempts/latest/<phase>.state` identifies the latest terminal attempt for that phase.

## Queue Light Review

Queue mode derives `CODEX_FLOW_LIGHT_ISSUE_REVIEW` for each `run_issue_flow.sh` invocation from `CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW`: `1` when queue light review is enabled, and `0` when it is disabled. The consumer config default is:

```sh
CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW=1
```

With that default, per-issue `.work/codex/review.prompt.md` is rendered from `review-light.prompt.md.tmpl`. The output schema and validation are unchanged, but the prompt avoids broad docs rereads and leaves cross-issue analysis to the strict final batch review.

Consumers that want full strict review for every queued issue can disable it:

```sh
CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW=0
```

Queue mode passes `CODEX_FLOW_LIGHT_ISSUE_REVIEW=0` in that case, so a parent `CODEX_FLOW_LIGHT_ISSUE_REVIEW=1` environment value cannot force light per-issue reviews. Batch review still uses `batch-review.prompt.md.tmpl` and remains strict.
