# OpenClaw セキュアインストール マニュアル (Mac Mini + Telegram)

Mac MiniにOpenClawを最もセキュアにインストールし、Telegramから利用するための手順書。

---

## 前提条件

- Mac Mini (Apple Silicon推奨)
- macOS 15以降
- インターネット接続
- Telegramアカウント
- LLM APIキー (Anthropic, OpenAI等)

---

## Phase 1: macOSセキュリティ基盤の構築

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

caffeinate永続化 (LaunchAgent):
```bash
cat > ~/Library/LaunchAgents/com.openclaw.caffeinate.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openclaw.caffeinate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-s</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.openclaw.caffeinate.plist
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
- **アクセスを許可するユーザー**: 「現在のユーザーのみ」に制限
- **VNC利用者がパスワードでスクリーンを操作することを許可**: 無効（Tailscale経由のみで使うため不要）

Screen SharingはTailscale経由でのみアクセスする（ファイアウォール+ステルスモードにより、LAN側からの直接アクセスはブロックされる）。

### 1.7 リモートログイン (SSH) の有効化

```
システム設定 → 一般 → 共有 → リモートログイン → オンにする
```

SSHもTailscale経由でのみ使用する。

---

## Phase 2: Tailscaleのインストール・設定 (システムレベル)

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

Mac Miniを再起動し、ログイン画面の状態で別のTailscale接続済みデバイスからpingが通ることを確認:

```bash
ping <mac-mini-tailscale-ip>
```

### 2.6 Screen Sharing経由でのリモートログイン確認

別のTailscale接続済みMacから:

```bash
open vnc://<mac-mini-tailscale-ip>
```

ログイン画面が表示され、パスワードを入力してログインできることを確認。ログイン後、画面をロック (`Ctrl+Cmd+Q`)。

---

## Phase 3: OpenClawのインストール

### 3.1 Node.jsのインストール

```bash
brew install node@24
```

Node 24が推奨。Node 22 LTS (22.16+) も対応。

### 3.2 OpenClawのインストール

**方法A: インストーラスクリプト (推奨)**
```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

**方法B: npm直接インストール**
```bash
npm install -g openclaw@latest
openclaw onboard --install-daemon
```

### 3.3 インストール確認

```bash
openclaw doctor
openclaw status
```

---

## Phase 4: Telegram Botの作成

### 4.1 BotFatherでBot作成

1. Telegramで `@BotFather` を検索してチャットを開く
2. `/newbot` を送信
3. Bot名を入力 (例: `My OpenClaw Bot`)
4. Bot用のユーザー名を入力 (例: `my_openclaw_bot`)
5. 表示される **Bot Token** を安全にコピーする

### 4.2 プライバシーモードの無効化 (グループ利用時のみ)

グループチャットで全メッセージを受信する場合:

1. `@BotFather` で `/setprivacy` を送信
2. 作成したBotを選択
3. `Disable` を選択

### 4.3 自分のTelegram User IDの取得

Botにメッセージを送信してから:
```bash
openclaw logs --follow
```

ログの `from.id` フィールドからUser IDを確認する。

または、Telegramで `@userinfobot` にメッセージを送って確認。

---

## Phase 5: OpenClawのセキュア設定

### 5.1 設定ファイルの編集

```bash
nano ~/.openclaw/openclaw.json
```

以下のセキュア設定を適用:

```json5
{
  // === Gateway設定 ===
  gateway: {
    bind: "loopback",

    auth: {
      mode: "token",
      // トークンはonboard時に自動生成される。手動設定する場合:
      // token: "ランダムな長い文字列"
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
      // 必要に応じてグループを追加:
      // groups: {
      //   "-1001234567890": {
      //     allowFrom: [YOUR_TELEGRAM_USER_ID],
      //   },
      // },

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

  // === エージェント設定 ===
  agents: {
    defaults: {
      sandbox: {
        mode: "all",
        workspaceAccess: "rw",
      },

      tools: {
        profile: "messaging",
        deny: [
          "group:runtime",
          "sessions_spawn",
          "sessions_send",
          "gateway",
          "cron",
        ],
        fs: {
          workspaceOnly: true,
        },
        exec: {
          security: "deny",
          ask: "always",
        },
      },
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

### 5.2 Telegram Bot Tokenの安全な設定

設定ファイルにトークンを直書きせず、環境変数で管理:

```bash
# ~/.zshrc または ~/.zprofile に追加
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
```

### 5.3 LLM APIキーの安全な設定

auth profilesを使用してキーチェーンに保存:
```bash
openclaw auth add anthropic
```

プロンプトに従いAPIキーを入力。キーはmacOSキーチェーンに安全に保存される。

### 5.4 ファイルパーミッションの確認

```bash
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
find ~/.openclaw/credentials -type f -exec chmod 600 {} \;
```

---

## Phase 6: Tailscale Serveの設定

### 6.1 OpenClaw GatewayをTailscale経由で公開

```bash
tailscale serve --bg http://127.0.0.1:18789
```

**重要:** `http://` を使用すること（`https+insecure://` ではない）。
**重要:** `tailscale funnel` は**絶対に使用しない**（パブリックインターネットに公開されてしまう）。

### 6.2 確認

別のTailscale接続済みデバイスから:
```
https://<mac-mini-hostname>.your-tailnet.ts.net
```

にアクセスしてControl UIが表示されることを確認。

---

## Phase 7: Gatewayの起動と動作確認

### 7.1 Gateway起動

```bash
openclaw gateway restart
```

### 7.2 セキュリティ監査

```bash
openclaw security audit
openclaw security audit --deep
```

**Critical** または **High** の指摘がないことを確認。指摘がある場合:
```bash
openclaw security audit --fix
```

### 7.3 Telegramからの動作確認

1. Telegramで作成したBotにDMを送信
2. 応答が返ってくることを確認
3. allowlistに含まれない別ユーザーからのメッセージがブロックされることを確認

### 7.4 ステータス確認

```bash
openclaw status --all
openclaw dashboard
```

---

## Phase 8: 自動起動の設定 (LaunchAgent)

OpenClawのGatewayをLaunchAgentとして登録する。LaunchAgentはユーザーログイン時に自動起動する。

```bash
openclaw onboard --install-daemon
```

確認:
```bash
launchctl list | grep openclaw
```

**注意:** LaunchAgentはユーザーセッション開始後に起動するため、再起動後はリモートログイン（Phase 2.4参照）が必要。

---

## 再起動後のリモート復旧手順

Mac Miniが再起動した場合（停電、macOSアップデート等）の手順:

1. **Tailscaleは自動的にtailnetに接続済み**（System Extension）
2. 別のTailscale接続済みMacからScreen Sharingでログイン:
   ```bash
   open vnc://<mac-mini-tailscale-ip>
   ```
3. パスワードを入力してログイン → OpenClaw LaunchAgentが自動起動
4. 画面をロック: `Ctrl+Cmd+Q`
5. Telegramからメッセージを送信して動作確認

---

## 運用ガイド

### 定期セキュリティ監査

週次で以下を実行:
```bash
openclaw security audit --deep
openclaw doctor --fix
```

### アップデート

```bash
npm update -g openclaw@latest
openclaw gateway restart
openclaw security audit
```

アップデート後は必ずセキュリティ監査を実行する。

### APIキーのローテーション

定期的にAPIキーをローテーション:
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

1. **Gatewayの停止**
   ```bash
   openclaw gateway stop
   ```

2. **ネットワーク遮断**
   ```bash
   # Tailscale Serveを停止
   tailscale serve --remove
   ```

3. **Telegram DMを無効化** (設定ファイルで)
   ```json5
   channels: { telegram: { dmPolicy: "disabled" } }
   ```

4. **認証情報のローテーション**
   ```bash
   # Gateway トークンの再生成
   openclaw auth rotate-gateway-token
   # APIキーのローテーション
   openclaw auth rotate anthropic
   ```

5. **監査とログ確認**
   ```bash
   openclaw security audit --deep
   # ログの確認
   less /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
   # セッション履歴の確認
   ls ~/.openclaw/agents/*/sessions/
   ```

---

## リモートアクセス (別デバイスからの利用)

### SSHトンネル経由 (Tailscale上)

```bash
ssh -N -L 18789:127.0.0.1:18789 user@<mac-mini-tailscale-ip>
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
| FileVault無効 (意図的) | [ ] |
| 自動ログイン無効 | [ ] |
| ファイアウォール + ステルスモード有効化 | [ ] |
| Screen Sharing有効 (Tailscale経由のみ) | [ ] |
| Tailscale (Homebrew版, `sudo brew services` でLaunchDaemon化) | [ ] |
| 再起動後にTailscale自動接続確認済み | [ ] |
| ホームディレクトリ mode 700 | [ ] |
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
| `sandbox.mode: "all"` | [ ] |
| 危険ツール(exec, browser, gateway, cron)拒否 | [ ] |
| `fs.workspaceOnly: true` | [ ] |
| `execApprovals.enabled: true` | [ ] |
| `discovery.mdns.mode: "minimal"` | [ ] |
| `logging.redactSensitive: "tools"` | [ ] |
| `openclaw security audit --deep` 通過 | [ ] |
| ClawHubスキル未検証のものなし | [ ] |

---

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Security Hardening Guide](https://aimaker.substack.com/p/openclaw-security-hardening-guide)
