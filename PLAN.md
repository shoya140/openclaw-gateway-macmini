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
11. [x] ベストプラクティス全面更新（2026-04-28〜29）
    - browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false 明示
    - controlUi の dangerous flags すべて明示的に false
    - tools.deny に group:automation, group:runtime 追加
    - Telegram errorPolicy/errorCooldownMs/textChunkLimit/groupAllowFrom 追加
    - LaunchAgent plist に OPENCLAW_NO_RESPAWN=1 注入
    - watchdog LaunchAgent 追加（60秒間隔で gateway 自動再起動）
    - Spotlight インデックス除外（.metadata_never_index）
    - sandbox は "off" のまま維持（OS アカウント分離が主防御、Docker は ROI 低）
    - CVE 2026年1月 / ClawHavoc 注意書きを README に追記
    - brew share は採用せず撤回（claw → admin 権限昇格経路を回避）。CLI tool は mise の aqua/ubi バックエンドで claw 配下に隔離
    - exec.security は最終的に "full" を維持（autonomy 重視、claw 隔離が主防御。allowlist + on-miss を一旦導入したが撤回）。代わりに Anthropic spend cap と Tailscale ACL を別レイヤーで補うことを README に明記
    - exec-approvals.json は生成しない（exec=full のため不要）
