# Docs README

このファイルは、この repo で Codex / reviewer が読むべき source-of-truth docs の入口です。

## 読む順番

1. `AGENTS.md`
   - この repo での最優先ルール
   - 変更方針、失敗方針、contract preservation の原則
2. `docs/consumer-contract.md`
   - v1 contract
   - stable entrypoints、`.work/` path、history naming、review format、consumer/engine boundary
3. `docs/codex_working_rules.md`
   - 実装時の具体的な working rules
   - prompt / checks / smoke harness を壊さないための注意点
4. `README.md`
   - repo の概要
   - entrypoint と全体フロー
5. `tools/codex/README.md`
   - smoke harness の目的と手動実行方法

## この repo で特に重視すること

- `tools/issue/start_from_issue.sh`、`tools/codex/*.sh` の stable wrapper path を維持すること。
- `.work/current_issue`、`.work/current_branch`、`.work/issues/<issue>.md`、`.work/codex/*` の path と命名を維持すること。
- review output の厳密フォーマットを維持すること。
- consumer-owned artifacts は this repo 自身が checked-in で持つこと。

## 読み分け

- 動作契約を確認したいときは `docs/consumer-contract.md` を優先します。
- 実装時の判断基準を確認したいときは `docs/codex_working_rules.md` を見ます。
- 背景や利用イメージを把握したいときは `README.md` を見ます。

