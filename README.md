# OpenClaw Gateway on Mac Mini

Mac Mini に OpenClaw をインストールし、Telegram から main (OpenAI GPT-5.5 via ChatGPT Pro Codex) と personal (LM Studio 上のローカル LLM) の 2 つの bot を運用するためのセットアップ。

## アーキテクチャ

```
[Telegram main Bot]     ─┐
                         ├─> [OpenClaw Gateway (localhost:18789)] ─┬─> [OpenAI Codex API]    (main, ChatGPT Pro OAuth)
[Telegram personal Bot] ─┘             ↑                          └─> [LM Studio 127.0.0.1] (personal)
                            [Tailscale Serve (tailnet 内のみ)]
```

- 1 gateway で 2 つの Telegram Bot を運用
- main = OpenAI GPT-5.5 (+ GPT-5.4-mini fallback) via `openai-codex` auth profile (ChatGPT Pro)、personal = LM Studio 上のローカル LLM
- Gateway は loopback bind、外部アクセスは Tailscale Serve 経由 (tailnet 内のみ、パブリックポート開放なし)
- OpenClaw は専用の標準アカウント `claw` で実行 (sudo / brew 不可)
- LM Studio は admin (= 01 を実行したユーザー) として LaunchDaemon で常駐
- Workspace は Google Drive 共有フォルダで個人 PC と同期

### セキュリティモデル

`exec.security: full` + `tools.deny: []` + `execApprovals: off` で「ユーザー権限内のあらゆる操作を承認なしに自走」する設計。`claw` 専用標準アカウントによる OS 分離が最後の砦。Mac Mini に Docker 未導入のため `sandbox.mode: "all"` は未適用 (main / personal 共に sandbox-off)。`security audit` の `models.small_params` CRITICAL は claw の OS 分離で受容。

設定では防げない領域は別レイヤーで補う:
- **ChatGPT Pro 枠**: 実質 unlimited (abuse guardrail のみ)。OAuth credential は `~/.openclaw` 配下を 700/600 に固定
- **Tailscale ACL**: Mac Mini ノードから他 tailnet ノードへの egress を制限

---

## 準備物

- Mac Mini (Apple Silicon 推奨) + macOS 15 以降
- 管理者アカウントに Homebrew インストール済み
- Telegram Bot Token 2 つ (main / personal、BotFather で作成) + 自分の User ID (`@userinfobot`)
- ChatGPT Pro サブスクリプション (main agent 用)
- OpenClaw 専用 Google アカウント
- 個人の Google Drive で `openclaw-workspace` フォルダを作成し、専用アカウントを「編集者」として共有

---

## クイックスタート

```bash
# 1. 管理者アカウントで実行
./scripts/01-admin-macos-setup.sh

# 2. Screen Sharing で claw アカウントにログイン後、claw で実行
./scripts/02-claw-user-setup.sh
./scripts/03-openclaw-setup.sh

# 3. main agent の OAuth ログイン (別マシンのブラウザで device code を入力)
openclaw models auth login --provider openai-codex --method device-code

# 4. LaunchAgent を再ロードして OAuth credential を反映
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

`<repo>/.env` に値があれば対話入力を省略できます ([下記](#env-プロジェクト直下))。2 回目以降の 03 実行は `~/.openclaw` を `~/.openclaw-snapshot-<ts>/` に退避してから再構築します ([バックアップ / リストア](#バックアップ--リストア))。

実行後、Telegram から main / personal の各 Bot に DM して応答が返れば完了。

---

## `.env` (プロジェクト直下)

`<repo>/.env` (chmod 600 推奨、`.gitignore` 済み) に下記を書いておくと 03 / 01 の対話入力を省略できます。シェルから `export` した環境変数も同様に優先されます。

| キー | 必須 | 用途 |
|----|----|----|
| `TELEGRAM_MAIN_BOT_TOKEN` | yes | main bot 用 Token |
| `TELEGRAM_PERSONAL_BOT_TOKEN` | yes | personal bot 用 Token |
| `TELEGRAM_USER_ID` | yes | 自分の Telegram User ID 数値 (allowlist と ownerAllowFrom 用) |
| `LMSTUDIO_MODEL` | no | personal-agent モデル初期値 + 01 の `lms get` 対象。デフォルト `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit` |
| `ANTHROPIC_API_KEY` | no | Anthropic に戻す場合の後方互換用 |

main agent は ChatGPT Pro の OAuth (`openai-codex` auth profile) で認証するため OpenAI API key は不要。`LMSTUDIO_API_KEY` は marker 値 (`"lm-studio"`) なので 03 がハードコードで `~/.openclaw/.env` に書き込みます。

---

## 各スクリプトが行うこと

詳細処理はソースコード ([`scripts/`](scripts/)) を参照。主要動作のみ抜粋:

### `01-admin-macos-setup.sh` (管理者アカウント)

- macOS 設定: ファイアウォール / `pmset` (24/7 運用) / 自動ログイン無効 / Screen Sharing / SSH 有効化
- Tailscale: install + 認証 + `tailscale serve --bg http://127.0.0.1:18789`
- LM Studio: install + LaunchDaemon (admin 権限で常駐、OpenAI 互換 API が `http://127.0.0.1:1234/v1`) + `LMSTUDIO_MODEL` を `lms get`
- `claw` 標準アカウント作成 + Google Drive for Desktop インストール

> **手動確認**: Screen Sharing の VNC パスワードアクセスが無効 (Tailscale 経由のみ) / 再起動後の Tailscale 自動接続 (`tailscale status`)
>
> **FileVault は無効のまま** (有効にするとコールドブート時にリモート復旧不可)

### `02-claw-user-setup.sh` (`claw` アカウント)

Screen Sharing 等で claw にログインしてから実行。

- Google Drive セットアップ (下記参照)
- mise + Node.js (`mise use -g node@24`) インストール
- sudo / brew が claw から使えないことの自動検証

#### Google Drive セットアップ (実行中の手動操作)

1. OpenClaw 専用 Google アカウントでサインイン
2. 同期モードを「ミラーリング」に設定 (Google Drive メニュー → 設定)
3. 共有された `openclaw-workspace` フォルダを My Drive に追加 (右クリック → 整理 → ショートカットを追加)

### `03-openclaw-setup.sh` (`claw` アカウント)

- 既存 `~/.openclaw` を `~/.openclaw-snapshot-<ts>/` に退避 ([詳細](#バックアップ--リストア))
- LaunchAgent 停止 → OpenClaw アンインストール → `npm install -g openclaw@latest`
- Telegram 拡張依存 (`grammy` 等) が openclaw の `package.json` に含まれているか動的判定し、欠けていれば手動 install (上流 packaging bug の workaround)
- Bot Token を `~/.openclaw/credentials/telegram/{main,personal}.token` に書き込み (chmod 600)
- Google Drive 内の `openclaw-workspace` を自動検出し `~/.openclaw/workspace` にシンボリックリンク
- `~/.openclaw/openclaw.json` を生成 ([主要設定](#openclawjson-の主要設定))
- LaunchAgent 登録 + plist に `OPENCLAW_NO_RESPAWN=1` 注入 + `bootout` → `bootstrap` → `kickstart` で確実に起動
- `openclaw doctor` / `security audit` / `status` で検証 (read-only、`--fix` は呼ばない)
- 完了後に device-code OAuth ログイン手順を案内

#### `openclaw.json` の主要設定

実値は [`scripts/03-openclaw-setup.sh`](scripts/03-openclaw-setup.sh) の `generate_config` を参照。

- **Gateway**: `bind: loopback` + `auth.mode: token` + `tailscale.mode: serve` + `controlUi.allowedOrigins: ["https://<tailscale-host>"]`
- **Telegram**: 各 account に `tokenFile` + `dmPolicy: allowlist` + `groupPolicy: allowlist` + Node 22+ Happy Eyeballs 有効化 (`network.dnsResultOrder: ipv4first`) + `streaming.preview.toolProgress: false` (送信スパム軽減)
- **Tools**: `profile: coding`, `deny: []`, `fs.workspaceOnly: true`, `exec.security: full`
- **Loop Detection**: `tools.loopDetection.enabled: true` (デフォルトは false)。LM Studio + Qwen 等のローカルモデルでツール呼び出しが暴走するのを抑止。`personal` agent は per-agent override で global より厳しい閾値 (Qwen は GPT-5.5 より遥かにループしやすい)
- **Agents**:
  - `defaults.model = openai-codex/gpt-5.5 (+ openai-codex/gpt-5.4-mini fallback)`、`defaults.workspace = ~/.openclaw/workspace`、`defaults.sandbox.mode = off` (Docker 未導入)
  - `defaults.timeoutSeconds = 1800` (30 分。OpenClaw 既定の 48 時間は Telegram bot 用途には長すぎる)
  - `list[]`: `main` (`openai-codex/gpt-5.5` + fallback、ChatGPT Pro OAuth) / `personal` (`lmstudio/${LMSTUDIO_MODEL}`)
- **OpenAI provider**: `models.providers.openai-codex` block は不要 (auth profile 切替のみで native Codex runtime が自動選択)。OAuth credential は OpenClaw が `~/.openclaw` 配下の auth store で管理 (パス公式未公開)
- **LM Studio provider**: `baseUrl: http://127.0.0.1:1234/v1` + `api: openai-completions`。`models[]` は LM Studio v0 native API (`/api/v0/models`) からロード可能な全 LLM/VLM を `id` / `name` / `contextWindow` 付きで自動展開 (API 失敗時は `LMSTUDIO_MODEL` 1 個のみ)。新規モデル追加時は 03 を再実行
- **Bindings**: telegram main → main, telegram personal → personal
- **Messages**: `queue.mode: collect` (2026.4.29 で `steer` がデフォルト化したが「進行中ランに新メッセージが注入されて前メッセージまで含んだ返信が返る」バグを踏むため `collect` に固定)
- **Owner commands**: `commands.ownerAllowFrom: ["telegram:<USER_ID>"]` で owner-only コマンド (`/diagnostics`, `/export-trajectory`, `/config`, exec 承認) を自分の Telegram に許可

### `04-recover-snapshot.sh` (`claw` アカウント)

`~/.openclaw-snapshot-<ts>/` から workspace と cron を復元。詳細は [バックアップ / リストア](#バックアップ--リストア)。

```bash
./scripts/04-recover-snapshot.sh ~/.openclaw-snapshot-<ts>
```

---

## 二重応答防止 (重要なお作法)

OpenClaw は同じ Bot Token に対して複数の polling worker が同時に走ると、Telegram から見て同じメッセージを複数回処理してしまい、2-3 度返答が返ることがあります (上流の getUpdates lock が破れるパターン)。これを防ぐため、**Gateway の起動・再起動は LaunchAgent 経由のみ**で行ってください。

```bash
# OK: 設定変更後の再ロード
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway

# OK: 03 を再実行 (snapshot 経由で確実に bootout してから起動)
./scripts/03-openclaw-setup.sh

# NG: 手動の gateway start / restart (二重 polling の原因)
openclaw gateway restart   # 使わない
openclaw gateway start     # 使わない
```

03 は plist に `OPENCLAW_NO_RESPAWN=1` を注入することで、config 変更時の SIGUSR1 in-process restart も抑制しています (これも二重 polling の原因)。

---

## モデルの切り替え

agent ID は人格 (Telegram bot identity) に紐付いており、bindings (account → agent) と token ファイル名は固定です。**モデルだけを差し替える場合は `~/.openclaw/openclaw.json` の `agents.list[].model` を編集**して LaunchAgent を再ロード:

```jsonc
"agents": {
  "list": [
    { "id": "main",     "model": { "primary": "openai-codex/gpt-5.5", "fallbacks": ["openai-codex/gpt-5.4-mini"] } },
    { "id": "personal", "model": "lmstudio/<modelKey>" }
  ]
}
```

```bash
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

`model` は文字列 (`"provider/model"`) または `{ primary, fallbacks }` オブジェクトのどちらでも可。

### LM Studio (ローカル LLM) のモデル差し替え

LM Studio v0 API 経由で 03 実行時点の全 LLM/VLM が `models.providers.lmstudio.models[]` に登録済み。利用可能なモデルキー確認:

```bash
~/.lmstudio/bin/lms ls --json
# または curl http://127.0.0.1:1234/api/v0/models
```

`agents.list[].personal.model` を `lmstudio/<modelKey>` に書き換えて LaunchAgent を再ロード。

新しいモデルを追加するときは admin で `lms get` してから 03 を再実行 (snapshot 経由で再構築されて `models[]` に追加される):

```bash
~/.lmstudio/bin/lms get "<huggingface-url-or-modelKey>"   # admin として
./scripts/03-openclaw-setup.sh                             # claw として
```

`<repo>/.env` の `LMSTUDIO_MODEL` を新モデルに更新してから 03 を再実行すれば `personal.model` の初期値も新モデルになります。

### main agent を Anthropic Claude に戻す

ChatGPT Proをやめて Anthropic API key 課金に戻す場合:

1. `<repo>/.env` に `ANTHROPIC_API_KEY="sk-ant-..."` を追記
2. `./scripts/03-openclaw-setup.sh` 再実行 (`~/.openclaw/.env` に書き込まれる)
3. `~/.openclaw/openclaw.json` の `agents.defaults` / `agents.list[].main` の `model` を `anthropic/claude-opus-4-7` (+ `anthropic/claude-sonnet-4-6` fallback) に編集
4. `launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway`
5. (任意) `openclaw models auth logout --provider openai-codex`

### 新しい人格 (3 つ目以降の Bot) を追加

1. BotFather で新 Bot を作成して token を取得
2. `~/.openclaw/credentials/telegram/<新名前>.token` を chmod 600 で配置
3. `openclaw.json` の `channels.telegram.accounts` / `agents.list[]` / `bindings[]` にエントリ追加
4. LaunchAgent を再ロード

---

## LM Link で個人 PC から LM Studio に直接接続 (オプション)

[LM Link](https://lmstudio.ai/link) は LM Studio の Tailscale tsnet ベースのメッシュ VPN で、別マシンから Mac Mini の LM Studio API を「ローカルのように」叩けます。本プロジェクトの既定経路 (Telegram + Tailscale Serve + OpenClaw Gateway) とは独立して、個人 PC の Claude Code / Codex / OpenCode 等から LM Studio を直接利用したい場合に使います。

前提: LM Studio アカウント + LM Link Preview Access の承認 ([lmstudio.ai/link](https://lmstudio.ai/link) から申請、Preview 期間中は数日)

```bash
# Mac Mini 側 (admin で実行、LaunchDaemon 起動済みの状態で)
~/.lmstudio/bin/lms login        # device code flow
~/.lmstudio/bin/lms link enable  # mesh に参加
~/.lmstudio/bin/lms link set-device-name "mac-mini-openclaw"   # 任意
~/.lmstudio/bin/lms link status                                # 接続状態
~/.lmstudio/bin/lms link disable # 無効化
```

個人 PC 側で LM Studio GUI を起動し、Mac Mini と同じアカウントで login + LM Link 有効化すると Mac Mini が peer として認識され、ダウンロード済みモデルが利用可能。OpenAI 互換クライアントは個人 PC のローカル `http://localhost:1234/v1` を向けるだけで Mac Mini 上の LM Studio に到達します。

---

## 再起動後のリモート復旧手順

Mac Mini が再起動した場合 (停電・macOS アップデート等)、Tailscale と LM Studio LaunchDaemon は自動起動。別の Tailscale 接続済み Mac から `open vnc://<mac-mini-tailscale-ip>` で **claw アカウント**にログインすれば、Gateway LaunchAgent と Google Drive for Desktop が起動するので `openclaw status` と Telegram からの疎通を確認。

---

## バックアップ / リストア

### 自動バックアップ (03 実行時)

03 は既存 `~/.openclaw` を検出すると `~/.openclaw-snapshot-<timestamp>/` に退避してから再構築します (初回セットアップ時はスキップ):

- `~/.openclaw` 全体 → snapshot に `cp -a`
- Google Drive 上の workspace 中身 → snapshot 内 `workspace/` に `mv` で実体化 (Google Drive 上は空になり個人 PC にも反映、復元は 04 で)

snapshot は workspace 実体を含む self-contained なバックアップで、Google Drive から消えても Mac Mini 上に残ります。**OAuth credential も `~/.openclaw` 配下に保存されているため、03 を再実行すると再ログインが必要**になります (snapshot から手動リストアは [手動リストア](#identity--telegram-などを手動リストア) 参照)。

### `04-recover-snapshot.sh` で workspace + cron を復元

```bash
./scripts/04-recover-snapshot.sh ~/.openclaw-snapshot-<ts>
```

- `<snapshot>/workspace/*` → Google Drive 上の `openclaw-workspace` に `cp -a` で書き戻し (個人 PC にも sync)
- `<snapshot>/cron/` → `~/.openclaw/cron` に `cp -a` (既存は削除して置き換え)
- `launchctl kickstart` で LaunchAgent 再ロード (新 cron 反映)

`identity` / `telegram` / `credentials` / `agents` 等は対象外 (下記の手動リストア参照)。

### identity / telegram などを手動リストア

snapshot 内容は普通の OpenClaw ホームディレクトリの中身なので、個別にコピーで戻せます。

```bash
SNAP=~/.openclaw-snapshot-<ts>   # 実際のディレクトリ名に置き換え

launchctl bootout gui/$(id -u)/ai.openclaw.gateway

# identity / telegram / credentials を戻す (再 pairing と再入力を回避)
cp -a "$SNAP/identity" "$SNAP/telegram" "$SNAP/credentials" ~/.openclaw/

# 履歴を戻す
cp -a "$SNAP/agents" "$SNAP/memory" "$SNAP/media" ~/.openclaw/

# cron 定義を戻す
cp -a "$SNAP/cron" ~/.openclaw/

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

| ディレクトリ | 役割 | 復元判断 |
|----|----|----|
| `workspace/` | Google Drive symlink | 不要 (実体は Google Drive 上に残っている) |
| `identity/` | デバイス identity・暗号鍵 | 必須 (再 pairing 回避) |
| `telegram/` | Telegram pairing 状態・update offset | 必須 |
| `credentials/telegram/*.token` | Bot Token | 必須 (再入力回避) |
| `agents/`, `memory/`, `media/` | セッション履歴・累積メモリ・受信メディア | 履歴を引き継ぐ場合 (`agents/` を入れるなら `media/` もセット) |
| `cron/`, `flows/`, `tasks/`, `plugins/`, `skills/` | スケジューラ・ユーザー定義 | カスタムしていれば |
| `openclaw.json` | 設定 | 通常は新生成を使う。`gateway.auth.token` を引き継ぐ場合は token 値だけ抜き出して新 config に書き戻し |
| `openclaw.json.{bak,bak.*,last-good}`, `logs/` | 履歴・キャッシュ | 復元しない |

`openai-codex` の OAuth credential は `~/.openclaw` 配下の auth store に保存されますが、保存パスは公式未公開です。`identity` を含む `~/.openclaw` 全体を `cp -a` で復元しても credential が拾われない場合は、再度 `openclaw models auth login --provider openai-codex --method device-code` でログインし直してください。

復元後は LaunchAgent を再ロード。動作確認できたら `rm -rf "$SNAP"`。

---

## 参考資料

- [OpenClaw 公式 - Install](https://docs.openclaw.ai/install) / [Security](https://docs.openclaw.ai/gateway/security) / [Telegram](https://docs.openclaw.ai/channels/telegram) / [Tailscale](https://docs.openclaw.ai/gateway/tailscale) / [OpenAI provider](https://docs.openclaw.ai/providers/openai)
- [OpenAI Codex CLI 認証](https://developers.openai.com/codex/auth) / [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)
- [LM Studio - Headless mode](https://lmstudio.ai/docs/app/api/headless) / [lms CLI](https://lmstudio.ai/docs/cli) / [LM Link](https://lmstudio.ai/docs/lmlink)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
