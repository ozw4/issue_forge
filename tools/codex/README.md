# Codex Flow Smoke Harness

`smoke_harness.sh` is a network-independent regression guard for the checked-in shell contract.

It covers two consumer shapes:

- first-time initialization fixtures that call `./vendor/issue_forge/tools/consumer/init.sh` from a direct-vendor consumer repo
- full-flow fixtures with only `.issue_forge/project.sh`, `.issue_forge/checks/run_changed.sh`, `AGENTS.md`, `README.md`, optional `docs/README.md`, and `vendor/issue_forge`

The fixture adds `vendor/issue_forge` as an untracked symlink after the baseline commit, then verifies that the flow still works through direct vendor entrypoints, excludes `.work/` and `vendor/issue_forge`, keeps working when the consumer `.gitignore` ignores those managed paths, and still surfaces consumer-owned changes elsewhere under `vendor/`.

Covered behavior includes:

- the direct vendor consumer init entrypoint updates `.gitignore`, creates minimal `.issue_forge/project.sh`, warns for missing `.issue_forge/checks/run_changed.sh` and `README.md`, does not warn for missing `docs/README.md`, does not create either docs entrypoint, and stays idempotent
- the direct vendor issue bootstrap entrypoint writes `.work/current_issue`, `.work/current_branch`, and the issue markdown file
- the direct vendor Codex execution entrypoint keeps the current `codex exec` defaults for `write` and `read`
- the direct vendor issue-flow entrypoint keeps the current `.work/codex/*` filenames, history round naming, review accept/format path, and worktree exclusions
- the direct vendor issue-queue entrypoint runs `./vendor/issue_forge/tools/codex/run_issue_queue.sh <issue1> <issue2>` as a strict-serial orchestrator, clears stale `.work/codex` before each issue, leaves final single-issue state on the last issue, and delegates push / PR create behavior to the existing full flow
- PR publishing generates the deterministic body format, stores body-file contents from the `gh` stub, covers the create path, and covers existing PR title/body sync through `gh pr edit`
- PR body assertions cover `Closes #<issue>`, summary, changed files, checks, review, checks/review artifacts when present, and `not available yet` when those artifacts are missing

The queue coverage intentionally does not add merge automation, approval automation, auto-merge, PR polling, wait loops, or queue persistence state.

Manual run:

```bash
./tools/codex/smoke_harness.sh
```

The harness does not call external GitHub or Codex services.
