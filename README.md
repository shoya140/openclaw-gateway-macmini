# OpenClaw Gateway on Mac Mini

Mac Mini に OpenClaw をインストールし、Telegram から利用するためのセットアップスクリプト + 運用マニュアル。

## 概要

```
[Telegram official Bot] ─┐
                         ├─> [OpenClaw Gateway (localhost:18789)] ─┬─> [Anthropic API]      (official-agent)
[Telegram personal Bot] ─┘             ↑                          └─> [LM Studio 127.0.0.1] (personal-agent)
                            [Tailscale Serve (tailnet 内のみアクセス可)]
```

- 1 gateway で 2 つの Telegram Bot を運用。`channels.telegram.accounts.{official,personal}` + top-level `bindings[]` で account → agent をルーティング
- 各 agent ごとに別モデル (official=Claude Opus 4.7、personal=LM Studio 上のローカル LLM)
- Gateway は Mac Mini 上で loopback bind。外部アクセスは Tailscale Serve 経由（tailnet 内のみ）。パブリックポート開放なし
- OpenClaw は専用の標準（非管理者）アカウント `claw` で実行。`sudo` / `brew` は OS レベルで使えないため、claw が乗っ取られても admin への昇格経路がない
- LM Studio は admin (= `01-admin-macos-setup.sh` を実行したユーザー) として LaunchDaemon で常駐。モデル本体は admin の `~/.lmstudio/` 配下に保存
- ワークスペースは Google Drive 共有フォルダにあり、個人 PC と同期される。git 管理は個人 PC 側で行う

`exec.security: full` + `tools.deny: []` + `execApprovals: off` で「ユーザー権限内のあらゆる操作を承認なしに自走」する設計。`gateway` / `cron` / `sessions_spawn` ツールも開放されているため、エージェント自身が `openclaw.json` を書き換えたり、永続化スケジュールを作ったり、サブエージェントを spawn できる。`claw` 専用標準アカウントによる OS 分離（sudo/brew 不可、admin・他ユーザーのファイル不可視）が最後の砦。

設定では防げない領域は別レイヤーで補う:
- **Anthropic console で月額 spend cap** を設定（API キー流出 or runaway loop 時の被害金額を有限化）
- **Tailscale ACL** で Mac Mini ノードから他 tailnet ノードへの egress を制限

---

## 準備物

- Mac Mini（Apple Silicon 推奨）+ macOS 15 以降
- インターネット接続
- 管理者アカウントに Homebrew インストール済み
- Telegram アカウント + BotFather で作成した **2 つの Bot Token**（official 用 / personal 用）+ 自分の User ID（`@userinfobot` で確認）
- LLM API キー（Anthropic 等）
- LM Studio 本体・LaunchDaemon・モデル取得は全て `01-admin-macos-setup.sh` が実行する。daemon の `UserName` には 01 を実行したユーザー (admin 権限) を流し込む。既定モデルは `unsloth/qwen3.6-35b-a3b-ud-mlx` で、`<repo>/.env` の `LMSTUDIO_MODEL` で変更可
- OpenClaw 専用 Google アカウント
- 個人の Google Drive で `openclaw-workspace` フォルダを作成し、専用 Google アカウントを「編集者」として共有済み

---

## クイックスタート

```bash
# 1. 管理者アカウントで実行
./scripts/01-admin-macos-setup.sh

# 2. Screen Sharing で claw アカウントにログインし、claw で実行
./scripts/02-claw-user-setup.sh

# 3. 引き続き claw で実行
./scripts/03-openclaw-setup.sh
```

2回目以降の実行は既存の `~/.openclaw` を自動的に `~/.openclaw-snapshot-<ts>/` にバックアップしてからクリーン状態で再構築します。同時に workspace と cron を snapshot から復元したい場合は `./scripts/03-openclaw-setup.sh --recover` を指定してください（最新 snapshot を自動選択）。特定の snapshot から復元する場合は `--recover ~/.openclaw-snapshot-<ts>` のようにパスを渡します。詳細は [バックアップ / リストア](#バックアップ--リストア) 参照。

### `.env` で対話入力をスキップ

何度もセットアップを再実行する場合、プロジェクトルート（このリポジトリの直下）に `.env` を置いておくと、`03-openclaw-setup.sh` が読み込んで対話入力を省略します（`LMSTUDIO_MODEL` は `01-admin-macos-setup.sh` も読み込んで `lms get` の対象に使う）。`.env` は `.gitignore` 済みでコミットされません。

```dotenv
# <repo>/.env  (chmod 600 推奨)
TELEGRAM_OFFICIAL_BOT_TOKEN="..."
TELEGRAM_PERSONAL_BOT_TOKEN="..."
TELEGRAM_USER_ID="..."
ANTHROPIC_API_KEY="sk-ant-..."
LMSTUDIO_API_KEY="lm-studio"                    # 省略可。未指定時は "lm-studio" (LM Studio はローカルなので marker)
LMSTUDIO_MODEL="unsloth/qwen3.6-35b-a3b-ud-mlx" # 省略可。01 の lms get + 03 の personal-agent.model に反映
```

- セットされている項目だけスキップされ、未設定の項目は従来通り対話入力されます
- シェルから `export` した環境変数（`ANTHROPIC_API_KEY=... ./scripts/03-...`）も同様に優先されます
- Telegram Bot Token は最終的に `~/.openclaw/credentials/telegram/{official,personal}.token` (chmod 600) に書き込まれ、`ANTHROPIC_API_KEY` / `LMSTUDIO_API_KEY` は `~/.openclaw/.env` (chmod 600) に書き込まれます

---

## 各スクリプトが行うこと

### `01-admin-macos-setup.sh`（管理者アカウント）

- ファイアウォール + ステルスモード有効化
- 24/7 運用向け `pmset`（スリープ無効、再起動後の自動復帰）
- 自動ログイン無効化、Screen Sharing 有効化、SSH 有効化
- Tailscale インストール・認証 + `tailscale serve --bg http://127.0.0.1:18789`
- LM Studio (llmster) インストール + `/Library/LaunchDaemons/io.shoya.lmstudio.plist` 配置 + モデル取得
  - `curl -fsSL https://lmstudio.ai/install.sh | bash -s -- --no-modify-path` で `~/.lmstudio/bin/lms` を配置
  - LaunchDaemon は `UserName` = 01 を実行したユーザー (admin 権限) で起動。モデル置き場は admin の `~/.lmstudio/`
  - 起動コマンド: `lms daemon up && lms server start --port 1234`（OpenAI 互換 API が `http://127.0.0.1:1234/v1` で listening）
  - admin の `~/.lmstudio/` を Spotlight + Time Machine から除外（モデル blob のインデックス防止）
  - daemon の起動を待ったうえで `lms get "${LMSTUDIO_MODEL:-unsloth/qwen3.6-35b-a3b-ud-mlx}"` を実行（`<repo>/.env` の `LMSTUDIO_MODEL` を読み込み済みならその値）
  - 旧 Ollama 構成 (`io.shoya.ollama.plist` / `io.shoya.ollama-preload.plist`) があれば自動で bootout + 削除
  - JIT loading に任せるため起動時 preload はしない（初回呼び出し時にメモリへロード）
- `claw` 標準アカウント作成（パスワード対話入力）
- Google Drive for Desktop インストール

> **手動確認が必要**:
> - Screen Sharing の VNC パスワードアクセスが無効であること（Tailscale 経由のみ使用）
> - 再起動後に Tailscale が自動接続されること（`tailscale status`）
>
> **FileVault は無効のまま**。有効にするとコールドブート時にリモート復旧ができなくなるため。

### `02-claw-user-setup.sh`（`claw` アカウント）

Screen Sharing 等で claw にログインしてから実行する。

- Google Drive セットアップ（[手順は下記](#google-drive-セットアップ)）
- mise インストール + シェル統合
- Node.js インストール（`mise use -g node@24`）
- sudo / brew が claw から使えないことの自動検証

#### Google Drive セットアップ

`02-claw-user-setup.sh` 実行中に Google Drive が起動するので、以下の GUI 操作を行ってから Enter を押す:

1. Open Claw 専用 Google アカウントでサインイン
2. 同期モードを「ミラーリング」に設定（Google Drive メニュー → 設定 → Google Drive → ミラーリング）
3. 個人が共有した `openclaw-workspace` フォルダを My Drive に追加（右クリック → 整理 → ショートカットを追加 → マイドライブ）

### `03-openclaw-setup.sh`（`claw` アカウント）

対話で **2 つの Telegram Bot Token (official / personal)** / User ID / Anthropic API Key を入力する（プロジェクト直下の `.env` に値があればその項目はスキップ）。

- OpenClaw インストール（`npm install -g openclaw@latest`）
- **Telegram 拡張 peer deps の手動 install**: `grammy` / `@grammyjs/runner` / `@grammyjs/transformer-throttler` を `$(npm root -g)/openclaw` 配下に `--no-save` で install。OpenClaw の `dist/` がこれらを require するが `package.json` に未宣言で、`npm install -g openclaw@latest` のたびに消えるため毎回再 install（上流 packaging bug。openclaw/openclaw#59867, #60263, #60309, #62425, #63103, #70615 等）。上流が修正したら 03 の `install_telegram_peer_deps` 関数は不要になる
- Google Drive 内の `openclaw-workspace` を自動検出し、`~/.openclaw/workspace` にシンボリックリンクを作成
- ワークスペースに `AGENTS.md`（mise で CLI tool を自分で導入するルール、sudo/brew が必要な作業はユーザーへ依頼するルール）を配置
- 入力された 2 つの Bot Token を `~/.openclaw/credentials/telegram/{official,personal}.token` (chmod 600) に書き込み（OpenClaw の `tokenFile` 仕様。symlink 不可・実ファイルのみ）
- `~/.openclaw/openclaw.json` 生成（主な設定）:
  - **マルチアカウント Telegram**: `channels.telegram.accounts.{official,personal}` 各々に `tokenFile` + `dmPolicy: "allowlist"` + `allowFrom: [USER_ID]` + `groupPolicy` / `groupAllowFrom` を指定。`defaultAccount: official`。**allowlist は account 単位**（チャンネル直下に書くと Doctor が `accounts.default` に切り出してしまい、official/personal は allowlist 無し扱いになる）
  - **エージェント**: `agents.list[]` に `official-agent` (`anthropic/claude-opus-4-7` primary + `anthropic/claude-sonnet-4-6` fallback) と `personal-agent` (`lmstudio/${LMSTUDIO_MODEL}`、未指定時は `lmstudio/unsloth/qwen3.6-35b-a3b-ud-mlx`)。`personal-agent` には `workspace: ~/.openclaw/workspace` を明示し、official と同じ Google Drive 配下の workspace を共有させる（明示しない場合 openclaw は `~/.openclaw/workspace-personal-agent` を自動生成して別 workspace になる）。さらに `agents.defaults.model` にも同じ Claude Opus + Sonnet fallback を設定し、main / 未バインド agent が OpenClaw 組み込み既定 (`openai/gpt-5.5`) にフォールバックするのを防止
  - **LM Studio provider**: `models.providers.lmstudio` に OpenAI 互換 API として登録（`baseUrl: http://127.0.0.1:1234/v1`, `api: openai`）
  - **ルーティング**: top-level `bindings[]` で `accountId: official → official-agent`、`accountId: personal → personal-agent`
  - **オーナー権限**: top-level `commands.ownerAllowFrom: ["telegram:<USER_ID>"]` で owner-only コマンド（`/diagnostics`, `/export-trajectory`, `/config`, exec 承認）を自分の Telegram アカウントに許可
  - **共通**: loopback / token auth / Tailscale Serve / `exec.security: full` / `tools.deny: []` / `execApprovals: off` / `fs.workspaceOnly: true` / `ssrfPolicy` / `channels.telegram.network.dnsResultOrder: "ipv4first"`（IPv6 経路の polling stall 回避のため IPv4 優先。`autoSelectFamily: false` は Node 22+ で getUpdates timeout cascade を引き起こす既知バグがあるため `true` のまま Happy Eyeballs を有効化） / `channels.telegram.timeoutSeconds: 60`（90s の polling stall threshold より先に HTTP timeout を発火させて zombie 状態を回避） / `channels.telegram.streaming.mode: "partial"` + `streaming.preview.toolProgress: false`（ツール進捗の逐次プレビューを抑止し送信スパムを軽減）
  - 実値は [`scripts/03-openclaw-setup.sh`](scripts/03-openclaw-setup.sh) の `generate_config` を参照
- `ANTHROPIC_API_KEY` / `LMSTUDIO_API_KEY="lm-studio"` を `~/.openclaw/.env` に保存（LM Studio はローカル marker のため最初から書き込み。Telegram トークンは `.env` ではなく `credentials/telegram/*.token` 経由）
- `~/.openclaw` 700 / 設定ファイル 600 / Spotlight 除外
- zsh 補完を `~/.openclaw/completions/openclaw.zsh` に生成し、`~/.zshrc` に source 行を追加（`openclaw completion --shell zsh --install --write-state`）
- Gateway LaunchAgent 登録 + `OPENCLAW_NO_RESPAWN=1` 注入

実行後、Telegram から official / personal の各 Bot に DM して応答が返れば完了。

---

## モデルの切り替え

デフォルトは official-agent = `anthropic/claude-opus-4-7` (+ `anthropic/claude-sonnet-4-6` fallback)、personal-agent = `lmstudio/unsloth/qwen3.6-35b-a3b-ud-mlx`（`.env` の `LMSTUDIO_MODEL` で変更可）、`agents.defaults.model` = `anthropic/claude-opus-4-7` (+ Sonnet fallback)。

agent ID は人格 (Telegram bot identity) に紐付いており、bindings (account → agent) と token ファイル名 (`credentials/telegram/{official,personal}.token`) は固定。**モデルだけを差し替える場合は `~/.openclaw/openclaw.json` の `agents.list[].model` を編集**して `openclaw gateway restart`:

```jsonc
"agents": {
  "defaults": {
    "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] }
  },
  "list": [
    { "id": "official-agent", "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] } },
    { "id": "personal-agent", "model": "lmstudio/unsloth/qwen3.6-35b-a3b-ud-mlx", "workspace": "/Users/claw/.openclaw/workspace" }
  ]
}
```

`model` は文字列 (`"provider/model"`) または `{ primary, fallbacks }` オブジェクトのどちらでも可。`agents.defaults.model` は `agents.list[]` で個別 model 指定の無い agent（`main` 等）に適用され、未設定だと OpenClaw は組み込み既定 `openai/gpt-5.5` にフォールバックして OpenAI auth を要求するため、Anthropic に明示する。`openclaw models set` は `agents.defaults.model` を書き換える CLI なので、`agents.list[]` の個別 model を変えたいときは openclaw.json の直接編集が必要。

### LM Studio (ローカル LLM) モデルの差し替え例

Mac Mini 上の LM Studio (`http://127.0.0.1:1234/v1`) は `LMSTUDIO_API_KEY="lm-studio"` がセット済み（`03-openclaw-setup.sh` で `~/.openclaw/.env` に自動投入）。**`personal-agent` のモデルと 01 の `lms get` 対象モデルは `<repo>/.env` の `LMSTUDIO_MODEL` で一括指定**する:

```bash
# 1. <repo>/.env の LMSTUDIO_MODEL を書き換え
#    LMSTUDIO_MODEL="<新しいモデル>"

# 2. 反映 (01 が admin として新モデル取得、03 が claw として openclaw.json 更新)
./scripts/01-admin-macos-setup.sh   # admin で実行
./scripts/03-openclaw-setup.sh      # claw で実行
```

スクリプトを再実行せず手動で反映したい場合は、admin として `lms get <model>`（モデルは admin の `~/.lmstudio/` に保存される）後に claw として `~/.openclaw/openclaw.json` の `agents.list[].model` と `models.providers.lmstudio.models[].id` を直接編集して `openclaw gateway restart`。新モデルは初回呼び出し時に JIT loading でメモリへ自動ロードされる。

### context window

context window は基本的に LM Studio 側の既定に任せる。文脈不足を感じた場合は `~/.openclaw/openclaw.json` の `models.providers.lmstudio.models[].params.contextLength` を追加して `openclaw gateway restart`。

### 新しい人格 (3 つ目以降の Bot) を追加する場合

1. BotFather で新 Bot を作成して token を取得
2. `~/.openclaw/credentials/telegram/<新名前>.token` を chmod 600 で配置
3. `openclaw.json` の `channels.telegram.accounts` / `agents.list[]` / `bindings[]` にエントリ追加
4. `openclaw gateway restart`

---

## 再起動後のリモート復旧手順

Mac Mini が再起動した場合（停電・macOS アップデート等）、Tailscale と LM Studio LaunchDaemon は自動起動する。別の Tailscale 接続済み Mac から `open vnc://<mac-mini-tailscale-ip>` で **claw アカウント**にログインすれば、Gateway LaunchAgent + Google Drive for Desktop が起動するので、`openclaw status` と Telegram からの疎通を確認する。

---

## バックアップ / リストア

### 自動バックアップ（スクリプト再実行）

`./scripts/03-openclaw-setup.sh` は既存の `~/.openclaw` を検出すると自動的に `~/.openclaw-snapshot-<timestamp>/` に退避してから、クリーン状態で OpenClaw を再構築します（初回セットアップ時はスキップ）。流れ:

1. Gateway / LaunchAgent を停止・削除し、`~/.openclaw` を snapshot にコピー
2. Google Drive 上の workspace 中身（dotfile / `.git` 含む全項目）は snapshot に **`mv`**（symlink ではなく実体）。Google Drive workspace は空になる（personal PC にも数十秒〜数分で反映）
3. npm uninstall + `~/.openclaw/` 削除のうえ、通常フロー（Bot Token / User ID / API Key を対話で再入力）で再構築。空の Google Drive workspace に symlink を張り直し、新しい `AGENTS.md` だけが配置される

snapshot は workspace 実体を含む self-contained なバックアップで、Google Drive から消えても Mac Mini 上に残ります。

### `--recover` で自動復元（workspace + cron）

```bash
./scripts/03-openclaw-setup.sh --recover                              # 最新 snapshot を自動選択
./scripts/03-openclaw-setup.sh --recover ~/.openclaw-snapshot-<ts>    # 特定の snapshot を指定
```

セットアップ完了後の最終ステップで snapshot から `workspace` と `cron/` を自動復元します:

- `workspace/`: snapshot 内の実体ファイルを Google Drive 上の workspace パスに `cp -a` で書き戻し（personal PC にも sync）
- `cron/`: snapshot から `~/.openclaw/cron` にコピーし、`openclaw gateway restart` で反映

引数なしの場合は `~/.openclaw-snapshot-*` から最新を自動選択。古い snapshot や別パスから復元したい場合はディレクトリパスを **空白区切り** で渡してください（上の例 2 行目）。zsh/bash は `--recover=~/path` の形式では `~` をシェル展開しないため、空白区切り (`--recover ~/...`) のほうが取り違えが起きにくく推奨です。`--recover=DIR` 形式も使用可能で、その場合は先頭の `~` をスクリプト側で `$HOME` に展開します。

それ以外（identity / telegram / agents / memory / media / flows / tasks / plugins / skills 等）は `--recover` の対象外です。必要があれば下記の手動リストアで個別に対応します。

### 手動リストア（identity / telegram など、その他の状態）

```bash
SNAP=~/.openclaw-snapshot-<ts>   # 実際のディレクトリ名に置き換え

# 最低限（同じ Telegram Bot を継続使用するなら必須）
cp -a "$SNAP/identity" "$SNAP/telegram" "$SNAP/credentials" ~/.openclaw/

# 履歴・カスタム設定（必要なものだけ選択）
cp -a "$SNAP/agents" "$SNAP/memory" "$SNAP/media" ~/.openclaw/
cp -a "$SNAP/flows" "$SNAP/tasks" "$SNAP/plugins" "$SNAP/skills" ~/.openclaw/

openclaw gateway restart
```

| ディレクトリ | 役割 | 復元判断 |
|----|----|----|
| `workspace/` | ワークスペース実体（snapshot は symlink ではなくファイル） | `--recover` で自動復元 |
| `cron/` | スケジュールされたタスク定義 | `--recover` で自動復元 |
| `identity/` | デバイス identity・暗号鍵 | 手動。必須（再 pairing 回避） |
| `telegram/` | Telegram pairing 状態・update offset | 手動。必須 |
| `credentials/telegram/*.token` | official / personal の Bot Token | 手動。必須（再入力したくなければ復元） |
| `agents/`, `memory/`, `media/` | セッション履歴・累積メモリ・受信メディア | 手動。履歴を引き継ぎたい場合（`agents/` を入れるなら `media/` もセット） |
| `flows/`, `tasks/`, `plugins/`, `skills/` | ユーザー定義 | 手動。カスタムしていれば復元 |
| `exec-approvals.json`, `*.bak*`, `*.last-good`, `logs/` | 履歴・キャッシュ | 復元しない（新 config と競合 / 不要） |

`gateway.auth.token` を引き継いでリモートクライアント再設定を避けたい場合は、snapshot の `openclaw.json` から token 値を抜き出して新 `openclaw.json` の同フィールドに書き戻し、`chmod 600` の上で `openclaw gateway restart`。動作確認できたら `rm -rf "$SNAP"`。

---

## 参考資料

- [OpenClaw 公式 - Install](https://docs.openclaw.ai/install) / [Security](https://docs.openclaw.ai/gateway/security) / [Telegram](https://docs.openclaw.ai/channels/telegram) / [Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [LM Studio - Headless mode](https://lmstudio.ai/docs/app/api/headless) / [lms CLI](https://lmstudio.ai/docs/cli)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
