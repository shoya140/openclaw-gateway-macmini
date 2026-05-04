# OpenClaw Gateway on Mac Mini

Mac Mini に OpenClaw をインストールし、Telegram から main (Claude) と personal (LM Studio 上のローカル LLM) の 2 つの bot を運用するためのセットアップ。

## アーキテクチャ

```
[Telegram main Bot]     ─┐
                         ├─> [OpenClaw Gateway (localhost:18789)] ─┬─> [Anthropic API]      (main agent)
[Telegram personal Bot] ─┘             ↑                          └─> [LM Studio 127.0.0.1] (personal agent)
                            [Tailscale Serve (tailnet 内のみ)]
```

- 1 gateway で 2 つの Telegram Bot を運用 (`channels.telegram.accounts.{main,personal}` + top-level `bindings[]`)
- main = Claude Opus 4.7 (+ Sonnet 4.6 fallback)、personal = LM Studio 上のローカル LLM
- Gateway は loopback bind、外部アクセスは Tailscale Serve 経由 (tailnet 内のみ、パブリックポート開放なし)
- OpenClaw は専用の標準アカウント `claw` で実行 (sudo / brew 不可、admin・他ユーザーのファイル不可視)
- LM Studio は admin (= 01 を実行したユーザー) として LaunchDaemon で常駐。モデルは admin の `~/.lmstudio/` 配下
- Workspace は Google Drive 共有フォルダで個人 PC と同期

### セキュリティモデル

`exec.security: full` + `tools.deny: []` + `execApprovals: off` で「ユーザー権限内のあらゆる操作を承認なしに自走」する設計。`claw` 専用標準アカウントによる OS 分離が最後の砦。**`personal` agent は LM Studio 上の小規模ローカル LLM を使うため prompt injection 耐性が低い**が、Mac Mini に Docker を導入していないため `sandbox.mode: "all"` は適用していない (main agent と同じく sandbox-off)。`security audit` の `models.small_params` CRITICAL は claw 標準アカウントの OS 分離を最後の砦として受容する。Docker (OrbStack 等) を導入する余裕ができたタイミングで `agents.list[].personal.sandbox.mode: "all"` + `tools.deny: ["group:web", "browser"]` を再導入することを推奨。

設定では防げない領域は別レイヤーで補う:
- **Anthropic console で月額 spend cap** を設定 (API キー流出 / runaway loop 時の被害金額を有限化)
- **Tailscale ACL** で Mac Mini ノードから他 tailnet ノードへの egress を制限

---

## 準備物

- Mac Mini (Apple Silicon 推奨) + macOS 15 以降
- インターネット接続
- 管理者アカウントに Homebrew インストール済み
- Telegram アカウント + BotFather で作成した **2 つの Bot Token** (main 用 / personal 用) + 自分の User ID (`@userinfobot` で確認)
- Anthropic API Key
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

2 回目以降の実行は `~/.openclaw` と Google Drive 上の workspace 中身を `~/.openclaw-snapshot-<ts>/` に自動でバックアップしてから再構築します (Google Drive 上の workspace は一旦空になり個人 PC にも反映)。snapshot から workspace + cron を復元する場合は `./scripts/04-recover-snapshot.sh <snapshot-dir>`。詳細は [バックアップ / リストア](#バックアップ--リストア) 参照。

---

## `.env` (プロジェクト直下)

`<repo>/.env` (chmod 600 推奨) に下記を書いておくと、03 / 01 の対話入力を省略できます。`.env` は `.gitignore` 済みでコミットされません。

```dotenv
TELEGRAM_MAIN_BOT_TOKEN="..."
TELEGRAM_PERSONAL_BOT_TOKEN="..."
TELEGRAM_USER_ID="..."
ANTHROPIC_API_KEY="sk-ant-..."
LMSTUDIO_MODEL="unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit"  # 省略可
```

| キー | 必須 | 用途 |
|----|----|----|
| `TELEGRAM_MAIN_BOT_TOKEN` | yes | main bot 用 Token (Claude) |
| `TELEGRAM_PERSONAL_BOT_TOKEN` | yes | personal bot 用 Token (LM Studio) |
| `TELEGRAM_USER_ID` | yes | 自分の Telegram User ID 数値 (allowlist と ownerAllowFrom 用) |
| `ANTHROPIC_API_KEY` | yes | main agent (Claude) |
| `LMSTUDIO_MODEL` | no  | personal agent モデル。01 の `lms get` 対象 + 03 の `agents.list[].personal.model` 初期値。デフォルト `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit` |

`LMSTUDIO_API_KEY` は marker 値 (`"lm-studio"`) を 03 がハードコードで `~/.openclaw/.env` に書き込むため、プロジェクト `.env` での指定は不要。

セット済みの項目だけ対話入力をスキップ。シェルから `export` した環境変数も同様に優先されます。

最終的な書き込み先:
- Telegram Bot Token → `~/.openclaw/credentials/telegram/{main,personal}.token` (chmod 600、symlink 不可・実ファイル必須)
- `ANTHROPIC_API_KEY`, `LMSTUDIO_API_KEY` → `~/.openclaw/.env` (chmod 600)

---

## 各スクリプトが行うこと

### `01-admin-macos-setup.sh` (管理者アカウント)

- ファイアウォール + ステルスモード有効化
- 24/7 運用向け `pmset` (スリープ無効、再起動後の自動復帰)
- 自動ログイン無効化、Screen Sharing 有効化、SSH 有効化
- Tailscale インストール・認証 + `tailscale serve --bg http://127.0.0.1:18789`
- LM Studio (llmster) インストール + `/Library/LaunchDaemons/io.shoya.lmstudio.plist` 配置 + モデル取得
  - `curl -fsSL https://lmstudio.ai/install.sh | bash -s -- --no-modify-path` で `~/.lmstudio/bin/lms` を配置
  - LaunchDaemon は `UserName` = 01 を実行したユーザー (admin 権限) で起動。モデル置き場は admin の `~/.lmstudio/`
  - 起動コマンド: `lms daemon up && lms server start --port 1234` (OpenAI 互換 API が `http://127.0.0.1:1234/v1` で listening)
  - admin の `~/.lmstudio/` を Spotlight + Time Machine から除外
  - daemon の起動を待ったうえで `lms get "${LMSTUDIO_MODEL:-unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit}"` を実行
  - JIT loading に任せるため起動時 preload はしない (初回呼び出し時にメモリへロード)
- `claw` 標準アカウント作成 (パスワード対話入力)
- Google Drive for Desktop インストール

> **手動確認が必要**:
> - Screen Sharing の VNC パスワードアクセスが無効であること (Tailscale 経由のみ使用)
> - 再起動後に Tailscale が自動接続されること (`tailscale status`)
>
> **FileVault は無効のまま**。有効にするとコールドブート時にリモート復旧ができなくなるため。

### `02-claw-user-setup.sh` (`claw` アカウント)

Screen Sharing 等で claw にログインしてから実行する。

- Google Drive セットアップ (下記参照)
- mise インストール + シェル統合
- Node.js インストール (`mise use -g node@24`)
- sudo / brew が claw から使えないことの自動検証

#### Google Drive セットアップ

`02-claw-user-setup.sh` 実行中に Google Drive が起動するので、以下の GUI 操作を行ってから Enter を押す:

1. OpenClaw 専用 Google アカウントでサインイン
2. 同期モードを「ミラーリング」に設定 (Google Drive メニュー → 設定 → Google Drive → ミラーリング)
3. 個人が共有した `openclaw-workspace` フォルダを My Drive に追加 (右クリック → 整理 → ショートカットを追加 → マイドライブ)

### `03-openclaw-setup.sh` (`claw` アカウント)

`.env` の値があれば対話入力を省略しつつ、以下を実行:

- 既存 `~/.openclaw` を `~/.openclaw-snapshot-<ts>/` に退避 (`~/.openclaw` 全体は `cp -a`、Google Drive 上の workspace 中身は `mv` で snapshot に実体化 → Google Drive 上は空になり個人 PC にも反映、復元は 04 で)
- LaunchAgent と `openclaw gateway stop` を確実に実行してから OpenClaw アンインストール + `~/.openclaw` 削除
- OpenClaw インストール (`npm install -g openclaw@latest`)
- Telegram 拡張依存 (`grammy` / `@grammyjs/runner` / `@grammyjs/transformer-throttler`) が openclaw の `package.json` に含まれているかを node で動的判定し、含まれていなければ手動 install (上流 packaging bug の workaround)
- 入力された 2 つの Bot Token を `~/.openclaw/credentials/telegram/{main,personal}.token` に書き込み (chmod 600)
- Google Drive 内の `openclaw-workspace` を自動検出し `~/.openclaw/workspace` にシンボリックリンク
- `~/.openclaw/openclaw.json` を生成 (主要設定は下記参照)。`models.providers.lmstudio.models[]` は LM Studio v0 native API (`http://127.0.0.1:1234/api/v0/models`) からロード可能な LLM/VLM 一覧を取得し `id` / `name` / `contextWindow` 付きで自動展開 (API 失敗時は `LMSTUDIO_MODEL` 1 個のみ)
- `ANTHROPIC_API_KEY` と `LMSTUDIO_API_KEY="lm-studio"` を `~/.openclaw/.env` に書き込み
- `~/.openclaw` 700 / 設定ファイル 600 / Spotlight 除外
- Gateway LaunchAgent 登録 (`openclaw gateway install --force`) + plist に `OPENCLAW_NO_RESPAWN=1` 注入
- `launchctl bootout` → `bootstrap` → `kickstart` で確実に新環境変数で起動
- `openclaw doctor` / `security audit` / `status` で検証 (read-only、`--fix` は呼ばない)
- 最後に `~/.openclaw/openclaw.json.{bak,bak.*,last-good}` を一括削除

#### `openclaw.json` の主要設定

- **Gateway**: `bind: loopback`, `auth.mode: token`, `tailscale.mode: serve`, `controlUi.allowedOrigins: ["https://<tailscale-host>"]`
- **Telegram**: `defaultAccount: main`, `accounts.{main,personal}` 各々に `tokenFile` + `dmPolicy: allowlist` + `allowFrom: [USER_ID]` + `groupPolicy: allowlist` + `groupAllowFrom: [USER_ID]`
  - `timeoutSeconds: 60`, `pollingStallThresholdMs: 120000`
  - `network.dnsResultOrder: ipv4first`, `network.autoSelectFamily: true` (Node 22+ の Happy Eyeballs を有効化)
  - `streaming.mode: partial`, `streaming.preview.toolProgress: false` (ツール進捗の逐次プレビューを抑止して送信スパムを軽減)
- **Tools**: `profile: coding`, `deny: []`, `fs.workspaceOnly: true`, `exec.security: full`
- **Browser**: `ssrfPolicy.dangerouslyAllowPrivateNetwork: false`
- **Agents**:
  - `defaults.model = anthropic/claude-opus-4-7 (+ sonnet fallback)` (未バインド agent が openclaw 組み込み既定 `openai/gpt-5.5` にフォールバックするのを防止)
  - `defaults.workspace = ~/.openclaw/workspace` (全 agent が同じ Google Drive workspace を共有)
  - `defaults.sandbox.mode = off` (Docker 未導入のため personal-agent でも sandbox は無効)
  - `list[]`: `main` (anthropic/claude-opus-4-7 + sonnet fallback) / `personal` (lmstudio/${LMSTUDIO_MODEL})。`main` は OpenClaw の予約 ID (CLI で add/delete 不可) で、`bindings` に明示的に紐付けて Telegram の `main` アカウント担当として使う。Claude 用に追加 agent を作る必要はない (main で兼ねる)
- **LM Studio provider**: `baseUrl: http://127.0.0.1:1234/v1`, `api: openai-completions`, `models[]` には 03 実行時点で LM Studio v0 native API から取得した全ロード可能 LLM/VLM を `id` / `name` / `contextWindow` 付きで自動展開 (API 失敗時は `LMSTUDIO_MODEL` 1 個のみ)。新規モデルを `lms get` した場合は 03 を再実行すれば `models[]` に追加される
- **Bindings**: telegram main → main, telegram personal → personal (`accountId` → `agentId`)
- **Owner commands**: `commands.ownerAllowFrom: ["telegram:<USER_ID>"]` で owner-only コマンド (`/diagnostics`, `/export-trajectory`, `/config`, exec 承認) を自分の Telegram アカウントに許可
- **Logging**: `redactSensitive: tools`

実値は [`scripts/03-openclaw-setup.sh`](scripts/03-openclaw-setup.sh) の `generate_config` を参照。

実行後、Telegram から main / personal の各 Bot に DM して応答が返れば完了。

### `04-recover-snapshot.sh` (`claw` アカウント)

`~/.openclaw-snapshot-<ts>/` から workspace と cron を復元するスクリプト。03 の自動バックアップで作られた snapshot を引数で指定して実行する。

```bash
./scripts/04-recover-snapshot.sh ~/.openclaw-snapshot-<ts>
```

- `<snapshot>/workspace/*` → `~/.openclaw/workspace` の symlink 先 (Google Drive 上の `openclaw-workspace`) に `cp -a` で書き戻し (個人 PC にも sync)
- `<snapshot>/cron/` → `~/.openclaw/cron` に `cp -a` (既存は削除して置き換え)
- 復元後は `launchctl kickstart` で LaunchAgent を再ロード (新 cron 反映)

`identity` / `telegram` / `credentials` / `agents` 等は対象外。必要なら下記 [手動リストア](#identity--telegram-などを手動リストア) を参照。

---

## 二重応答防止 (重要なお作法)

OpenClaw は同じ Bot Token に対して複数の polling worker が同時に走ると、Telegram から見て同じメッセージを複数回処理してしまい、2-3 度返答が返ることがあります (上流の getUpdates lock が破れるパターン)。これを防ぐため、**Gateway の起動・再起動は LaunchAgent 経由のみで行ってください**。

```bash
# OK: 設定変更後の再ロード
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway

# OK: 03 を再実行 (snapshot 経由で確実に bootout してから起動)
./scripts/03-openclaw-setup.sh

# NG: 手動の gateway start / restart は二重 polling の原因
openclaw gateway restart   # 使わない
openclaw gateway start     # 使わない
```

03 は plist に `OPENCLAW_NO_RESPAWN=1` を注入することで、config 変更時の SIGUSR1 in-process restart も抑制しています (これも二重 polling の原因の一つ)。

---

## モデルの切り替え

デフォルトは:
- `main` (Claude) = `anthropic/claude-opus-4-7` (+ `anthropic/claude-sonnet-4-6` fallback)
- `personal` (LM Studio) = `lmstudio/${LMSTUDIO_MODEL}` (`.env` の `LMSTUDIO_MODEL` で初期値変更可、未指定時は `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit`)
- `agents.defaults.model` = `anthropic/claude-opus-4-7` (+ Sonnet fallback)

agent ID は人格 (Telegram bot identity) に紐付いており、bindings (account → agent) と token ファイル名は固定。**モデルだけを差し替える場合は `~/.openclaw/openclaw.json` の `agents.list[].model` を編集**して LaunchAgent を再ロード:

```jsonc
"agents": {
  "defaults": {
    "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] },
    "workspace": "/Users/claw/.openclaw/workspace",
    "sandbox": { "mode": "off" }
  },
  "list": [
    { "id": "main",     "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] } },
    { "id": "personal", "model": "lmstudio/<modelKey>" }
  ]
}
```

```bash
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

`model` は文字列 (`"provider/model"`) または `{ primary, fallbacks }` オブジェクトのどちらでも可。

### LM Studio (ローカル LLM) モデルの差し替え

#### 既に LM Studio にロードされているモデル間で差し替える

```bash
# 利用可能なモデルキーを確認
~/.lmstudio/bin/lms ls --json
# または curl http://127.0.0.1:1234/api/v0/models
```

03 実行時点で `models.providers.lmstudio.models[]` に LM Studio v0 API 経由で全 LLM/VLM が `contextWindow` 付きで登録されています。**`~/.openclaw/openclaw.json` の `agents.list[].personal.model` を `lmstudio/<modelKey>` に書き換えて LaunchAgent を再ロード**するだけでモデル切り替えが完結します。`<modelKey>` は `lms ls --json` の `modelKey` か `curl http://127.0.0.1:1234/api/v0/models` の `id` で確認できます。

#### 新しいモデルを追加する

```bash
# 1. admin として lms get で取得 (モデルは admin の ~/.lmstudio/ に保存)
~/.lmstudio/bin/lms get "<huggingface-url-or-modelKey>"

# 2. claw として 03 を再実行 → models[] に新モデルが contextWindow 付きで追加される
./scripts/03-openclaw-setup.sh

# 3. agents.list[].personal.model を新モデルに書き換えて LaunchAgent を再ロード
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

`<repo>/.env` の `LMSTUDIO_MODEL` を新モデルに更新してから 03 を再実行すれば、`personal.model` の初期値も新モデルになります (snapshot 経由で再構築)。

### 新しい人格 (3 つ目以降の Bot) を追加する場合

1. BotFather で新 Bot を作成して token を取得
2. `~/.openclaw/credentials/telegram/<新名前>.token` を chmod 600 で配置
3. `openclaw.json` の `channels.telegram.accounts` / `agents.list[]` / `bindings[]` にエントリ追加
4. LaunchAgent を再ロード

---

## LM Link で個人 PC から LM Studio に直接接続 (オプション)

[LM Link](https://lmstudio.ai/link) は LM Studio が提供する Tailscale tsnet ベースのメッシュ VPN で、別マシンから Mac Mini の LM Studio API を「ローカルのように」叩けるようにする機能です。本プロジェクトの既定経路 (Telegram + Tailscale Serve + OpenClaw Gateway) とは独立して、個人 PC の Claude Code / Codex / OpenCode 等から LM Studio を直接利用したい場合に使います。

### 前提

- LM Studio アカウント ([lmstudio.ai](https://lmstudio.ai/) で作成)
- LM Link Preview Access の承認 ([lmstudio.ai/link](https://lmstudio.ai/link) から申請、Preview 期間中は申請から承認まで数日)

### Mac Mini 側 (admin で実行、LaunchDaemon が起動済みの状態で)

```bash
~/.lmstudio/bin/lms login        # device code flow
~/.lmstudio/bin/lms link enable  # mesh に参加
~/.lmstudio/bin/lms link set-device-name "mac-mini-openclaw"   # 任意
~/.lmstudio/bin/lms link status                                # 接続状態
```

### 個人 PC 側

LM Studio GUI を起動し、Mac Mini と同じアカウントで login したうえで LM Link を有効化すると、Mac Mini が peer として認識され、ダウンロード済みモデルがそのまま利用可能になります。OpenAI 互換クライアントは個人 PC のローカル `http://localhost:1234/v1` を向けるだけで Mac Mini 上の LM Studio に到達します。

### 無効化

```bash
~/.lmstudio/bin/lms link disable
```

---

## 再起動後のリモート復旧手順

Mac Mini が再起動した場合 (停電・macOS アップデート等)、Tailscale と LM Studio LaunchDaemon は自動起動します。別の Tailscale 接続済み Mac から `open vnc://<mac-mini-tailscale-ip>` で **claw アカウント**にログインすれば、Gateway LaunchAgent と Google Drive for Desktop が起動するので、`openclaw status` と Telegram からの疎通を確認してください。

---

## バックアップ / リストア

### 自動バックアップ

`./scripts/03-openclaw-setup.sh` は既存 `~/.openclaw` を検出すると、`~/.openclaw-snapshot-<timestamp>/` に退避してから再構築します (初回セットアップ時はスキップ):
- `~/.openclaw` 全体 → snapshot に `cp -a`
- Google Drive 上の workspace 中身 → snapshot 内 `workspace/` に `mv` (実体ファイル化、Google Drive 上は空になり個人 PC にも反映)

snapshot は workspace 実体を含む self-contained なバックアップで、Google Drive から消えても Mac Mini 上に残ります。

### `04-recover-snapshot.sh` で workspace + cron を復元

```bash
./scripts/04-recover-snapshot.sh ~/.openclaw-snapshot-<ts>
```

- `<snapshot>/workspace/*` → Google Drive 上の `openclaw-workspace` に `cp -a` で書き戻し (個人 PC にも sync)
- `<snapshot>/cron/` → `~/.openclaw/cron` に `cp -a` (既存は削除して置き換え)
- LaunchAgent を `kickstart` で再ロード (新 cron 反映)

### identity / telegram などを手動リストア

snapshot 内容は普通の OpenClaw ホームディレクトリの中身なので、個別にコピーで戻せます。

```bash
SNAP=~/.openclaw-snapshot-<ts>   # 実際のディレクトリ名に置き換え

# Gateway を停止 (LaunchAgent 経由)
launchctl bootout gui/$(id -u)/ai.openclaw.gateway

# 例: identity / telegram / credentials を戻す (再 pairing と再入力を回避)
cp -a "$SNAP/identity" "$SNAP/telegram" "$SNAP/credentials" ~/.openclaw/

# 例: 履歴を戻す
cp -a "$SNAP/agents" "$SNAP/memory" "$SNAP/media" ~/.openclaw/

# 例: cron 定義を戻す
cp -a "$SNAP/cron" ~/.openclaw/

# 起動
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

| ディレクトリ | 役割 | 復元判断 |
|----|----|----|
| `workspace/` | Google Drive symlink | 不要 (実体は Google Drive 上に残っている) |
| `identity/` | デバイス identity・暗号鍵 | 必須 (再 pairing 回避) |
| `telegram/` | Telegram pairing 状態・update offset | 必須 |
| `credentials/telegram/*.token` | main / personal の Bot Token | 必須 (再入力したくなければ) |
| `agents/`, `memory/`, `media/` | セッション履歴・累積メモリ・受信メディア | 履歴を引き継ぎたい場合 (`agents/` を入れるなら `media/` もセット) |
| `cron/`, `flows/`, `tasks/`, `plugins/`, `skills/` | スケジューラ・ユーザー定義 | カスタムしていれば |
| `openclaw.json` | 設定 | 通常は新生成を使う。`gateway.auth.token` を引き継ぎたい場合は token 値だけ抜き出して新 config に書き戻し、`chmod 600` 後に再ロード |
| `openclaw.json.{bak,bak.*,last-good}`, `logs/` | 履歴・キャッシュ | 復元しない |

復元後は LaunchAgent を再ロードしてください。動作確認できたら `rm -rf "$SNAP"`。

---

## 参考資料

- [OpenClaw 公式 - Install](https://docs.openclaw.ai/install) / [Security](https://docs.openclaw.ai/gateway/security) / [Telegram](https://docs.openclaw.ai/channels/telegram) / [Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [LM Studio - Headless mode](https://lmstudio.ai/docs/app/api/headless) / [lms CLI](https://lmstudio.ai/docs/cli) / [LM Link](https://lmstudio.ai/docs/lmlink)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
