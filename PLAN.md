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
| `~/.openclaw/workspace/` | デフォルトワークスペース（→ Google Driveへのシンボリックリンク） | claw |
| `~/Library/CloudStorage/GoogleDrive-.../My Drive/openclaw-workspace/` | ワークスペース実体（Google Drive同期） | claw（Google Drive経由で個人PCと共有） |

- `~/.openclaw/` はデフォルトの場所に維持（機密データを含むため mode 700 のホームディレクトリ内が適切）
- `~/.openclaw/workspace` をGoogle Drive共有フォルダへのシンボリックリンクとして設定（デフォルトワークスペースパスを使用）
- `openclaw.json` はシークレットを含まない設計のためバージョン管理可能（ただし変更頻度が低いため管理者が sudo で直接編集する運用）

### ワークスペース共有方式: Google Drive共有フォルダ

- Open Claw専用のGoogleアカウントを作成
- 個人のGoogle Driveにワークスペースフォルダを作成し、Open Clawアカウントを「編集者」として招待
- Mac Mini（clawアカウント）ではGoogle Drive for Desktopにサインインし、共有フォルダをミラーリングモードで同期
- git管理は個人PC側のみで行う（普通に `git init`。Mac Mini側のエージェントはgitを使わないため、`.git`が同期されても問題なし）
- Google Driveのインストールは管理者アカウントでbrew経由

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

## プロジェクト構成

```
scripts/
  01-admin-macos-setup.sh     # 管理者: macOSセキュリティ + Tailscale + clawアカウント
  02-claw-user-setup.sh       # claw: Google Drive + mise + Node.js
  03-openclaw-setup.sh        # claw: OpenClawインストール・設定（--reinitで再インストール可）
README.md                     # セットアップガイド + 運用マニュアル
PLAN.md                       # 計画書・設計方針
LOG.md                        # 作業ログ
```

## 作業ステップ

1. [x] OpenClawリサーチ
2. [x] Telegram連携リサーチ
3. [x] セキュリティ強化リサーチ
4. [x] PLAN.md作成
5. [x] MANUAL.md作成
6. [x] LOG.md作成
7. [x] 専用標準アカウント `claw` 方針への移行（PLAN.md, MANUAL.md, LOG.md更新）
8. [x] ワークスペースを `/opt/openclaw/workspace/` に変更（agent.workspace設定、バージョン管理方針）
9. [x] ワークスペースをGoogle Drive共有フォルダ方式に変更（/opt/openclaw/workspace/ → Google Drive、個人PC側でgit管理）
10. [x] GUI操作のCUI化 + セットアップスクリプト化（手動マニュアル → 半自動セットアップ）

## 参考資料

- [OpenClaw公式ドキュメント - Install](https://docs.openclaw.ai/install)
- [OpenClaw公式ドキュメント - Security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw公式ドキュメント - Telegram](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw公式ドキュメント - Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
