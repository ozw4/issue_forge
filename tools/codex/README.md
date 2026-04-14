# Codex Flow Smoke Harness

`smoke_harness.sh` is a network-independent regression guard for `tools/codex/` and `tools/issue/`.

It creates a temporary local git fixture, stubs `gh` and `codex`, wraps `git` to log invocations while delegating to the local binary, and verifies:

- `tools/issue/start_from_issue.sh` writes `.work/current_issue`, `.work/current_branch`, and the issue markdown file
- `tools/codex/run_codex.sh` keeps the current `codex exec` defaults for `write` and `read`
- `tools/codex/run_issue_flow.sh` keeps the current `.work/codex/*` filenames, history round naming, and review accept/format path

Manual run:

```bash
./tools/codex/smoke_harness.sh
```

The harness does not call external GitHub or Codex services.
