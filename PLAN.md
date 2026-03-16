# OpenClaw Gateway on Mac Mini - セキュアデプロイメント計画

## 目的

Mac MiniにOpenClawを最もセキュアな方法でインストールし、Telegram経由で利用可能にする。

## アーキテクチャ概要

```
[Telegram] <---> [OpenClaw Gateway (localhost:18789)] <---> [LLM API (Anthropic/OpenAI等)]
                        ↑
              [Tailscale Serve (tailnet内のみアクセス可)]
```

- OpenClaw GatewayはMac Mini上でlocalhostにバインド
- 外部アクセスはTailscale Serve経由（tailnet内のみ）
- Telegramとの通信はOpenClawのTelegramチャネル機能で実現
- パブリックインターネットへのポート公開なし

## セキュリティ方針

### ネットワーク層
- Gateway: `gateway.bind: "loopback"` (localhost限定)
- Tailscale Serve: tailnet内のみ公開（Funnelは使用しない）
- macOSファイアウォール + ステルスモード有効化
- パブリックポート公開なし

### 認証・認可層
- Gateway認証: トークンベース
- Telegram DM: `dmPolicy: "allowlist"` (明示的なユーザーID指定)
- グループ: `groupPolicy: "allowlist"` (明示的なグループ/ユーザーID指定)
- 数値IDのみ使用（ユーザーネームは使用しない）

### アプリケーション層
- ツール制限: 危険なツール（exec, browser, gateway, cron）をデフォルト拒否
- サンドボックス: `sandbox.mode: "all"` で全ツール隔離
- ワークスペース制限: `fs.workspaceOnly: true`
- スキル: ClawHubスキルは未検証のものをインストールしない

### データ保護
- FileVault (フルディスク暗号化) 有効化
- `~/.openclaw` ディレクトリ: mode 700
- 設定ファイル: mode 600
- APIキーはauth profilesまたは環境変数で管理（設定ファイルに直書きしない）

## 作業ステップ

1. [x] OpenClawリサーチ
2. [x] Telegram連携リサーチ
3. [x] セキュリティ強化リサーチ
4. [x] PLAN.md作成
5. [ ] MANUAL.md作成
6. [ ] LOG.md作成

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
