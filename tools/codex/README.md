# Codex Flow Smoke Harness

`smoke_harness.sh` is a network-independent regression guard for the checked-in shell contract.

It creates a temporary consumer fixture with only:

- `.issue_forge/project.sh`
- `.issue_forge/checks/run_changed.sh`
- `AGENTS.md`
- `README.md`
- `docs/README.md`
- `vendor/issue_forge`

The fixture adds `vendor/issue_forge` as an untracked symlink after the baseline commit, then verifies that the flow still works through direct vendor entrypoints and that git operations exclude both `.work/` and `vendor/issue_forge`.

Covered behavior includes:

- the direct vendor issue bootstrap entrypoint writes `.work/current_issue`, `.work/current_branch`, and the issue markdown file
- the direct vendor Codex execution entrypoint keeps the current `codex exec` defaults for `write` and `read`
- the direct vendor issue-flow entrypoint keeps the current `.work/codex/*` filenames, history round naming, review accept/format path, and worktree exclusions

Manual run:

```bash
./tools/codex/smoke_harness.sh
```

The harness does not call external GitHub or Codex services.
