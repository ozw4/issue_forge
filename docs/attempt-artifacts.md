# Attempt Artifact Contract

This document is a normative addendum to `docs/consumer-contract.md` for implementation, checks, review, and repair attempt artifacts.

## Authoritative roots

Single-Issue attempts are authoritative under:

```text
.work/codex/attempts/<phase>.round-<round>.attempt-<id>/
```

Queue batch attempts are authoritative under the immutable queue run:

```text
.work/queue/runs/<run-id>/batches/<batch-id>/attempts/<phase>.round-<round>.attempt-<id>/
```

`.work/queue/batches/<batch-id>/` remains a compatibility artifact path. It may contain the established logs, prompts, summaries, review files, token TSV, and history, but it does not own authoritative batch attempt directories. Reusing the same Issue range in another queue run must not share attempts or `latest` pointers.

## Attempt contents and identity

Each attempt has a unique directory and records:

```text
input.state
output.log
stderr.log          # stdout-only phases
parsed-review.txt   # successfully parsed review phases
result.state
```

`input.state` records the attempt ID, `run_id`, `scope`, `scope_id`, phase, logical round, execution mode, reasoning effort, prompt identity, compatibility output path, and command-argv hash. Standalone attempts use `run_id=none`, `scope=standalone`, and `scope_id=none`. Issue attempts identify the Issue. Queue batch attempts identify both the queue run and batch.

A later invocation always creates a new attempt directory. It never reuses or rewrites an earlier terminal attempt.

## Terminal publication

Before `result.state` becomes visible, `output.log`, optional `stderr.log`, and optional `parsed-review.txt` are frozen read-only. `result.state` is then written read-only through an atomic sibling-file replacement.

The compatibility view and `attempts/latest/<phase>.state` are published only from a terminal attempt. A small `attempts/pending/<phase>.state` journal records an in-progress publication. The next attempt-store invocation verifies the terminal hashes and either completes that publication or discards a journal that never reached `result.state`.

Compatibility files remain writable because existing prompts, history publication, and PR generation consume those paths. Read-only mode applies to authoritative attempt files, not the compatibility copies.

## Review publication and retry

For `review` and `batch-review`, process exit `0` is not sufficient for success. The raw output must parse and pass the existing review schema and semantic validation before the attempt is published.

The engine fingerprints `HEAD`, the index diff, the tracked worktree diff, and the path, executable bit, and content hash of untracked files immediately before and after each reviewer command. Managed internal paths such as `.work` and the vendored engine remain excluded by the normal worktree pathspecs.

If the fingerprint changes, that attempt is recorded as `invalid` and is not published. Review material is regenerated from the new repository state and the reviewer is run again. The default limit is three retries per logical review round and can be overridden with `CODEX_FLOW_REVIEW_RETRY_LIMIT`. If the repository keeps changing after the limit, the flow fails without advancing the compatibility review or `latest` pointer.

A successful review advances the raw compatibility file, parsed compatibility file, and `latest` pointer from the same attempt. A parser failure records an `invalid` attempt with `parser_status=failed`, does not create `parsed-review.txt`, and leaves the previously published raw/parsed generation and `latest` pointer unchanged.

## Token usage paths

When an immutable attempt log is inside the same artifact tree as `token-usage.tsv`, the TSV stores the log relative to the TSV directory:

```text
./attempts/<attempt-id>/output.log
```

The complete artifact tree may therefore be copied to a queue archive and the source removed without invalidating the token-to-log reference. Paths outside the TSV artifact tree remain unchanged.

## Compatibility invariants

The established paths in `docs/consumer-contract.md`, including `.work/codex/*.log`, review files, history names, and `.work/queue/batches/<batch-id>/`, remain supported compatibility views. Attempt artifacts add provenance and interruption safety; they do not change review output format, branch naming, GitHub publication behavior, or the consumer-owned file set.
