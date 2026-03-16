# 作業ログ

## 2026-03-16

### リサーチ完了

- OpenClawの概要調査: オープンソースのパーソナルAIアシスタント。Peter Steinberger開発。GitHub 250k+ stars。
- インストール方法の調査: `openclaw.ai/install.sh` または `npm install -g openclaw@latest`。Node 24推奨。
- Telegram連携の調査: grammYベースのBot統合。BotFatherでトークン取得、dmPolicy/groupPolicyでアクセス制御。
- セキュリティ強化策の調査: 公式セキュリティドキュメント、Tailscale連携、コンテナ化デプロイ、ツールサンドボックス。
- Mac Mini + Tailscale構成の調査: mager.coのガイドを参考にMac Mini特有の設定（スリープ防止、FileVault、ファイアウォール）を確認。

### ドキュメント作成

- PLAN.md: セキュアデプロイメントのアーキテクチャと方針をまとめた
- MANUAL.md: 8フェーズの構築手順 + 運用ガイド + セキュリティチェックリストを作成

### MANUAL.md運用方針の変更

ユーザーのフィードバックに基づき、以下の方針に変更:

- **FileVault**: 無効のまま（コールドブート時のリモート復旧を優先）
- **自動ログイン**: 無効（物理アクセス保護のため）
- **Tailscale**: Mac App Store版に変更（System Extensionとしてログイン前から起動）
- **再起動後の運用**: Screen Sharing (VNC over Tailscale) でリモートログイン → 画面ロック
- **リモートログインの有効化**: SSH + Screen Sharing (Tailscale経由のみ)

変更理由:
- FileVault + 自動ログインはmacOSが両立を許可しない
- FileVault有効 → 停電後にリモート復旧不可
- 自動ログイン有効 → 物理アクセスで誰でも利用可能
- Tailscale System Extension + Screen Sharing が最もバランスの取れた構成

### セキュリティ方針の要約

最もセキュアな構成のポイント:
1. **Gateway**: localhostバインド限定、トークン認証
2. **ネットワーク**: Tailscale Serve (tailnet内のみ)、Funnelは使わない、パブリックポート開放なし
3. **Telegram**: allowlistベースDM/グループポリシー、数値ID限定、execApprovals有効化
4. **ツール制御**: sandbox mode all、危険ツール拒否、ワークスペース限定ファイルアクセス
5. **OS**: FileVault、ファイアウォール+ステルスモード、パーミッション制限
6. **シークレット管理**: 環境変数 or キーチェーン、設定ファイルに直書きしない
