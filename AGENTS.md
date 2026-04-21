# AGENTS.md

このリポジトリで Codex / 自動化フローが最初に従うべきルールを定義します。

## 優先順位

1. `docs/consumer-contract.md`
2. `docs/README.md` から辿る source-of-truth docs
3. `README.md`
4. GitHub issue 本文と `.work/` artifacts

概要説明と契約が食い違う場合は、`docs/consumer-contract.md` を正とします。

## この repo の位置づけ

- この repo は `issue_forge` の shared engine であると同時に、self-hosting する first consumer です。
- external consumer contract は `vendor/issue_forge/tools/...` を直接呼ぶ形です。consumer repo に `./tools/codex/*.sh` や `./tools/issue/*.sh` の wrapper / shim は要求しません。
- この repo 自身は engine 開発と regression coverage のために `tools/codex/`、`tools/issue/`、`tools/checks/run_changed.sh`、`tools/codex/prompts/*.tmpl` を checked-in で持ち続けます。

## 実装ルール

- まず既存の shell helper を再利用し、ロジックの重複を増やさないこと。
- shell ベースのアーキテクチャを維持し、サービス化・デーモン化・別言語への全面移植はしないこと。
- 変更は issue scope に限定し、最小差分で行うこと。
- fallback や互換レイヤーは原則追加しないこと。
- 異常系は握りつぶさず、根本原因が分かる具体的なメッセージで即時失敗すること。
- engine root と consumer root を混同しないこと。`ISSUE_FORGE_ENGINE_ROOT` と `CODEX_FLOW_REPO_ROOT` は別概念として扱います。
- `.work/` レイアウト、history 命名、branch 命名、review 出力フォーマットは contract を更新しない限り維持すること。
- default prompts は engine-owned の `vendor/issue_forge/tools/codex/prompts/` です。consumer-specific prompts は `CODEX_FLOW_PROMPTS_DIR` で明示 override する場合のみ使います。
- default checks hook は `./.issue_forge/checks/run_changed.sh` です。
- issue の要求が docs と衝突する場合は docs を優先すること。

## チェックとレビュー

- 実装を終えたら、consumer checks hook と smoke harness で checked-in behavior を検証すること。
- `tools/checks/run_changed.sh` は validation only とし、tracked file を自動修正しないこと。
- review session は read-only です。コードやワークツリーを変更してはいけません。
- レビューや確認では、省略記号でごまかさず checked-in の正確なコードを基準に判断すること。

## ドキュメント更新ルール

- runtime behavior を変えた場合は、必要に応じて `README.md`、`docs/README.md`、`docs/consumer-contract.md`、`docs/codex_working_rules.md`、`tools/codex/README.md`、smoke harness / tests を同じ change set で更新すること。
- docs だけを変更する場合も、checked-in behavior と矛盾しないこと。
