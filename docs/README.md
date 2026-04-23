# Docs README

このファイルは、この repo で Codex / reviewer が読むべき source-of-truth docs の入口です。

## 読む順番

1. `AGENTS.md`
   - 最優先ルール
   - engine root / consumer root の扱い
   - 最小差分、fail-fast、contract preservation の原則
2. `docs/consumer-contract.md`
   - direct vendor invocation contract
   - minimal consumer-owned files
   - config defaults、PR body/title sync、`.work` invariants、review format invariants
3. `docs/codex_working_rules.md`
   - 実装時の具体的な working rules
   - smoke fixture と git exclusion の注意点
4. `README.md`
   - repo の概要
   - consumer layout と日常的な使い方
5. `tools/codex/README.md`
   - smoke harness の目的と手動実行方法

## この repo で特に重視すること

- external consumer entrypoints は `vendor/issue_forge/tools/consumer/init.sh`、`vendor/issue_forge/tools/issue/start_from_issue.sh`、`vendor/issue_forge/tools/codex/*.sh` です。
- external consumers は `./tools/codex` や `./tools/issue` の shim を持つ必要がありません。
- consumer docs の primary entrypoint は `README.md` です。`docs/README.md` は追加 docs が必要な場合だけ optional です。
- typical consumer-owned paths は `.issue_forge/project.sh`、`.issue_forge/checks/run_changed.sh`、`AGENTS.md`、`README.md`、optional `docs/README.md`、`vendor/issue_forge` です。`tools/consumer/init.sh` は `.gitignore` を更新し、`.issue_forge/project.sh` を初期化できますが、`README.md` と `docs/README.md` は作らず、missing warning は `.issue_forge/checks/run_changed.sh` と `README.md` にだけ出します。
- `.work/current_issue`、`.work/current_branch`、`.work/issues/<issue>.md`、`.work/codex/*` の path と命名は維持します。
- review output の厳密フォーマットを維持します。
- PR publish は deterministic な body を生成し、open PR がある場合は title/body だけを同期更新します。
- consumer git hygiene として `.work`、`.work/`、`vendor/issue_forge`、`vendor/issue_forge/` を ignore することを推奨します。
- この repo 自体は self-hosting のため `tools/codex/` と `tools/issue/` の checked-in entrypoint を持ち続けます。

## 読み分け

- 動作契約を確認したいときは `docs/consumer-contract.md` を優先します。
- 実装時の判断基準を確認したいときは `docs/codex_working_rules.md` を見ます。
- 背景や利用イメージを把握したいときは `README.md` を見ます。
