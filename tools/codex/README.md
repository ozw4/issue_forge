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
- Issue and Batch checks share one immutable check-attempt helper; strict manifests bind exact argv, fixed base, review snapshot, exit/signal result, and combined-log hash while legacy checks logs remain atomic compatibility views
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

Rows are appended after Codex calls when the corresponding Codex log contains a `tokens used` block followed by a numeric value. Comma separators are normalized, so `133,813` is recorded as `133813`. Logs without token usage leave the TSV with only its header; collection is observability-only and does not fail the flow.

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

## Queue Agent Attempts

Queue runs preserve each Codex invocation below the authoritative run directory:

```text
.work/queue/runs/<run_id>/batches/<batch_id>/attempts/
├── issue-<issue_number>/<operation>/attempt-NNNN/
└── batch/<operation>/attempt-NNNN/
```

Each terminal attempt contains `request.state`, the exact `prompt.md`, one combined stdout/stderr `agent.log`, and `result.state`. An `attempt-NNNN.running/` directory means the process stopped before terminal finalization. Later executions do not overwrite terminal or `.running` attempts and use the next sequence number. The existing `.work/codex` and batch log filenames remain compatibility views: combined-policy logs receive `agent.log`, while stdout-policy raw review logs receive stdout only. Standalone `run_issue_flow.sh` executions do not enable this attempt store by default.

Issue and batch review rounds capture a review snapshot as the consumer repository `HEAD` commit plus a Git tree for the current worktree, honoring the standard worktree exclusions. The snapshot must still match after the Reviewer and before the rejected-review fix cycle begins; a mismatch stops the flow. Each active Fixer then captures a fresh snapshot immediately before its own invocation, so later Fixer attempts include the changes produced by earlier active findings. With the attempt store enabled, every review and Fixer attempt preserves the snapshot it actually received. The original Batch review snapshot remains the reconciliation boundary for the cycle.

## Finding Ledgers

Starting a new standalone Issue through `start_from_issue.sh` removes the previous `.work/codex` only after the new Issue branch is created successfully. The Issue ledger is therefore scoped to that Issue at `.work/codex/findings.tsv`.

Validated batch reviews use `.work/queue/runs/<run_id>/batches/<batch>/findings.tsv` as the source of truth. A resume continues the same run-owned ledger; another run over the same batch range starts a separate ledger. After each round, the engine copies the current ledger and that round's history to `.work/queue/batches/<batch>/findings.tsv` and `.work/queue/batches/<batch>/history/findings.round-NN.tsv` for compatibility, but never reads those copies as finding state.

Both ledger types use the TSV columns `finding_id`, `severity`, `first_round`, `last_seen_round`, `status`, `resolution`, and `text`. IDs are ledger-local sequences starting at `F0001` and are reused only for exact normalized-text matches. Normalization removes the leading review bullet marker and a trailing CR, and replaces each literal tab with one space; category tags remain part of batch finding text.

The concise blocker, major, and minor sentences remain the source of truth for acceptance, severity, ledger identity, pending findings, and unresolved matching. Each current finding also has one structured detail record containing `finding`, `severity`, `evidence`, `impact`, `required_outcome`, `constraints`, and `validation`. Details are auxiliary Fixer context, not part of identity and not a prescribed patch design; changing only details leaves the finding ID unchanged.

Validated Issue details are written to `.work/codex/review-details.tsv` with round copies at `.work/codex/history/review-details.round-NN.tsv`. Before a fix, the engine joins current details to ledger-owned pending IDs and writes `.work/codex/pending-finding-details.tsv`. The review details header is:

```text
severity	finding	evidence	impact	required_outcome	constraints	validation
```

The pending details header is:

```text
finding_id	severity	text	evidence	impact	required_outcome	constraints	validation
```

Batch details are authoritative at `.work/queue/runs/<run_id>/batches/<batch>/review-details.tsv`, `.work/queue/runs/<run_id>/batches/<batch>/history/review-details.round-NN.tsv`, and `.work/queue/runs/<run_id>/batches/<batch>/pending-finding-details.tsv`. They are copied to the corresponding paths below `.work/queue/batches/<batch>/` for compatibility. The pending join preserves `pending-findings.tsv` order and uses only existing ledger IDs. Missing, unknown, or duplicate mappings and malformed or missing required artifacts fail explicitly; the engine never synthesizes details from concise findings or reads a compatibility copy as authoritative state.

`status` is observation state: a finding seen in the current round is `present`, while an absent prior finding is retained as `not_observed`. `resolution` is lifecycle state: new findings are `unresolved`, and only the next Reviewer may verify them as `resolved` or `invalid`. A resolved or invalid finding that reappears keeps its ID and returns to `unresolved`.

Before each rejected-review cycle, current `present` and `unresolved` records are written once to `pending-findings.tsv` and joined to `pending-finding-details.tsv`. The scheduler selects one unprocessed row by `blocker`, `major`, then `minor`, preserving pending order within a severity. It atomically replaces `active-finding-details.tsv` first and `active-finding.tsv` last as the commit marker; the two renames are not simultaneous. Before consuming the active ID, the engine validates matching zero-or-one-row cardinality plus exact `finding_id`, `severity`, and `text`, so an interrupted old/new pair fails closed before a Fixer starts. The active concise row and source-of-truth documentation are normative; active details help the Fixer confirm evidence, satisfy the required outcome and constraints, and choose focused validation. The `validation` field is guidance and is never executed as shell input.

Each pending ID receives at most one sequential Fixer attempt in that cycle. Immediately before and after the invocation, the engine hashes and compares the two pending artifacts, cumulative resolution, two active artifacts, and generated Fixer prompt. Any missing, replaced, or byte-modified scheduler artifact stops the flow before the Fixer log is parsed or a claim is appended. The Fixer chooses the smallest safe implementation, does not intentionally address another pending finding, starts no multi-agent or parallel work, and normally runs only the smallest directly relevant validation. Focused validation is not acceptance evidence and does not replace configured full Checks. Queue resume derives Batch Fixer progress only from run-owned attempts and cumulative resolution state; unmatched attempts fail closed rather than repeating an active ID.

Each Fixer returns exactly one `fixed`, `false_positive`, or `cannot_fix` claim for its active ID. `fix-resolution.tsv` accumulates those rows in processing order for the current cycle and is reinitialized when a new rejected cycle begins. A claim does not close a finding: only the next Reviewer records `resolved`, `invalid`, or `unresolved` in `review-verification.tsv`. After all active findings receive an attempt, standalone Issue and changed Batch cycles enter full Checks once and then rerun Reviewer; a failed check continues through the existing checks-fix loop. An unchanged Batch cycle whose claims are all `false_positive` or `cannot_fix` skips its commit and Checks.

```text
Reviewer
  -> pending findings
  -> one active finding
  -> one Fixer
  -> focused validation by that Fixer
  -> next active finding
  -> full Checks once
  -> Reviewer verification
```

For example, this pending set is scheduled as `F0002` and then `F0001` because major precedes minor:

```text
finding_id	severity	text
F0001	minor	Document the edge case.
F0002	major	Restore the required guard.
```

The two one-line Fixer outputs:

```text
resolution:
- F0002 | fixed | Restored the required guard.

resolution:
- F0001 | cannot_fix | The consumer contract forbids the requested change.
```

produce this cumulative report:

```text
finding_id	action	note
F0002	fixed	Restored the required guard.
F0001	cannot_fix	The consumer contract forbids the requested change.
```

Issue active artifacts and `fix-from-review.snapshot.state` live below `.work/codex/`, including cycle history at `history/fix-resolution.round-NN.tsv`. Batch active artifacts and cumulative resolution state are authoritative below `.work/queue/runs/<run_id>/batches/<batch>/`; active artifacts have no compatibility copy. Pending artifacts, cumulative resolution, and resolution history are copied below `.work/queue/batches/<batch>/` but are never read as run-owned state. The current Batch Fixer snapshot exists only at the compatibility artifact path `.work/queue/batches/<batch>/fix-from-batch-review.snapshot.state`; immutable attempts retain the snapshot they received. A changed Batch cycle creates one review-fix commit after all Fixers and then starts one full Batch Checks phase. If no files changed and every claim is `false_positive` or `cannot_fix`, Batch skips that commit and Checks.

Current acceptance still uses the current structured review finding sections rather than scanning the full ledger. `accept: no` requires at least one current blocker, major, or minor finding; verification records alone are not a rejection reason. After each round, the current ledger is copied to its corresponding `history/findings.round-NN.tsv` path.

The run-owned Batch directory also stores `review-lifecycle.state` (schema version 1) with the logical review/fix rounds, the next `review`, `fix`, or `complete` action, and an update timestamp. Resume follows that state, so a completed fix continues with the next review and a completed review does not rerun before the outer queue checkpoint is written. If a review fix commit became durable before lifecycle publication, resume adopts the expected linear review/check-fix commit frontier only with a clean worktree, a current cumulative resolution exactly matching valid run-owned history and covering every pending ID, and a still-valid run-owned pending-details mapping; it reruns checks without rerunning the Fixer, and then advances to the next review. This is Batch-review control state, separate from Agent attempts and finding data; it has no compatibility copy and does not alter queue state schema version 3.

## Check Attempts

Standalone Issue checks store terminal attempts at `.work/codex/check-attempts/issue-checks/attempt-NNNN/` and the strict TSV index at `.work/codex/checks.manifest.tsv`. Queue Issue attempts are authoritative at `.work/queue/runs/<run_id>/batches/<batch>/check-attempts/issue-<issue>/`; their manifests are `checks/issue-<issue>.manifest.tsv`, and validated copies are included in the run-owned Issue archive. Batch attempts use the sibling `check-attempts/batch/` store and `checks/batch.manifest.tsv`.

An unfinished `.running` directory is preserved but never indexed as terminal. Resume scans both terminal and `.running` IDs and allocates the next sequence. Terminal `combined.log` is the only input for atomic legacy `checks.log` publication and check history. The manifest and terminal artifacts, rather than the legacy log, determine the latest structured result. Checks are snapshot-verified as read-only operations using the same exclusions as review snapshots; a repository mutation produces `status=invalid` and is left intact for operator inspection.
