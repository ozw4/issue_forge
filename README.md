# issue_forge

`issue_forge` は、GitHub Issue を起点に実装・checks・review・PR 作成までを回す shell-based engine です。

external consumer は engine を `vendor/issue_forge` に bind mount または symlink し、その path を直接呼びます。consumer repo に `./tools/codex/*.sh` や `./tools/issue/*.sh` の wrapper は不要です。

詳細な contract は [docs/consumer-contract.md](docs/consumer-contract.md) を参照してください。

## First-time setup

consumer repo では最初に次を実行できます。

```bash
./vendor/issue_forge/tools/consumer/init.sh
```

この init script は consumer の `.gitignore` に `.work`、`.work/`、`vendor/issue_forge`、`vendor/issue_forge/` を追記し、`.issue_forge/project.sh` が無ければ作成します。`.issue_forge/checks/run_changed.sh` と `README.md` が無い場合は warning を出します。`README.md` と `docs/README.md` は作成せず、`docs/README.md` が無くても warning は出しません。`git add` や commit もしません。

## Consumer layout

`README.md` は consumer docs の primary entrypoint です。`docs/README.md` は追加の docs index が必要な場合だけ optional です。

基本的な consumer-owned layout は次です。

```text
<consumer-repo>/
├─ .issue_forge/
│  ├─ project.sh
│  └─ checks/
│     └─ run_changed.sh
├─ AGENTS.md
├─ README.md
├─ docs/
│  └─ README.md
└─ vendor/
   └─ issue_forge -> bind mount or symlink
```

`vendor/issue_forge` は consumer repo に commit しない前提です。

## Direct entrypoints

consumer repo root から次を直接実行します。

```bash
./vendor/issue_forge/tools/consumer/init.sh
./vendor/issue_forge/tools/issue/start_from_issue.sh 123
./vendor/issue_forge/tools/codex/doctor.sh
./vendor/issue_forge/tools/codex/run_issue_flow.sh 123
./vendor/issue_forge/tools/codex/continue_after_review.sh 123
./vendor/issue_forge/tools/codex/restart_issue_flow.sh --hard 123
./vendor/issue_forge/tools/codex/make_pr_only.sh 123
./vendor/issue_forge/tools/codex/run_codex.sh write .work/codex/implementation.prompt.md
```

`.work/current_issue` がある場合は issue number を省略できます。

## PR publishing

`run_issue_flow.sh` と `make_pr_only.sh` は同じ publish helper を使い、PR body を deterministic に自動生成します。body は local issue context、saved fixed base commit、git diff、`.work/codex/checks.log`、`.work/codex/review.txt` から組み立てられます。

生成される body は次の安定した形です。

```text
Closes #<issue>

## Summary
- <issue title>

## Changed files
- `<path>`

## Checks
- `.work/codex/checks.log`: <last non-empty line>

## Review
- `.work/codex/review.txt`: accept: yes/no
- findings: blocker <n>, major <n>, minor <n>
```

checks/review artifact がまだ無い `make_pr_only.sh` 経路では、その section に `not available yet` を出します。既存の open PR がある場合は `gh pr edit ... --title ... --body-file ...` で title/body だけを同期し、draft/open state、reviewers、labels は変更しません。新規 PR 作成時は従来どおり `CODEX_FLOW_PR_DRAFT_DEFAULT` を守ります。

## Defaults

consumer の `.issue_forge/project.sh` は空でも構いません。default は engine 側で補完されます。

| Setting | Default |
| --- | --- |
| `CODEX_FLOW_BASE_BRANCH` | `main` |
| `CODEX_FLOW_BASE_REF` | `origin/${CODEX_FLOW_BASE_BRANCH}` |
| `CODEX_FLOW_BRANCH_PREFIX` | `issue/` |
| `CODEX_FLOW_CHECKS_COMMAND` | `./.issue_forge/checks/run_changed.sh` |
| `CODEX_FLOW_PROMPTS_DIR` | `${ISSUE_FORGE_ENGINE_ROOT}/tools/codex/prompts` |
| `CODEX_FLOW_PR_DRAFT_DEFAULT` | `1` |
| `CODEX_FLOW_PROFILE_WRITE_SANDBOX` | `danger-full-access` |
| `CODEX_FLOW_PROFILE_WRITE_REASONING` | `xhigh` |
| `CODEX_FLOW_PROFILE_READ_SANDBOX` | `danger-full-access` |
| `CODEX_FLOW_PROFILE_READ_REASONING` | `medium` |

consumer-specific prompts を使いたい場合だけ `CODEX_FLOW_PROMPTS_DIR` を override します。

## Stable invariants

次は current contract です。

- `.work/` layout
- `.work/codex/*` filenames
- history naming
- issue branch naming `issue/<number>-<slug>`
- review output format
- GitHub issue / PR behavior

`accept: yes` は `blocker:` と `major:` に実 finding が無いことを意味します。`minor:` は残り得ます。

## Git hygiene

consumer repo では次を ignore する運用を推奨します。

```gitignore
.work
.work/
vendor/issue_forge
vendor/issue_forge/
```

ただし flow 自体は `.gitignore` に依存せず、`.work` と consumer repo 内の `vendor/issue_forge` を明示的に保護します。consumer-owned な他の `vendor/` 配下ファイルは `git status`、`git diff`、`git add`、review material に見える必要があります。

## Required commands

次の command が必要です。

- `bash`
- `git`
- `gh`
- `codex`
- `shellcheck`
- `awk`
- `sed`
- `tr`
- `cut`
- `mktemp`

## Self-hosting

この repo 自体は engine 開発と regression coverage のために self-hosting します。そのため次も引き続き有効です。

```bash
./tools/codex/doctor.sh
./tools/codex/smoke_harness.sh
python -m pytest -q
```

この repo の `.issue_forge/project.sh` は self-hosted values を明示的に持ち続けます。

- `CODEX_FLOW_CHECKS_COMMAND='./tools/checks/run_changed.sh'`
- `CODEX_FLOW_PROMPTS_DIR='tools/codex/prompts'`

external consumer はこれらを書かなくても動くのが contract です。
