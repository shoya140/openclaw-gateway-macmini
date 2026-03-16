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

## ディレクトリ構成

| パス | 内容 | アクセス |
|------|------|---------|
| `/Users/claw/.openclaw/` | 設定、認証、セッション等（デフォルト） | claw のみ（管理者は sudo） |
| `/opt/openclaw/workspace/` | エージェントの作業ディレクトリ（git管理） | claw + 管理者 |

- `~/.openclaw/` はデフォルトの場所に維持（機密データを含むため mode 700 のホームディレクトリ内が適切）
- `agent.workspace` を `/opt/openclaw/workspace/` に設定し、管理者が sudo なしで git 操作できるようにする
- `openclaw.json` はシークレットを含まない設計のためバージョン管理可能（ただし変更頻度が低いため管理者が sudo で直接編集する運用）

## セキュリティ方針

### アカウント分離（権限昇格の防止）
- OpenClawは**専用の標準（非管理者）アカウント `claw`** で実行
- 標準アカウントは管理者グループに属さないため、`sudo` がOSレベルで実行不可
- `brew` は `claw` アカウントには未インストール
- 通常のシェルコマンド（git, node, npm, ファイル操作等）は自由に実行可能
- `sudo` / `brew install` が必要な作業はTelegram経由でユーザーに依頼し、管理者アカウントで手動実行

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
- シェル実行: 自由（OSレベルの権限分離で保護）
- サンドボックス: `sandbox.mode: "exec"` （exec系ツールはサンドボックス内で実行）
- ワークスペース制限: 共有プロジェクトディレクトリのみアクセス可能
- エージェント指示: systemPromptでsudo/brew依頼ルールを明示
- スキル: ClawHubスキルは未検証のものをインストールしない

### データ保護
- `~/.openclaw` ディレクトリ: mode 700
- 設定ファイル: mode 600
- APIキーはauth profilesまたは環境変数で管理（設定ファイルに直書きしない）

## 作業ステップ

1. [x] OpenClawリサーチ
2. [x] Telegram連携リサーチ
3. [x] セキュリティ強化リサーチ
4. [x] PLAN.md作成
5. [x] MANUAL.md作成
6. [x] LOG.md作成
7. [x] 専用標準アカウント `claw` 方針への移行（PLAN.md, MANUAL.md, LOG.md更新）
8. [x] ワークスペースを `/opt/openclaw/workspace/` に変更（agent.workspace設定、バージョン管理方針）

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
