# OpenClaw Gateway on Mac Mini - セキュアデプロイメント計画

## 目的

Mac MiniにOpenClawをインストールし、Telegram経由で利用可能にする。

システム概要・設定詳細・運用手順は [README.md](README.md) を参照。

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
