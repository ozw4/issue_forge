# Codex Working Rules

`issue_forge` を変更するときの具体的な作業ルールです。

## 1. Stable contract を先に守る

次は contract surface なので、理由なく変えません。

- external consumer entrypoints:
  - `vendor/issue_forge/tools/consumer/init.sh`
  - `vendor/issue_forge/tools/issue/start_from_issue.sh`
  - `vendor/issue_forge/tools/codex/doctor.sh`
  - `vendor/issue_forge/tools/codex/run_issue_flow.sh`
  - `vendor/issue_forge/tools/codex/run_issue_queue.sh`
  - `vendor/issue_forge/tools/codex/restart_issue_flow.sh`
  - `vendor/issue_forge/tools/codex/continue_after_review.sh`
  - `vendor/issue_forge/tools/codex/make_pr_only.sh`
  - `vendor/issue_forge/tools/codex/run_codex.sh`
- `.work/` 配下の path と file name
- review output format
- issue branch naming rule
- PR body format と、既存 open PR の title/body のみを同期する publish behavior

この repo 自身の `tools/codex/*.sh` と `tools/issue/start_from_issue.sh` は self-hosting 用 checked-in entrypoint です。external consumer contract では必須ではありません。

## 2. Engine と consumer の境界を崩さない

engine 側に置くもの:

- reusable shell libraries
- issue bootstrap / state / publish / review orchestration
- default prompt templates
- direct vendor entrypoints
- generic smoke behavior

consumer 側に残すもの:

- `.issue_forge/project.sh`
- `.issue_forge/checks/run_changed.sh`
- `AGENTS.md`
- `README.md`
- optional `docs/README.md`
- optional custom prompt templates

repo 固有のルールや docs を engine 側の暗黙知に押し込まないでください。

## 3. Root 解決のルール

- `ISSUE_FORGE_ENGINE_ROOT` は実行された engine 側の root です。bind mount / symlink の logical path を保ちます。
- `CODEX_FLOW_REPO_ROOT` は consumer repo root です。
- engine root と consumer root は別扱いにし、`pwd -P` や `realpath` で vendor path を潰さないでください。
- `ISSUE_FORGE_CONSUMER_ROOT` のような明示設定が不正な場合は即時失敗させ、黙って別候補へ fall back しないでください。

## 4. Prompt と docs の扱い

- prompt templates の default は `vendor/issue_forge/tools/codex/prompts/` です。
- consumer-specific prompts は optional で、必要な場合のみ `CODEX_FLOW_PROMPTS_DIR` で override します。
- consumer docs の primary entrypoint は `README.md` です。`docs/README.md` は追加 docs がある場合だけ optional とします。
- docs を追加したら `docs/README.md` に読む順番を反映してください。
- docs の wording を変えるだけでも、runtime behavior と矛盾していないか確認してください。

## 5. Shell 実装のルール

- 既存 helper があるなら再利用し、同等ロジックの再実装を避けます。
- エラーは早く、具体的に失敗させます。
- 想定可能な異常は明示的に検証し、無言フォールバックは入れません。
- path、prompt file、history file の命名は文字列契約として扱います。

## 6. Checks hook のルール

- default checks hook は `./.issue_forge/checks/run_changed.sh` です。
- checks hook は non-interactive です。
- base ref を 1 つ受け取ります。
- tracked file を自動修正しません。
- この repo の self-hosting checks は `tools/checks/run_changed.sh` に残しますが、external consumer contract では必須 path ではありません。

## 7. PR publish のルール

- PR body は shell helper で deterministic に生成し、AI 生成文は使いません。
- body は `Closes #<issue>`、`## Summary`、`## Changed files`、`## Checks`、`## Review` を含みます。
- Summary と checks の最終行は byte truncate せず、そのまま出力して UTF-8 を壊さないようにします。
- changed files は `.work/base_commit` の fixed base と issue branch の差分から取り、uncommitted worktree-only state は含めません。
- checks/review artifact が無い `make_pr_only.sh` 経路では失敗させず、body に `not available yet` を明示します。
- 既存 open PR がある場合は `gh pr edit ... --title ... --body-file ...` で title/body だけ同期し、draft/open state、reviewers、labels は触りません。
- 新規 PR 作成時は `CODEX_FLOW_PR_DRAFT_DEFAULT` を維持します。

## 7.1 Issue queue のルール

- `run_issue_queue.sh <issue_number> [issue_number ...]` は明示 issue list だけを受け付け、`.work/current_issue` に fallback しません。
- issue number は入力順のまま strict serial に処理し、sort / dedupe / parallelism は入れません。
- 各 issue の開始前に `.work/codex` を削除し、既存の `start_from_issue.sh <issue>` と `run_issue_flow.sh <issue>` に処理を委譲します。
- queue 用の `.work` state、resume file、config toggle は追加しません。完了後の single-issue state は最後の issue を指します。
- merge automation、approval automation、auto-merge、PR polling、wait loop は queue runner に入れません。

## 8. Git hygiene と worktree exclusion

- flow は `.work/` を明示的に除外し、`.gitignore` に依存しません。
- engine が consumer repo 内の `vendor/issue_forge` にある場合、通常の `git status`、`git diff`、staging path discovery、review material ではその path だけを明示的に除外します。
- staging では、excluded pathspec 付きの `git diff --name-only` / `git ls-files --others` で concrete path を集め、その concrete path だけを `git add --pathspec-from-file` に渡します。`:(exclude)...` を `git add` に直接渡してはいけません。
- `git clean` では `vendor/issue_forge` を専用保護しつつ、consumer-owned な他の `vendor/` 配下ファイルは保護しません。
- positive pathspec `.` を先に置き、その後に `:(exclude)...` を並べる current contract を守ってください。

## 9. Smoke harness のルール

- fixture は checked-in contract を検証するためのものです。
- fixture consumer は minimal files だけを持ちます。
- `vendor/issue_forge` は baseline commit の後に symlink で作り、未追跡 path のまま exclusion を検証します。
- fixture consumer に `tools/codex` や `tools/issue` を捏造しないでください。
- 可能な限り checked-in の `tools/checks/run_changed.sh` を `.issue_forge/checks/run_changed.sh` としてコピーして使います。
- PR create path と existing PR update path の body 内容を検証し、missing artifact と checks/review artifact ありの両方を coverage に含めます。
- queue scenario は direct vendor path の `./vendor/issue_forge/tools/codex/run_issue_queue.sh <issue1> <issue2>` を実行し、入力順、両 issue の bootstrap、2 回の PR create、最後の single-issue state、`.work/codex` の stale artifact 削除、既存 flow 経由の push / PR create を検証します。
