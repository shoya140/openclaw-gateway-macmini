# OpenClaw Gateway on Mac Mini

Mac MiniにOpenClawをインストールし、Telegramから利用するためのセットアップスクリプト + 運用マニュアル。

## アーキテクチャ

```
[Telegram] <---> [OpenClaw Gateway (localhost:18789)] <---> [LLM API (Anthropic/OpenAI等)]
                        ↑
              [Tailscale Serve (tailnet内のみアクセス可)]
```

- OpenClaw GatewayはMac Mini上でlocalhostにバインド
- 外部アクセスはTailscale Serve経由（tailnet内のみ）
- Telegramとの通信はOpenClawのTelegramチャネル機能で実現
- パブリックインターネットへのポート公開なし

## セキュリティモデル

OpenClawは専用の標準（非管理者）アカウント `claw` で実行する。標準アカウントは管理者グループに属さないため、`sudo` がOSレベルで実行不可。`brew` も未インストール。通常のシェルコマンドは自由に実行でき、権限昇格が必要な作業はTelegram経由でユーザーに依頼する。

| レイヤー | 対策 |
|---------|------|
| **OS** | 専用標準アカウント `claw`（sudo不可）、ファイアウォール + ステルスモード、FileVault無効（リモート復旧優先） |
| **ネットワーク** | Gateway loopback bind、Tailscale Serve（tailnet内のみ）、パブリックポート開放なし |
| **認証** | Gateway トークン認証、Telegram allowlist（数値ID限定）、execApprovals有効 |
| **アプリケーション** | sandbox mode off (OSアカウント分離で代替)、coding profile、AGENTS.mdでsudo/brew依頼ルール |
| **データ** | `~/.openclaw` mode 700、設定ファイル mode 600、シークレットは `.env` (mode 600) で管理 |

## プロジェクト構成

```
scripts/
  01-admin-macos-setup.sh     # 管理者: macOSセキュリティ + Tailscale + clawアカウント
  02-claw-user-setup.sh       # claw: Google Drive + mise + Node.js
  03-openclaw-setup.sh        # claw: OpenClawインストール・設定（--reinitで再インストール可）
README.md                     # 本ドキュメント（セットアップガイド + 運用マニュアル）
PLAN.md                       # 計画書・作業ステップ
LOG.md                        # 作業ログ
```

## ディレクトリ構成（Mac Mini上）

| パス | 内容 | アクセス |
|------|------|---------|
| `~/.openclaw/` | 設定、認証、セッション等 | claw のみ（管理者は sudo） |
| `~/.openclaw/workspace/` | デフォルトワークスペース（→ Google Driveへのシンボリックリンク） | claw |
| `~/Library/CloudStorage/GoogleDrive-.../My Drive/openclaw-workspace/` | ワークスペース実体（Google Drive同期） | claw（Google Drive経由で個人PCと共有） |
| `~/Library/CloudStorage/GoogleDrive-.../My Drive/openclaw-workspace/AGENTS.md` | エージェント向けシステムプロンプト | claw |

---

## 前提条件

- Mac Mini (Apple Silicon推奨)
- macOS 15以降
- インターネット接続
- Homebrewインストール済み（管理者アカウント）
- Telegramアカウント
- LLM APIキー (Anthropic, OpenAI等)
- Open Claw専用Googleアカウント（事前に作成済み）
- 個人のGoogle Driveでワークスペースフォルダ `openclaw-workspace` を作成し、Open Clawアカウントを「編集者」として共有済み

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

---

## Phase 1: macOS Admin Setup

> **管理者アカウント**で実行する。

### 実行

```bash
./scripts/01-admin-macos-setup.sh
```

### スクリプトが行うこと

1. **ファイアウォール + ステルスモード有効化**
   ```bash
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
   ```

2. **管理者ホームディレクトリ保護** (`chmod 700 ~/`)

3. **スリープ防止設定** (24/7運用)
   ```bash
   sudo pmset -a sleep 0 disksleep 0 displaysleep 0
   sudo pmset -a hibernatemode 0 powernap 0
   sudo pmset -a standby 0 autopoweroff 0
   sudo pmset -a autorestart 1
   ```

4. **自動ログイン無効化**
   ```bash
   sudo sysadminctl -autologin off
   ```

5. **Screen Sharing有効化** - CLIで有効化を試みるが、macOS 12.1+のTCC制限により手動設定が必要な場合がある
   - CLIで有効化できない場合、スクリプトがGUI操作を指示する
   - VNCパスワードアクセスは手動で無効化する必要あり（Tailscale経由のみ使用のため）

6. **SSH (リモートログイン) 有効化**
   ```bash
   sudo systemsetup -setremotelogin on
   ```

7. **Tailscaleインストール・認証** (`brew install tailscale` → `sudo brew services start tailscale` → `sudo tailscale up`)

8. **`claw` 標準アカウント作成** - パスワード入力を求められる
   ```bash
   sudo sysadminctl -addUser claw -fullName "OpenClaw" -password "<password>"
   ```

9. **Google Drive for Desktopインストール** (`brew install --cask google-drive`)

10. **Tailscale Serve設定**
    ```bash
    sudo tailscale serve --bg http://127.0.0.1:18789
    ```

### FileVaultについて

FileVaultは**無効のまま**とする。有効にするとコールドブート時に物理的なパスワード入力が必須となり、停電後のリモート復旧ができなくなるため。

### 手動で確認が必要な項目

- Screen Sharing の VNCパスワードアクセスが無効であること
- 再起動後にTailscaleが自動接続されること（`tailscale status`）

---

## Phase 2: Claw User Setup

> **`claw` アカウント**で実行する（Screen Sharing等でclawにログイン）。

### 実行

```bash
./scripts/02-claw-user-setup.sh
```

### スクリプトが行うこと

1. **Google Driveセットアップ** (GUI操作) - スクリプトがGoogle Driveアプリを起動し、以下の手順を指示する:
   - Open Claw専用Googleアカウントでサインイン
   - 同期モードを「ミラーリング」に設定
   - 共有フォルダをMy Driveに追加

2. **miseインストール** (`curl https://mise.run | sh` + シェル統合)

3. **Node.jsインストール** (`mise use -g node@24`)

4. **権限制限の確認** - sudo/brewが使えないことを自動検証

---

## Phase 3: OpenClaw Setup

> **`claw` アカウント**で実行する。

### 初回インストール

```bash
./scripts/03-openclaw-setup.sh
```

### 再インストール（初期化 + 再セットアップ）

```bash
./scripts/03-openclaw-setup.sh --reinit
```

`--reinit` は以下を行う:
- Gateway停止
- LaunchAgent削除
- 設定ファイルを `/tmp/` にバックアップ
- OpenClawアンインストール (`npm uninstall -g openclaw`)
- ワークスペースのシンボリックリンクを削除（Google Driveの実体は保持）
- `~/.openclaw/` を削除（`.env` 含むシークレットも削除）
- その後、通常のインストールフローを実行

### スクリプトが行うこと

1. **OpenClawインストール** (`npm install -g openclaw@latest`)

2. **Telegram Bot情報入力** - 以下を対話的に入力:
   - Bot Token (BotFatherから取得)
   - 自分のTelegram User ID (数値)

3. **ワークスペースパス検出 + シンボリックリンク作成** - Google Drive内の `openclaw-workspace` フォルダを自動検出し、`~/.openclaw/workspace` にシンボリックリンクを作成（`agent.workspace` 設定は不要）

3.5. **AGENTS.md 生成** - ワークスペースにエージェント向けシステムプロンプト (`AGENTS.md`) を配置

4. **設定ファイル生成** (`~/.openclaw/openclaw.json`)
   - Gateway: loopback bind, port 18789, token auth (自動生成), Tailscale Serve
   - Telegram: allowlistベースDM/グループポリシー, execApprovals
   - Tools: coding profile, ワークスペース限定FS, exec full
   - エージェント: sandbox off (OSレベルのアカウント分離で代替)

5. **シークレット設定** - `TELEGRAM_BOT_TOKEN` と `ANTHROPIC_API_KEY` を `~/.openclaw/.env` に保存

7. **ファイルパーミッション設定** (`~/.openclaw`: 700, 設定ファイル: 600)

8. **Gatewayデーモン登録・起動・検証**
   ```bash
   openclaw gateway install --force
   openclaw doctor --fix
   openclaw gateway restart
   openclaw security audit
   openclaw security audit --deep
   openclaw doctor
   openclaw status
   ```

9. **Telegram動作確認** - Botへのメッセージ送信を確認

### Telegram Bot の事前準備

スクリプト実行前にBotを作成しておく:

1. Telegramで `@BotFather` を検索してチャットを開く
2. `/newbot` を送信
3. Bot名とユーザー名を入力
4. 表示される **Bot Token** を安全にコピー
5. グループで使う場合: `/setprivacy` → 作成したBotを選択 → `Disable`

自分のTelegram User IDは `@userinfobot` にメッセージを送って確認できる。

### 生成される設定ファイルの内容

スクリプトが生成する `~/.openclaw/openclaw.json` の主要設定:

| 設定項目 | 値 |
|---------|-----|
| `gateway.mode` | `"local"` |
| `gateway.port` | `18789` |
| `gateway.bind` | `"loopback"` |
| `gateway.auth.mode` | `"token"` |
| `gateway.auth.token` | (スクリプトが自動生成) |
| `gateway.tailscale.mode` | `"serve"` |
| `channels.telegram.dmPolicy` | `"allowlist"` |
| `channels.telegram.groupPolicy` | `"allowlist"` |
| `channels.telegram.execApprovals.enabled` | `true` |
| `tools.profile` | `"coding"` |
| `tools.deny` | `["sessions_spawn", "sessions_send", "gateway", "cron"]` |
| `tools.fs.workspaceOnly` | `true` |
| `tools.exec.security` | `"full"` |
| `agents.defaults.sandbox.mode` | `"off"` |
| `session.dmScope` | `"per-channel-peer"` |
| `discovery.mdns.mode` | `"minimal"` |
| `logging.redactSensitive` | `"tools"` |

---

## 再起動後のリモート復旧手順

Mac Miniが再起動した場合（停電、macOSアップデート等）の手順:

1. **Tailscaleは自動的にtailnetに接続済み**（LaunchDaemon）
2. 別のTailscale接続済みMacからScreen Sharingで **`claw` アカウント**にログイン:
   ```bash
   open vnc://<mac-mini-tailscale-ip>
   ```
3. `claw` アカウントのパスワードを入力してログイン → OpenClaw LaunchAgent + Google Drive for Desktopが自動起動
4. Google Driveの同期が完了していることを確認（メニューバーのGoogle Driveアイコン）
5. 画面をロック: `Ctrl+Cmd+Q`
6. Telegramからメッセージを送信して動作確認

---

## 運用ガイド

### 管理者作業が必要な場面

OpenClawがTelegram経由で管理者権限が必要な作業を依頼してきた場合:

1. SSH or Screen Sharingで**管理者アカウント**にログイン
2. OpenClawが提示したコマンドを実行
3. Telegramで完了を報告

### ワークスペースのバージョン管理

ワークスペースはGoogle Drive経由で個人PCと同期される。**git管理は個人PC側でのみ行う。**

#### 個人PC側の初期設定

Google Drive内のワークスペースで普通にgit initする:

```bash
cd ~/Library/CloudStorage/GoogleDrive-<personal-account>/My\ Drive/openclaw-workspace
git init
git config user.name "個人の名前"
git config user.email "個人のメール"
```

`.git`はGoogle Drive経由でMac Mini側にも同期されるが、Mac Mini側のエージェントはgitを使わないため問題なし。git操作は個人PCでのみ行う。

推奨 `.gitignore`:
```
*.log
*.jsonl
node_modules/
.env
.env.local
credentials/
.DS_Store
```

### 定期セキュリティ監査

`claw` アカウントで週次実行:
```bash
openclaw security audit --deep
openclaw doctor --fix
```

### アップデート

`claw` アカウントで実行:
```bash
npm update -g openclaw@latest
openclaw gateway restart
openclaw security audit
```

Node.jsのアップデートが必要な場合も `claw` アカウントで（mise経由）:
```bash
mise use -g node@24
```

### APIキーのローテーション

`claw` アカウントで `~/.openclaw/.env` の `ANTHROPIC_API_KEY` を更新し、Gateway再起動:
```bash
vi ~/.openclaw/.env
openclaw gateway restart
```

### ログの確認

```bash
openclaw logs --follow
openclaw status --all
```

### インシデント対応手順

問題が発生した場合の即座の対応:

1. **Gatewayの停止** (`claw` アカウント)
   ```bash
   openclaw gateway stop
   ```

2. **ネットワーク遮断** (管理者アカウント)
   ```bash
   tailscale serve --remove
   ```

3. **Telegram DMを無効化** (`claw` アカウントの設定ファイルで)
   ```json
   { "channels": { "telegram": { "dmPolicy": "disabled" } } }
   ```

4. **認証情報のローテーション** (`claw` アカウント)
   ```bash
   openclaw doctor --generate-gateway-token
   vi ~/.openclaw/.env   # ANTHROPIC_API_KEY を更新
   openclaw gateway restart
   ```

5. **監査とログ確認** (`claw` アカウント)
   ```bash
   openclaw security audit --deep
   less /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
   ls ~/.openclaw/agents/*/sessions/
   ```

---

## リモートアクセス (別デバイスからの利用)

### SSHトンネル経由 (Tailscale上)

```bash
ssh -N -L 18789:127.0.0.1:18789 claw@<mac-mini-tailscale-ip>
```

### リモートクライアント設定

別デバイスの `~/.openclaw/openclaw.json`:
```json
{
  "gateway": {
    "mode": "remote",
    "remote": {
      "url": "ws://127.0.0.1:18789",
      "token": "Mac Mini側のgateway authトークン"
    }
  }
}
```

```bash
openclaw tui
```

---

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Security Hardening Guide](https://aimaker.substack.com/p/openclaw-security-hardening-guide)
