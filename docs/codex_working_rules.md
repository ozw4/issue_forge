# Codex Working Rules

`issue_forge` を変更するときの具体的な作業ルールです。

## 1. Stable contract を先に守る

次は contract surface なので、理由なく変えません。

- `tools/issue/start_from_issue.sh`
- `tools/codex/run_issue_flow.sh`
- `tools/codex/restart_issue_flow.sh`
- `tools/codex/continue_after_review.sh`
- `tools/codex/make_pr_only.sh`
- `tools/codex/run_codex.sh`
- `.work/` 配下の path と file name
- review output format
- issue branch naming rule

これらを変える場合は、`docs/consumer-contract.md` と smoke coverage も同時に更新します。

## 2. Engine と consumer の境界を崩さない

engine 側に置くもの:

- reusable shell libraries
- issue bootstrap / state / publish / review orchestration
- generic smoke behavior

consumer 側に残すもの:

- `AGENTS.md`
- `docs/README.md` と source-of-truth docs
- `tools/checks/run_changed.sh`
- `.issue_forge/project.sh`
- prompt templates

repo 固有のルールや docs を engine 側の暗黙知に押し込まないでください。

## 3. Prompt と docs の扱い

- prompt templates は repo 固有 instructions を持つ consumer asset です。
- prompt から参照する docs path は checked-in の実体と一致させてください。
- docs を追加したら `docs/README.md` に読む順番を反映してください。
- docs の wording を変えるだけでも、runtime behavior と矛盾していないか確認してください。

## 4. Shell 実装のルール

- 既存 helper があるなら再利用し、同等ロジックの再実装を避けます。
- エラーは早く、具体的に失敗させます。
- 想定可能な異常は明示的に検証し、無言フォールバックは入れません。
- path、prompt file、history file の命名は文字列契約として扱います。

## 5. Checks hook のルール

- `tools/checks/run_changed.sh` は non-interactive です。
- base ref を 1 つ受け取ります。
- tracked file を自動修正しません。
- この repo では、変更対象に応じて shellcheck と smoke harness を回す方針です。
- smoke harness 用の挙動が必要な場合も、checked-in hook から制御できる形を優先します。

## 6. Smoke harness のルール

- fixture は checked-in contract を検証するためのものです。
- consumer-owned artifacts を harness 側で恒久的に捏造しないでください。
- 可能な限り checked-in の `AGENTS.md`、`docs/README.md`、`tools/checks/run_changed.sh`、`.issue_forge/project.sh` を fixture repo にコピーして使います。
- harness 専用の差分は、状態ファイルや stub binary など最小限に留めます。

