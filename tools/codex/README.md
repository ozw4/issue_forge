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
- the direct vendor issue queue processes issues sequentially in input order on one batch branch, persists its fresh plan and queue/batch/Issue lifecycle state, resumes the first unfinished phase from that local state, archives per-issue Codex artifacts atomically, runs batch checks/review/fix loops with configured reasoning effort, creates a single batch PR, records terminal success/failure, and fails before modification when multiple batches are requested without `--auto-merge`
- queue resume fixtures cover terminal no-op, post-edit implementation failure without duplicate implementation, commit reconciliation without duplicate commit, accepted and malformed/raw-only batch review checkpoints, post-create PR recovery without duplicate creation, open and already-merged auto-merge reconciliation through ack, saved-base branch recreation without duplicate branch creation, completed archive reuse and temporary archive cleanup, committed-Issue skip, batch checks, stale/live/fresh locks, dirty wrong-branch rejection, and missing/old plan or state rejection
- explicit requeue fixtures cover destructive reset/clean of the current failed Issue, preservation of `.work` and logical `vendor/issue_forge`, queued/context restoration while queue and batch stay failed, batch artifact invalidation with history preservation, idempotent Issue context, fresh one-time implementation on the following `--resume`, and committed/unplanned/later-progressed/missing-base/live-lock rejection
- batch helper fixtures restore check/review rounds and cumulative fix budgets from history, reuse clean accepted reviews, discard stale structured output when a newer review is interrupted, re-evaluate dirty interrupted fixes, reconcile existing PRs before creation (including incomplete saved metadata), atomically persist batch head/PR metadata, and skip duplicate auto-merge requests for merged PRs
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

Rows are appended after Codex calls when the corresponding Codex log contains a `tokens used` block followed by a numeric value. Comma separators are normalized, so `133,813` is recorded as `133813`. A phase/subject/round key is appended at most once, which makes collection idempotent across reconciliation. Logs without token usage leave the TSV with only its header; collection is observability-only and does not fail the flow.

## Internal Issue Checkpoints

Queue mode passes each Issue `state.tsv` and `head_commit` path to `run_issue_flow.sh`. This enables resume-safe internal dispatch across `implementation`, `checks`, `review`, `commit`, and `archive`; phase always names the next action. It is limited to `CODEX_FLOW_SKIP_PUBLISH=1`. The public `run_issue_queue.sh --resume` entrypoint restores the saved schema-v1 plan and drives these checkpoints on the same local worktree. Normal single-Issue invocation does not use these checkpoint variables and still requires a clean worktree at entry.

`run_issue_queue.sh --requeue <issue_number>` is the destructive alternative to continuing partial Issue work. It is limited to the first unfinished `failed`/`leased` Issue in its saved batch, resets that batch branch to the Issue-local base commit, removes the active/unfinished Issue artifacts and current batch completion artifacts, and leaves the Issue at `queued / context` while queue and batch stay terminal `failed`. It never resumes automatically; the operator must run `run_issue_queue.sh --resume` separately. Failed-attempt generations are not retained.

Queue checkpoints are schema-v1 local single-worker state. Issue leases name the owning batch and have no TTL or heartbeat. Atomic writes mean temporary-file replacement by same-directory rename for one checkpoint file, not a full transaction or `fsync` guarantee. Resume therefore reconciles the documented normal post-side-effect windows only in the same local worktree and branch. Old incomplete queue migration, remote branch recovery outside the saved-base `branch` checkpoint, automatic retry/requeue, backoff, and dead-letter handling remain intentionally unsupported.

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
