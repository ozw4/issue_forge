# issue_forge

`issue_forge` は、GitHub Issue を起点に実装・チェック・レビュー・PR 作成までを回す、シェルベースの共有エンジンです。

このリポジトリは **engine 本体** を提供し、各 consumer repo は自分のポリシーや prompt、checks を持ったまま、安定した wrapper パス経由でこの engine を利用します。

現在の v1 方針は次の通りです。

- shell 実装を維持する
- `.work/` レイアウトを維持する
- consumer 側の stable entrypoint を維持する
- repo 固有の prompt / docs / checks / project policy は consumer 側に残す

詳細な契約は [docs/consumer-contract.md](docs/consumer-contract.md) を参照してください。

## できること

- GitHub Issue から作業 branch を作成する
- issue 内容を `.work/` に保存する
- Codex を `write` / `read` モードで起動する
- 実装 → checks → fix loop を回す
- review → fix loop を回す
- commit / push / draft PR 作成まで進める
- consumer contract を smoke harness で退行検知する

## 全体像

`issue_forge` は engine と consumer の責務を分けています。

### engine 側で持つもの

- issue bootstrap
- flow state 管理
- prompt rendering
- Codex 実行 wrapper
- checks / review orchestration
- publish / PR helpers
- smoke harness

### consumer 側で持つもの

- `.issue_forge/project.sh`
- `tools/codex/prompts/*.prompt.md.tmpl`
- `AGENTS.md`
- `docs/README.md`
- repo 固有 checks コマンド
- stable wrapper パス

## 導入方法

consumer repo に `vendor/issue_forge` として配置します。

```text
<consumer-repo>/
├─ .issue_forge/
│  └─ project.sh
├─ AGENTS.md
├─ docs/
│  └─ README.md
├─ tools/
│  ├─ checks/
│  │  └─ run_changed.sh
│  ├─ codex/
│  │  ├─ run_issue_flow.sh
│  │  ├─ restart_issue_flow.sh
│  │  ├─ continue_after_review.sh
│  │  ├─ make_pr_only.sh
│  │  ├─ run_codex.sh
│  │  └─ prompts/
│  │     ├─ implementation.prompt.md.tmpl
│  │     ├─ fix-from-checks.prompt.md.tmpl
│  │     ├─ review.prompt.md.tmpl
│  │     └─ fix-from-review.prompt.md.tmpl
│  └─ issue/
│     └─ start_from_issue.sh
└─ vendor/
   └─ issue_forge/
```

consumer 側 wrapper は薄い shim とし、実体は `vendor/issue_forge` を呼び出します。

## 必要コマンド

次のコマンドが必要です。

- `bash`
- `git`
- `gh`
- `codex`
- `awk`
- `sed`
- `tr`
- `cut`
- `mktemp`

加えて、通常は次も前提です。

- `gh auth` が済んでいる
- `origin` remote がある
- base ref が解決できる
- 実行対象が Git repo である

## consumer 側の必須ファイル

### 1. `.issue_forge/project.sh`

project policy と runtime 設定です。例:

- `CODEX_FLOW_BASE_REF` は issue branch bootstrap 時に解決する source ref です。
- checks / review / rerun は runtime に保存した fixed base commit を使います。

```bash
CODEX_FLOW_BASE_REF='origin/main'
CODEX_FLOW_BASE_BRANCH='main'
CODEX_FLOW_BRANCH_PREFIX='issue/'
CODEX_FLOW_CHECKS_COMMAND='./tools/checks/run_changed.sh'
CODEX_FLOW_PROMPTS_DIR='tools/codex/prompts'
CODEX_FLOW_PR_DRAFT_DEFAULT=1

CODEX_FLOW_PROFILE_WRITE_SANDBOX='danger-full-access'
CODEX_FLOW_PROFILE_WRITE_REASONING='xhigh'
CODEX_FLOW_PROFILE_READ_SANDBOX='danger-full-access'
CODEX_FLOW_PROFILE_READ_REASONING='medium'
```

### 2. Prompt templates

以下の 4 ファイルが必要です。

- `tools/codex/prompts/implementation.prompt.md.tmpl`
- `tools/codex/prompts/fix-from-checks.prompt.md.tmpl`
- `tools/codex/prompts/review.prompt.md.tmpl`
- `tools/codex/prompts/fix-from-review.prompt.md.tmpl`

prompt templates は consumer-owned artifact ですが、この repo の current preserved path contract は `tools/codex/prompts/` です。`.issue_forge/prompts/` は current path ではありません。

### 3. Repository docs

最低限、次が参照される前提です。

- `AGENTS.md`
- `docs/README.md`

### 4. Checks hook

consumer repo は checks hook を提供します。

- path: `./tools/checks/run_changed.sh`
- invocation: `./tools/checks/run_changed.sh <fixed_base_commit>`
- exit code `0`: pass
- non-zero: fail → fix-from-checks loop に入る

## 基本フロー

通常の入口は consumer 側 wrapper です。

### 1. issue から branch を作る

```bash
./tools/issue/start_from_issue.sh 123
```

この処理で行うこと:

- `gh issue view` で issue を読む
- branch 名を生成する
- issue branch を作る
- branch 作成時点の fixed base commit を `.work/base_commit` に書く
- `.work/current_issue` を書く
- `.work/current_branch` を書く
- `.work/issues/123.md` を書く

### 2. 実装から PR まで流す

```bash
./tools/codex/run_issue_flow.sh 123
```

すでに `.work/current_issue` がある場合は省略可能です。

```bash
./tools/codex/run_issue_flow.sh
```

この flow は大まかに次を実施します。

1. implementation prompt を生成
2. `run_codex.sh write` で実装
3. checks を実行
4. 失敗時は fix-from-checks を回す
5. review prompt を生成
6. `run_codex.sh read` で review
7. accept されなければ fix-from-review を回す
   `accept: yes` は `blocker:` と `major:` が空であることを意味し、`minor:` は残りうる
8. commit
9. push
10. draft PR を作成

### 3. review 修正後に続ける

```bash
./tools/codex/continue_after_review.sh 123
```

または `.work/current_issue` があれば:

```bash
./tools/codex/continue_after_review.sh
```

### 4. やり直す

```bash
./tools/codex/restart_issue_flow.sh 123
```

破壊的にやり直すなら:

```bash
./tools/codex/restart_issue_flow.sh --hard 123
```

### 5. PR だけ作る

```bash
./tools/codex/make_pr_only.sh 123
```

## `run_codex.sh` の使い方

通常は `run_issue_flow.sh` から呼ばれますが、単体でも使えます。

```bash
./tools/codex/run_codex.sh write .work/codex/implementation.prompt.md
./tools/codex/run_codex.sh read .work/codex/review.prompt.md
```

- `write`: 実装用 profile
- `read`: review 用 profile

`codex exec` には sandbox と reasoning 設定が渡されます。

また、一時的な provider capacity エラーに対して retry します。

### retry 設定

環境変数で上書きできます。

- `CODEX_TRANSIENT_MAX_RETRIES` デフォルト: `5`
- `CODEX_TRANSIENT_INITIAL_DELAY_SEC` デフォルト: `5`

例:

```bash
CODEX_TRANSIENT_MAX_RETRIES=2 CODEX_TRANSIENT_INITIAL_DELAY_SEC=3 \
  ./tools/codex/run_codex.sh write .work/codex/implementation.prompt.md
```

## `.work/` に作られる主なファイル

`issue_forge` は `.work/` を state と artifact の保存先に使います。
consumer repo では `.work/` を `.gitignore` に入れるのを推奨しますが、publish staging は `.gitignore` に依存せず `.work/` を明示除外します。

### issue state

- `.work/base_commit`
- `.work/current_issue`
- `.work/current_branch`
- `.work/issues/<issue>.md`

### codex artifacts

- `.work/codex/implementation.prompt.md`
- `.work/codex/fix-from-checks.prompt.md`
- `.work/codex/review.prompt.md`
- `.work/codex/fix-from-review.prompt.md`
- `.work/codex/checks.log`
- `.work/codex/implementation.log`
- `.work/codex/review.diff`
- `.work/codex/review.untracked.txt`
- `.work/codex/review.raw.txt`
- `.work/codex/review.txt`
- `.work/codex/fix-from-review.log`
- `.work/codex/history/*`

### 命名ルール

history artifact は次の形式です。

```text
.work/codex/history/<stem>.round-<NN>.<ext>
```

例:

- `implementation.round-00.log`
- `checks.round-01.log`
- `review.round-01.txt`

## 入口スクリプト一覧

### `tools/issue/start_from_issue.sh`

```bash
./tools/issue/start_from_issue.sh <issue_number>
```

issue bootstrap と branch 作成を行います。

### `tools/codex/run_issue_flow.sh`

```bash
./tools/codex/run_issue_flow.sh [issue_number]
```

main flow です。

### `tools/codex/restart_issue_flow.sh`

```bash
./tools/codex/restart_issue_flow.sh [--hard] [issue_number]
```

`.work/codex` を消して flow をやり直します。

### `tools/codex/continue_after_review.sh`

```bash
./tools/codex/continue_after_review.sh [issue_number]
```

review 指摘を手で直した後に flow を再開します。

### `tools/codex/make_pr_only.sh`

```bash
./tools/codex/make_pr_only.sh [issue_number]
```

現在 branch の PR を作成または取得します。

## smoke harness

consumer contract の退行確認には smoke harness を使います。

```bash
./tools/codex/smoke_harness.sh
```

この harness は次を行います。

- 一時 git fixture を作る
- `gh` / `codex` を stub する
- flow をオフラインで検証する
- `.work` 生成物と履歴命名を検証する
- wrapper から shared engine が正しく呼ばれているか検証する

テストからは次で呼ばれます。

```bash
pytest -q tests/test_codex_smoke_harness.py
```

## よくあるエラー

### `Failed to resolve consumer repo root for issue_forge runtime`

原因:

- `vendor/issue_forge` の配置が想定と違う
- 実行位置が consumer repo 配下ではない
- consumer repo に `.issue_forge/project.sh` がない

対処:

- `vendor/issue_forge` が consumer repo の直下 `vendor/` にあることを確認
- consumer repo root に `.issue_forge/project.sh` があることを確認

### `Missing required command: codex`

原因:

- `codex` が PATH にない

対処:

- CLI を導入する
- PATH を確認する

### `Working tree must be clean before starting an issue branch`

原因:

- `.work/` 以外に未コミット変更がある

対処:

- commit / stash / discard してから再実行する

### `Missing review file: .work/codex/review.txt`

原因:

- review phase がまだ完了していない
- `.work/codex` を消した

対処:

- `run_issue_flow.sh` を先に完了させる
- 必要なら `restart_issue_flow.sh` でやり直す

## 開発メモ

この repo 自体も consumer として動作できるように最小構成を持っています。

- `.issue_forge/project.sh`
- `tools/codex/prompts/`
- `tools/checks/run_changed.sh`
- `tools/codex/smoke_harness.sh`
- `tests/test_codex_smoke_harness.py`

そのため、engine 単体の変更でも smoke harness で挙動確認できます。

## 参考

- consumer contract: [docs/consumer-contract.md](docs/consumer-contract.md)
- smoke harness 説明: [tools/codex/README.md](tools/codex/README.md)
