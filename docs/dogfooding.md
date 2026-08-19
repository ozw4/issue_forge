# Live dogfooding runbook

この runbook は、`issue_forge` 自身を self-hosting consumer として、実際の GitHub Issue から draft PR 作成まで動かす手順です。この repository では checked-in の `./tools/issue/...` と `./tools/codex/...` を使います。external consumer 用の `./vendor/issue_forge/...` entrypoint は使いません。

通常 flow は Codex を実行し、commit、branch push、GitHub PR 作成まで行います。default sandbox は `danger-full-access` です。dogfooding 用の Issue と repository への push 権限を用意し、security policy を確認してから実行してください。この手順は auto-merge を有効にしません。

## 1. Fresh clone を準備する

通常 Issue flow に必要な command に加えて、self-hosting verification 用の Python と `pytest` を用意します。必要な command の一覧は [README.md](../README.md#requirements) を参照してください。VS Code Dev Container を使う場合、repository の設定が必要な tools と `pytest` を準備します。

作業中の clone と state を共有しないよう、dogfooding 専用の fresh clone を作成します。

```bash
git clone https://github.com/ozw4/issue_forge.git issue_forge-dogfood
cd issue_forge-dogfood

gh auth status
git status --short
./tools/codex/doctor.sh
```

`gh auth status` と `doctor.sh` が成功し、`git status --short` が何も出力しないことを確認します。clone 先の `origin` が dogfooding 対象 repository を指していることも確認します。

```bash
git remote get-url origin
```

## 2. Baseline regression を確認する

live flow の前に、fresh clone の checked-in behavior を確認します。

```bash
./tools/checks/run_changed.sh origin/main
./tools/codex/smoke_harness.sh
python -m pytest -q
```

すべて exit status 0 で完了することを確認します。`run_changed.sh` は fresh clone に変更がなければ `No changes detected` と表示します。smoke harness は外部 GitHub/Codex services を呼ばず、fixture 内で shell contract を検証します。

## 3. Single-Issue flow を実行する

実装 scope が明確で、まだ対応 branch や open PR がない open Issue を 1 件選びます。以下では `123` を実際の Issue number に置き換えます。

```bash
DOGFOOD_ISSUE=123
gh issue view "$DOGFOOD_ISSUE"
./tools/issue/start_from_issue.sh "$DOGFOOD_ISSUE"
```

bootstrap 後の branch と Issue state を確認します。

```bash
DOGFOOD_BRANCH="$(git branch --show-current)"
printf 'branch: %s\n' "$DOGFOOD_BRANCH"
cat .work/current_issue
cat .work/current_branch
gh pr list --state open --head "$DOGFOOD_BRANCH" --json number,url,isDraft
```

branch が `issue/<issue_number>-<slug>` で、`.work/current_issue` と `.work/current_branch` が選択した Issue と現在 branch を示すことを確認します。`gh pr list` は `[]` である必要があります。既存 open PR がある場合、flow はその PR の title/body だけを同期し、draft/open state は変更しません。その場合はこの新規 draft PR 試験を続けず、競合しない Issue と fresh clone を用意します。

single-Issue flow を実行します。

```bash
./tools/codex/run_issue_flow.sh "$DOGFOOD_ISSUE"
```

flow は implementation、consumer-owned checks、structured review と必要な修正 loop、commit、push、PR publish を順番に実行します。途中で失敗した場合は出力された根本原因を解消し、成功したものとして手動で commit や PR を作らず、表示された state と repository の recovery entrypoint を確認します。

## 4. Draft PR と artifacts を確認する

flow 完了後、worktree と作成された PR を確認します。

```bash
git status --short
git log -1 --oneline
gh pr view "$DOGFOOD_BRANCH" \
  --json number,url,title,state,isDraft,headRefName,baseRefName
gh pr view "$DOGFOOD_BRANCH" --json body --jq .body
```

次を確認します。

- `git status --short` に tracked/untracked の実装残りがない
- latest commit が `chore: address issue #<issue_number>` である
- PR の `state` が `OPEN`、`isDraft` が `true` である
- `headRefName` が dogfooding branch、`baseRefName` が `main` である
- PR body に `Closes #<issue_number>`、Summary、Changed files、Checks、Review がある

checks と review のローカル artifact も確認できます。

```bash
tail -n 20 .work/codex/checks.log
cat .work/codex/review.txt
```

ブラウザで draft PR 全体を確認する場合は次を実行します。

```bash
gh pr view "$DOGFOOD_BRANCH" --web
```

draft の解除、merge、close、branch delete はこの runbook の範囲外です。必要な後続操作は通常の repository review process に従って手動で行います。
