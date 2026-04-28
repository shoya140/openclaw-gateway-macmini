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

OpenClawは専用の標準（非管理者）アカウント `claw` で実行する。標準アカウントは管理者グループに属さないため、`sudo` がOSレベルで実行不可。`brew` は claw からは使用不可（`/opt/homebrew` は admin 所有のまま）。これは、claw を乗っ取った攻撃者が brew prefix のバイナリを差し替えて admin 実行時に権限昇格する経路を塞ぐため。CLI tool は mise（aqua/ubi バックエンド）で claw のホーム配下にインストールする。通常のシェルコマンドは自由に実行でき、権限昇格が必要な作業はTelegram経由でユーザーに依頼する。

| レイヤー | 対策 |
|---------|------|
| **OS** | 専用標準アカウント `claw`（sudo・brew いずれも不可）、ファイアウォール + ステルスモード、FileVault無効（リモート復旧優先） |
| **ネットワーク** | Gateway loopback bind、Tailscale Serve（tailnet内のみ）、パブリックポート開放なし、`browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false` |
| **認証** | Gateway トークン認証、Telegram allowlist（DM/グループ別に数値ID限定）、execApprovals有効、controlUi の dangerous flags すべてオフ |
| **アプリケーション** | sandbox mode off（OSアカウント分離で代替、Docker Desktop省略）、coding profile、`tools.deny` で group:automation/runtime/sessions/gateway/cron ブロック、`tools.exec.security: full`（claw 隔離下でエージェントを autonomous に動作させる方針）、CLI tool は mise (aqua/ubi) で claw 配下に隔離 |
| **データ** | `~/.openclaw` mode 700、設定ファイル mode 600、シークレットは `.env` (mode 600) で管理、Spotlight 除外 |
| **可用性** | OPENCLAW_NO_RESPAWN=1 で respawn ループ防止、watchdog LaunchAgent (60秒間隔) で gateway 自己回復 |

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
| `~/.openclaw/` | 設定、認証、エージェント状態、セッション、skill、logs/、scripts/ 等 | claw のみ（管理者は sudo） |
| `~/.openclaw/openclaw.json` | gateway/channels/tools/agents 設定（mode 600） | claw |
| `~/.openclaw/.env` | TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY（mode 600） | claw |
| `~/.openclaw/scripts/watchdog.sh` | watchdog 本体スクリプト | claw |
| `~/.openclaw/logs/watchdog.log` | watchdog による gateway 再起動ログ | claw |
| `~/.openclaw/workspace/` | デフォルトワークスペース（→ Google Driveへのシンボリックリンク） | claw |
| `~/.openclaw-snapshot-<ts>/` | `--reinit` 実行時に自動作成されるスナップショット | claw |
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | OpenClaw Gateway LaunchAgent (`OPENCLAW_NO_RESPAWN=1` 注入済) | claw |
| `~/Library/LaunchAgents/local.openclaw.watchdog.plist` | Watchdog LaunchAgent (60秒間隔) | claw |
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

### スクリプトが行うこと

1. **OpenClawインストール** (`npm install -g openclaw@latest`)

2. **Telegram Bot情報入力** - 以下を対話的に入力:
   - Bot Token (BotFatherから取得)
   - 自分のTelegram User ID (数値)

3. **ワークスペースパス検出 + シンボリックリンク作成** - Google Drive内の `openclaw-workspace` フォルダを自動検出し、`~/.openclaw/workspace` にシンボリックリンクを作成（`agent.workspace` 設定は不要）

4. **AGENTS.md 生成** - ワークスペースにエージェント向けシステムプロンプト (`AGENTS.md`) を配置。mise (aqua/ubi バックエンド) で CLI tool を自分で導入するルール、sudo/brew が必要な作業はユーザーへ依頼するルールを記載

5. **`openclaw.json` 生成** (`~/.openclaw/openclaw.json`)
   - Gateway: loopback bind, port 18789, token auth (自動生成), Tailscale Serve, controlUi の dangerous flags すべて off + 自動検出した Tailscale ホスト名で `allowedOrigins` 設定
   - Telegram: dmPolicy/groupPolicy ともに `allowlist`、`allowFrom`/`groupAllowFrom` 分離、`errorPolicy: always` + `errorCooldownMs: 120000`、`textChunkLimit: 3500`、execApprovals (target: dm)
   - Tools: `coding` profile、`fs.workspaceOnly: true`、`exec.security: full` (claw 隔離下で autonomous 実行)、`deny` に group:automation/runtime/sessions_spawn/sessions_send/gateway/cron
   - Browser: `ssrfPolicy.dangerouslyAllowPrivateNetwork: false`
   - エージェント: デフォルトモデル `anthropic/claude-opus-4-7`、`sandbox.mode: off` (OS アカウント分離で代替)

6. **シークレット設定** - `TELEGRAM_BOT_TOKEN` と `ANTHROPIC_API_KEY` を `~/.openclaw/.env` に保存

7. **ファイルパーミッション設定** (`~/.openclaw`: 700, 設定ファイル: 600, `~/.openclaw/credentials/` 配下のファイル: 600)

8. **Spotlight インデックス除外** - `~/.openclaw/.metadata_never_index` を作成。ワークスペース側にも書き込み可能ならば同様

9. **Gateway デーモン登録・起動・検証**
    ```bash
    openclaw gateway install --force
    # OPENCLAW_NO_RESPAWN=1 を LaunchAgent plist の EnvironmentVariables に注入
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OPENCLAW_NO_RESPAWN string 1" \
      ~/Library/LaunchAgents/ai.openclaw.gateway.plist
    openclaw doctor --fix
    openclaw gateway restart
    # Watchdog LaunchAgent を登録 (60秒ごとに gateway 状態をチェックし、停止していたら kickstart)
    launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/local.openclaw.watchdog.plist
    openclaw security audit
    openclaw security audit --deep
    openclaw doctor
    openclaw status
    ```

10. **Telegram動作確認** - Botへのメッセージ送信を確認

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
| `gateway.controlUi.allowInsecureAuth` | `false` |
| `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback` | `false` |
| `gateway.controlUi.dangerouslyDisableDeviceAuth` | `false` |
| `gateway.controlUi.allowedOrigins` | (Tailscale Serve の URL を自動検出) |
| `channels.telegram.dmPolicy` | `"allowlist"` |
| `channels.telegram.groupPolicy` | `"allowlist"` |
| `channels.telegram.allowFrom` / `groupAllowFrom` | (User ID を分離して設定) |
| `channels.telegram.errorPolicy` | `"always"` (エラー時に常時返信、`errorCooldownMs` でスパム防止) |
| `channels.telegram.errorCooldownMs` | `120000` (スパム防止) |
| `channels.telegram.textChunkLimit` | `3500` |
| `channels.telegram.actions.deleteMessage`/`reactions`/`sticker` | `false` |
| `channels.telegram.execApprovals.enabled` | `true` |
| `channels.telegram.execApprovals.target` | `"dm"` |
| `tools.profile` | `"coding"` |
| `tools.deny` | `["group:automation", "group:runtime", "sessions_spawn", "sessions_send", "gateway", "cron"]` |
| `tools.fs.workspaceOnly` | `true` |
| `tools.exec.security` | `"full"` (claw 隔離下で autonomous 実行、都度承認なし) |
| `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork` | `false` |
| `agents.defaults.model` | `"anthropic/claude-opus-4-7"` (Anthropic Claude Opus 4.7) |
| `agents.defaults.sandbox.mode` | `"off"` (OSアカウント分離で代替) |
| `session.dmScope` | `"per-channel-peer"` |
| `discovery.mdns.mode` | `"minimal"` |
| `logging.redactSensitive` | `"tools"` |

`exec.security: full` のため `~/.openclaw/exec-approvals.json` は生成しない。autonomy 重視で都度承認なしの構成。OS レベルの隔離（claw 標準アカウント、`~/.openclaw` 700、`tools.deny` のグループ単位ブロック、`tools.fs.workspaceOnly`、`browser.ssrfPolicy`）が主防御。

> **補完すべきコスト・ネットワーク制御**: `exec=full` では API 暴走や tailnet ピボットを設定では防げない。以下を別レイヤーで設定推奨:
> - **Anthropic console で月額 spend cap** を設定（API キー流出時の被害金額を有限化）
> - **Tailscale ACL** で Mac Mini ノードから他 tailnet ノードへの egress を制限

### 再インストール（スナップショット + クリーン初期化）

```bash
./scripts/03-openclaw-setup.sh --reinit
```

`--reinit` は以下を行う:
1. **スナップショット作成**: `~/.openclaw-snapshot-<timestamp>/` に `~/.openclaw` 全体をコピー
2. **クリーンアップ**: Watchdog 停止 → Gateway 停止 → LaunchAgent 削除 → npm uninstall → workspace symlink 削除（Google Drive 実体は保持）→ `~/.openclaw/` 削除
3. **再構築**: 上記「スクリプトが行うこと」の通常フローを再実行（Bot Token / User ID / API Key は対話的に再入力）

**スナップショットからの復元はユーザーが手動で行う。** どのファイルを引き継ぐかを把握しておくため、自動復元はしない方針。

#### 手動復元の参考

スナップショット `~/.openclaw-snapshot-<ts>/` から、必要に応じて新しい `~/.openclaw/` にコピーする。

| 復元候補 | コマンド例 | 効果 |
|---------|----------|------|
| Telegram pairing / OAuth トークン | `cp -a ~/.openclaw-snapshot-<ts>/credentials ~/.openclaw/` | 同じ Bot で pairing 再構築不要 |
| エージェント状態 | `cp -a ~/.openclaw-snapshot-<ts>/agents ~/.openclaw/` | 既存セッションのコンテキスト保持 |
| セッション履歴 | `cp -a ~/.openclaw-snapshot-<ts>/sessions ~/.openclaw/` | 過去の会話を保持 |
| インストール済み skill | `cp -a ~/.openclaw-snapshot-<ts>/skills ~/.openclaw/` | skill 再導入不要 |
| TOOLS.md / カスタムファイル | `cp -a ~/.openclaw-snapshot-<ts>/TOOLS.md ~/.openclaw/` | 個別ファイル単位で判断 |

`gateway.auth.token` を引き継ぎたい場合（リモート OpenClaw クライアントの再設定回避）:
```bash
old_token=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw-snapshot-<ts>/openclaw.json'))['gateway']['auth']['token'])")
python3 -c "
import json
p='$HOME/.openclaw/openclaw.json'
c=json.load(open(p))
c['gateway']['auth']['token']='$old_token'
open(p,'w').write(json.dumps(c, indent=2)+'\n')
"
chmod 600 ~/.openclaw/openclaw.json
openclaw gateway restart
```

復元後、サービスを再起動して反映:
```bash
openclaw gateway restart
launchctl kickstart -k "gui/$UID/local.openclaw.watchdog"
```

スナップショットは動作確認後に削除:
```bash
rm -rf ~/.openclaw-snapshot-<ts>
```

完全ロールバック（再インストールをなかったことにする）:
```bash
rm -rf ~/.openclaw && cp -a ~/.openclaw-snapshot-<ts> ~/.openclaw
```

---

## 再起動後のリモート復旧手順

Mac Miniが再起動した場合（停電、macOSアップデート等）の手順:

1. **Tailscaleは自動的にtailnetに接続済み**（LaunchDaemon）
2. 別のTailscale接続済みMacからScreen Sharingで **`claw` アカウント**にログイン:
   ```bash
   open vnc://<mac-mini-tailscale-ip>
   ```
3. `claw` アカウントのパスワードを入力してログイン → OpenClaw Gateway LaunchAgent + watchdog LaunchAgent + Google Drive for Desktop がそれぞれ自動起動
4. Google Driveの同期が完了していることを確認（メニューバーのGoogle Driveアイコン）
5. `openclaw status` で gateway が起動済みであることを確認（万一停止していても 60秒以内に watchdog が `launchctl kickstart` で再起動する）
6. 画面をロック: `Ctrl+Cmd+Q`
7. Telegramからメッセージを送信して動作確認

---

## 運用ガイド

### 管理者作業が必要な場面

claw からは sudo も brew も使えないため、以下は admin での手作業になる:
- `sudo` を要する設定変更（pmset, systemsetup, /Library/LaunchDaemons/ 等）
- `brew install` / `brew install --cask` 全般
- システム全体に影響する変更（FileVault, Tailscale 設定等）

claw 自身が新しい CLI tool を必要とする場合は、mise の aqua/ubi バックエンドで自分でインストールする（admin への依頼は不要）。

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

`claw` アカウントで週次実行（CVE 対応のため OpenClaw 本体の更新も含む）:
```bash
openclaw security audit --deep
openclaw doctor --fix
npm outdated -g openclaw    # 更新があるか確認
```

> **注意**: 2026年1月に 1-click account takeover → RCE の CVE が報告されている。最新版維持が critical。

### アップデート

`claw` アカウントで実行:
```bash
npm update -g openclaw@latest
openclaw gateway restart    # 内部で SIGUSR1 を送るが、OPENCLAW_NO_RESPAWN=1 で respawn ループ防止
openclaw security audit
```

restart が不安定な場合は launchd に直接 kickstart を発火:
```bash
launchctl kickstart -k "gui/$UID/ai.openclaw.gateway"
```

Node.jsのアップデートが必要な場合も `claw` アカウントで（mise経由）:
```bash
mise use -g node@24
```

### Skill / MCP サーバーのインストール

> **注意**: 2026年1月の ClawHavoc キャンペーンで ClawHub レジストリの skill 数百件にマルウェア混入。

skill を導入する場合のルール:
- 自動更新は**無効**（バージョンピン）
- 公式署名付きのみ
- 導入前に `openclaw security audit --deep` でベースラインを取り、導入後と比較
- skill のソースを目視レビュー

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
tail -f ~/.openclaw/logs/watchdog.log    # watchdog による gateway 自動再起動の履歴
```

### インシデント対応手順

問題が発生した場合の即座の対応:

1. **Gatewayの停止 + watchdog の停止** (`claw` アカウント)
   ```bash
   launchctl bootout "gui/$UID/local.openclaw.watchdog"
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
   openclaw logs --follow
   tail -100 ~/.openclaw/logs/watchdog.log
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
