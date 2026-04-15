# AGENTS.md

このリポジトリで Codex / 自動化フローが最初に従うべきルールを定義します。

## 優先順位

1. `docs/consumer-contract.md`
2. `docs/README.md` から辿る source-of-truth docs
3. `README.md`
4. GitHub issue 本文と `.work/` artifacts

概要説明と契約が食い違う場合は、`docs/consumer-contract.md` を正とします。

## この repo の位置づけ

- この repo は `issue_forge` の shared engine であると同時に、v1 contract の first consumer です。
- consumer-owned artifacts はこの repo 自身が持ちます。少なくとも `AGENTS.md`、`docs/README.md`、`tools/checks/run_changed.sh`、`.issue_forge/project.sh`、`tools/codex/prompts/*.tmpl` は checked-in の実体を保ちます。
- `tools/codex/` と `tools/issue/` の stable entrypoint path は consumer contract の一部です。互換性を壊す rename や relocation は、contract と smoke coverage を同時に更新する場合を除いて禁止です。

## 実装ルール

- まず既存の shell helper を再利用し、ロジックの重複を増やさないこと。
- shell ベースのアーキテクチャを維持し、サービス化・デーモン化・別言語への全面移植はしないこと。
- 変更は issue scope に限定し、最小差分で行うこと。
- fallback や互換レイヤーは原則追加しないこと。
- 異常系は握りつぶさず、根本原因が分かる具体的なメッセージで即時失敗すること。
- `.work/` レイアウト、history 命名、branch 命名、review 出力フォーマットは contract を更新しない限り維持すること。
- issue の要求が docs と衝突する場合は docs を優先すること。

## チェックとレビュー

- 実装を終えたら、consumer checks hook と smoke harness で checked-in behavior を検証すること。
- `tools/checks/run_changed.sh` は validation only とし、tracked file を自動修正しないこと。
- review session は read-only です。コードやワークツリーを変更してはいけません。
- レビューや確認では、省略記号でごまかさず checked-in の正確なコードを基準に判断すること。

## ドキュメント更新ルール

- runtime behavior を変えた場合は、必要に応じて `README.md`、`docs/README.md`、`docs/consumer-contract.md`、`tools/codex/README.md`、smoke harness / tests を同じ change set で更新すること。
- docs だけを変更する場合も、checked-in behavior と矛盾しないこと。

