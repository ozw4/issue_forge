# issue_forge

Shared shell engine extracted from seisviewer3d.

Current state:
- bootstrap copy from the consumer repo
- path layout intentionally preserved first
- behavior-preserving extraction comes before cleanup

Primary contract:
- see docs/consumer-contract.md


Vendored runtime usage:
- mount or place this repository at `<consumer-repo>/vendor/issue_forge`
- consumer-owned policy stays in `<consumer-repo>/.issue_forge/project.sh`
- consumer-owned prompts stay in `<consumer-repo>/.issue_forge/prompts/`
- `tools/codex/lib/config.sh` resolves the consumer repo root in vendored mode and standalone smoke fixtures
