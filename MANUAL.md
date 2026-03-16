# OpenClaw セキュアインストール マニュアル (Mac Mini + Telegram)

Mac MiniにOpenClawを最もセキュアにインストールし、Telegramから利用するための手順書。

**セキュリティモデル:** OpenClawは専用の標準（非管理者）アカウント `claw` で実行する。標準アカウントは管理者グループに属さないため、`sudo` がOSレベルで実行不可。`brew` も未インストール。通常のシェルコマンドは自由に実行でき、権限昇格が必要な作業はTelegram経由でユーザーに依頼する。

---

## 前提条件

- Mac Mini (Apple Silicon推奨)
- macOS 15以降
- インターネット接続
- Telegramアカウント
- LLM APIキー (Anthropic, OpenAI等)

---

## Phase 1: macOSセキュリティ基盤の構築

> 以下はすべて**管理者アカウント**で実行する。

### 1.1 FileVaultについて

FileVaultは**無効のまま**とする。有効にするとコールドブート時に物理的なパスワード入力が必須となり、停電後のリモート復旧ができなくなるため。

代わりに、自動ログインを無効化し、Screen Sharing経由のリモートログイン運用で物理アクセスを保護する（Phase 1.5参照）。

### 1.2 ファイアウォールとステルスモードの有効化

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
```

確認:
```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode
```

### 1.3 ホームディレクトリのアクセス制限

```bash
chmod 700 ~/
```

### 1.4 スリープ防止設定 (24/7運用の場合)

```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 0
sudo pmset -a hibernatemode 0 powernap 0
sudo pmset -a standby 0 autopoweroff 0
sudo pmset -a autorestart 1
```

### 1.5 自動ログインは無効のまま

自動ログインは**有効にしない**。物理的にディスプレイとキーボードを接続した第三者にデスクトップを操作される防止のため。

確認:
```
システム設定 → ユーザとグループ → ログインオプション → 自動ログイン: オフ
```

### 1.6 Screen Sharingの有効化 (リモートログイン用)

再起動後にTailscale経由でリモートからログインするためにScreen Sharingを有効化する。

```
システム設定 → 一般 → 共有 → 画面共有 → オンにする
```

設定のポイント:
- **アクセスを許可するユーザー**: 管理者アカウントと `claw` アカウントの両方
- **VNC利用者がパスワードでスクリーンを操作することを許可**: 無効（Tailscale経由のみで使うため不要）

Screen SharingはTailscale経由でのみアクセスする（ファイアウォール+ステルスモードにより、LAN側からの直接アクセスはブロックされる）。

### 1.7 リモートログイン (SSH) の有効化

```
システム設定 → 一般 → 共有 → リモートログイン → オンにする
```

SSHもTailscale経由でのみ使用する。

---

## Phase 2: Tailscaleのインストール・設定 (システムレベル)

> **管理者アカウント**で実行する。

Tailscaleはシステムレベルデーモン（LaunchDaemon）として起動する。これにより、**ユーザーがログインしていない状態（ログイン画面）でもtailnetに接続**され、Screen SharingやSSHでリモートログインが可能になる。

### 2.1 Tailscaleのインストール

```bash
brew install tailscale
```

### 2.2 システムレベルでデーモンを起動

`sudo` 付きで `brew services start` を実行すると、`/Library/LaunchDaemons/` にplistが作成され、macOS起動時にroot権限で自動起動する。

```bash
sudo brew services start tailscale
```

### 2.3 tailnetへの認証

```bash
sudo tailscale up
```

表示されるURLをブラウザで開き、認証を完了する。

### 2.4 接続確認

```bash
tailscale status
```

自分のtailnet内のデバイスが表示されることを確認。

### 2.5 再起動テスト

Mac Miniを再起動し、ログイン画面の状態で別のTailscale接続済みデバイスからTailscaleの接続を確認:

```bash
tailscale status
```

Mac Miniが `online` と表示されていればOK。ステルスモードが有効なためpingには応答しない。

### 2.6 Screen Sharing経由でのリモートログイン確認

別のTailscale接続済みMacから:

```bash
open vnc://<mac-mini-tailscale-ip>
```

ログイン画面が表示され、パスワードを入力してログインできることを確認。ログイン後、画面をロック (`Ctrl+Cmd+Q`)。

---

## Phase 3: 専用標準アカウントの作成

> **管理者アカウント**で実行する。

OpenClaw実行専用の標準（非管理者）アカウントを作成する。標準アカウントは管理者グループ (`admin`) に属さないため、**`sudo` がOSレベルで実行不可**となる。

### 3.1 アカウント作成

```bash
sudo sysadminctl -addUser claw -fullName "OpenClaw" -password "<強力なパスワード>"
```

**注意:** `-admin` フラグは付けない（標準アカウントとして作成される）。

### 3.2 アカウントの確認

管理者グループに含まれていないことを確認:
```bash
dscl . -read /Groups/admin GroupMembership
```

出力に `claw` が含まれていなければOK。

### 3.3 ホームディレクトリの保護

```bash
sudo chmod 700 /Users/claw
```

### 3.4 共有ワークスペースディレクトリの作成

管理者アカウントとclawアカウントが共同で使用するワークスペースディレクトリを作成する。OpenClawのデフォルトワークスペース（`~/.openclaw/workspace`）の代わりに、管理者がsudoなしでgit操作できる場所に配置する。

```bash
sudo mkdir -p /opt/openclaw/workspace
sudo chown claw:staff /opt/openclaw/workspace
sudo chmod 755 /opt/openclaw
sudo chmod 770 /opt/openclaw/workspace
```

管理者ユーザーもアクセスできるようにACLを追加:
```bash
sudo chmod +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit" /opt/openclaw/workspace
```

### 3.5 miseのインストール

clawアカウントにログインして実行:
```bash
su - claw
```

miseをインストール（sudo/brew不要）:
```bash
curl https://mise.run | sh
```

シェルへの統合:
```bash
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

### 3.6 Node.jsのインストール（mise経由）

```bash
mise use -g node@24
```

確認:
```bash
node --version
npm --version
```

### 3.7 制限の確認

clawアカウントで以下が失敗することを確認:
```bash
sudo echo "test"
# → パスワード入力を求められ、入力しても「<ユーザー名> is not in the sudoers file」で拒否される

brew install something
# → command not found (brewはclawアカウントにインストールされていない)
```

---

## Phase 4: OpenClawのインストール

> 以下は **`claw` アカウント**で実行する（Phase 3.5から継続）。

### 4.1 OpenClawのインストール

```bash
npm install -g openclaw@latest
openclaw onboard --install-daemon
```

### 4.2 インストール確認

```bash
openclaw doctor
openclaw status
```

---

## Phase 5: Telegram Botの作成

### 5.1 BotFatherでBot作成

1. Telegramで `@BotFather` を検索してチャットを開く
2. `/newbot` を送信
3. Bot名を入力 (例: `My OpenClaw Bot`)
4. Bot用のユーザー名を入力 (例: `my_openclaw_bot`)
5. 表示される **Bot Token** を安全にコピーする

### 5.2 プライバシーモードの無効化 (グループ利用時のみ)

グループチャットで全メッセージを受信する場合:

1. `@BotFather` で `/setprivacy` を送信
2. 作成したBotを選択
3. `Disable` を選択

### 5.3 自分のTelegram User IDの取得

Botにメッセージを送信してから:
```bash
openclaw logs --follow
```

ログの `from.id` フィールドからUser IDを確認する。

または、Telegramで `@userinfobot` にメッセージを送って確認。

---

## Phase 6: OpenClawのセキュア設定

> **`claw` アカウント**で実行する。

### 6.1 設定ファイルの編集

```bash
vim ~/.openclaw/openclaw.json
```

以下の設定を適用:

```json5
{
  // === Gateway設定 ===
  gateway: {
    bind: "loopback",

    auth: {
      mode: "token",
    },

    tailscale: {
      mode: "serve",
    },

    controlUi: {
      allowInsecureAuth: false,
    },
  },

  // === Telegramチャネル設定 ===
  channels: {
    telegram: {
      // BotFatherから取得したトークン（環境変数推奨）
      // botToken: は環境変数 TELEGRAM_BOT_TOKEN で設定

      // DM設定: allowlistで自分のみ許可
      dmPolicy: "allowlist",
      allowFrom: [
        YOUR_TELEGRAM_USER_ID,  // 数値IDに置き換える
      ],

      // グループ設定: デフォルトで全ブロック
      groupPolicy: "allowlist",

      // メディア制限
      mediaMaxMb: 20,

      // リトライ設定
      retry: {
        attempts: 3,
        minDelayMs: 100,
        maxDelayMs: 5000,
        jitter: true,
      },
      timeoutSeconds: 30,

      // アクション制限
      actions: {
        deleteMessage: false,
        sticker: false,
      },

      // 実行承認 (自分のみ承認可能)
      execApprovals: {
        enabled: true,
        approvers: [YOUR_TELEGRAM_USER_ID],
        target: "dm",
      },
    },
  },

  // === エージェントワークスペース ===
  agent: {
    workspace: "/opt/openclaw/workspace",
  },

  // === エージェント設定 ===
  agents: {
    defaults: {
      sandbox: {
        mode: "exec",
        workspaceAccess: "rw",
      },

      tools: {
        profile: "developer",
        deny: [
          "sessions_spawn",
          "sessions_send",
          "gateway",
          "cron",
        ],
        fs: {
          workspaceOnly: false,
          deny: [
            "/Users/*/.*",         // 他ユーザーのdotfiles
            "/etc/**",
            "/Library/**",
          ],
        },
        exec: {
          security: "sandbox",
        },
      },

      // エージェントへの指示
      systemPrompt: `
あなたはclawアカウント（標準・非管理者）で動作しています。

## 環境
- ランタイム管理: mise（~/.local/bin/mise）
  - 新しいランタイムが必要な場合は `mise use -g <tool>@<version>` で自分でインストールできます
  - 例: `mise use -g python@3.12`, `mise use -g go@1.22`
- Node.js: mise経由でインストール済み

## シェルコマンドの実行ルール
- 通常のシェルコマンド（git, node, npm, python, ファイル操作, ビルド, テスト等）は自由に実行してください。
- miseで管理可能なランタイムのインストール・バージョン変更は自分で実行してください。
- 以下の操作は自分では実行できません。必要な場合はユーザーに実行すべきコマンド群を提示し、管理者アカウントでの手動実行を依頼してください:
  - sudo を必要とする操作（システム設定変更、サービス管理、パーミッション変更等）
  - brew を必要とする操作（ソフトウェアのインストール・アンインストール）
  - LaunchDaemonの作成・変更（/Library/LaunchDaemons/）
  - システム全体に影響する設定変更

## 依頼時のフォーマット
ユーザーへの依頼は以下の形式で送信してください:

🔧 管理者権限が必要な作業があります

実行が必要なコマンド:
\`\`\`bash
# （ここにコマンドを記述）
\`\`\`

理由: （なぜこの作業が必要か簡潔に）

完了したら教えてください。

## ワークスペース
- 作業ディレクトリ: /opt/openclaw/workspace
`,
    },
  },

  // === セッション設定 ===
  session: {
    dmScope: "per-channel-peer",
  },

  // === ログ設定 ===
  logging: {
    redactSensitive: "tools",
  },

  // === mDNS設定 ===
  discovery: {
    mdns: {
      mode: "minimal",
    },
  },
}
```

### 6.2 Telegram Bot Tokenの安全な設定

設定ファイルにトークンを直書きせず、環境変数で管理:

```bash
vim ~/.zprofile
```

以下の行を追加:
```
export TELEGRAM_BOT_TOKEN="<BotFatherから取得したトークン>"
```

`vim` で直接編集することで、トークンがシェル履歴に残ることを防ぐ。

### 6.3 LLM APIキーの安全な設定

auth profilesを使用してキーチェーンに保存:
```bash
openclaw auth add anthropic
```

プロンプトに従いAPIキーを入力。キーはmacOSキーチェーンに安全に保存される。

### 6.4 ファイルパーミッションの確認

```bash
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
find ~/.openclaw/credentials -type f -exec chmod 600 {} \;
```

---

## Phase 7: Tailscale Serveの設定

> **管理者アカウント**で実行する。

### 7.1 OpenClaw GatewayをTailscale経由で公開

```bash
tailscale serve --bg http://127.0.0.1:18789
```

**重要:** `http://` を使用すること（`https+insecure://` ではない）。
**重要:** `tailscale funnel` は**絶対に使用しない**（パブリックインターネットに公開されてしまう）。

### 7.2 確認

別のTailscale接続済みデバイスから:
```
https://<mac-mini-hostname>.your-tailnet.ts.net
```

にアクセスしてControl UIが表示されることを確認。

---

## Phase 8: Gatewayの起動と動作確認

> **`claw` アカウント**で実行する。

### 8.1 Gateway起動

```bash
openclaw gateway restart
```

### 8.2 セキュリティ監査

```bash
openclaw security audit
openclaw security audit --deep
```

**Critical** または **High** の指摘がないことを確認。指摘がある場合:
```bash
openclaw security audit --fix
```

### 8.3 Telegramからの動作確認

1. Telegramで作成したBotにDMを送信
2. 応答が返ってくることを確認
3. allowlistに含まれない別ユーザーからのメッセージがブロックされることを確認

### 8.4 権限分離の動作確認

Telegramからsudoが必要な作業を指示し、エージェントが以下の動作をすることを確認:
1. 自分でsudoを実行しようとしない
2. ユーザーに実行すべきコマンドを提示する
3. ユーザーの完了報告を待ってから次の作業に進む

### 8.5 ステータス確認

```bash
openclaw status --all
openclaw dashboard
```

---

## Phase 9: 自動起動の設定 (LaunchAgent)

> **`claw` アカウント**で実行する。

OpenClawのGatewayをLaunchAgentとして登録する。LaunchAgentは `claw` ユーザーのログイン時に自動起動する。

```bash
openclaw onboard --install-daemon
```

確認:
```bash
launchctl list | grep openclaw
```

**注意:** LaunchAgentはユーザーセッション開始後に起動するため、再起動後は `claw` アカウントへのリモートログインが必要（Phase 2.6参照）。

---

## 再起動後のリモート復旧手順

Mac Miniが再起動した場合（停電、macOSアップデート等）の手順:

1. **Tailscaleは自動的にtailnetに接続済み**（LaunchDaemon）
2. 別のTailscale接続済みMacからScreen Sharingで **`claw` アカウント**にログイン:
   ```bash
   open vnc://<mac-mini-tailscale-ip>
   ```
3. `claw` アカウントのパスワードを入力してログイン → OpenClaw LaunchAgentが自動起動
4. 画面をロック: `Ctrl+Cmd+Q`
5. Telegramからメッセージを送信して動作確認

---

## 運用ガイド

### 管理者作業が必要な場面

OpenClawがTelegram経由で管理者権限が必要な作業を依頼してきた場合:

1. SSH or Screen Sharingで**管理者アカウント**にログイン
2. OpenClawが提示したコマンドを実行
3. Telegramで完了を報告

### ワークスペースのバージョン管理

ワークスペース（`/opt/openclaw/workspace`）は管理者のgitアカウントでバージョン管理する。管理者はsudoなしで直接git操作が可能。

初期設定（管理者アカウントで実行）:
```bash
cd /opt/openclaw/workspace
git init
git config user.name "管理者の名前"
git config user.email "管理者のメール"
```

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

`claw` アカウントで実行:
```bash
openclaw auth rotate anthropic
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
   ```json5
   channels: { telegram: { dmPolicy: "disabled" } }
   ```

4. **認証情報のローテーション** (`claw` アカウント)
   ```bash
   openclaw auth rotate-gateway-token
   openclaw auth rotate anthropic
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
```json5
{
  gateway: {
    mode: "remote",
    remote: {
      url: "ws://127.0.0.1:18789",
      token: "Mac Mini側のgateway authトークン",
    },
  },
}
```

```bash
openclaw tui
```

---

## セキュリティチェックリスト

| 項目 | 確認 |
|------|------|
| **OS・ネットワーク** | |
| FileVault無効 (意図的) | [ ] |
| 自動ログイン無効 | [ ] |
| ファイアウォール + ステルスモード有効化 | [ ] |
| Screen Sharing有効 (Tailscale経由のみ) | [ ] |
| Tailscale (Homebrew版, `sudo brew services` でLaunchDaemon化) | [ ] |
| 再起動後にTailscale自動接続確認済み | [ ] |
| **アカウント分離** | |
| `claw` が標準（非管理者）アカウントである | [ ] |
| `claw` が `admin` グループに属していない | [ ] |
| `claw` から `sudo` が実行不可 | [ ] |
| `claw` から `brew install` が実行不可 | [ ] |
| `/Users/claw` mode 700 | [ ] |
| 共有ワークスペース (`/opt/openclaw/workspace`) のパーミッション正常 | [ ] |
| `agent.workspace` が `/opt/openclaw/workspace` に設定済み | [ ] |
| **OpenClaw設定** | |
| `~/.openclaw` mode 700 | [ ] |
| `openclaw.json` mode 600 | [ ] |
| `gateway.bind: "loopback"` | [ ] |
| Gateway認証トークン設定済み | [ ] |
| Tailscale Serve (Funnelではない) | [ ] |
| Telegram `dmPolicy: "allowlist"` | [ ] |
| Telegram `groupPolicy: "allowlist"` | [ ] |
| 数値User IDのみ使用 | [ ] |
| Telegram Bot Token環境変数で管理 | [ ] |
| APIキーはauth profiles/キーチェーンで管理 | [ ] |
| `sandbox.mode: "exec"` | [ ] |
| `tools.profile: "developer"` | [ ] |
| systemPromptにsudo/brew依頼ルール設定済み | [ ] |
| `execApprovals.enabled: true` | [ ] |
| `discovery.mdns.mode: "minimal"` | [ ] |
| `logging.redactSensitive: "tools"` | [ ] |
| `openclaw security audit --deep` 通過 | [ ] |
| ClawHubスキル未検証のものなし | [ ] |
| **動作確認** | |
| Telegramからの応答確認済み | [ ] |
| sudo要求時にユーザーへの依頼動作確認済み | [ ] |

---

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Security Hardening Guide](https://aimaker.substack.com/p/openclaw-security-hardening-guide)
