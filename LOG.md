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

### 専用標準アカウント方針への移行

ユーザーの要望: OpenClawにシェルコマンドを自由に実行させつつ、sudo/brew installが必要な作業はユーザーに依頼するフローにしたい。

検討結果:
- LLMへの指示だけでsudo/brewを禁止するのはプロンプトインジェクション等で突破されるリスクがある
- **専用の標準（非管理者）アカウント `claw`** で実行すれば、OSレベルでsudoが実行不可になる
- brewも`/opt/homebrew`への書き込み権限がないため実行不可
- 通常のシェルコマンドは自由に実行可能

PLAN.md・MANUAL.mdの変更点:
- **Phase 3を新設**: 専用標準アカウント `claw` の作成手順（sysadminctl, 共有ディレクトリ, npm設定）
- **エージェント設定を変更**: `sandbox.mode: "all"` → `"exec"`, `tools.profile: "messaging"` → `"developer"`, `exec.security: "ask"` → `"sandbox"`
- **systemPromptを追加**: sudo/brew必要時にユーザーへコマンド群を提示して依頼するルール
- **caffeinate設定を削除**: pmsetの設定で十分なため不要
- **全Phaseにアカウント指示を追加**: 各作業が管理者/clawどちらで実行すべきかを明記
- **セキュリティチェックリスト更新**: アカウント分離の項目群を追加、動作確認にsudo依頼テストを追加
- **アカウント名**: `openclaw` → `claw` に変更（ユーザー指定）

### ワークスペース構成の変更

公式ドキュメントの再調査に基づき、ディレクトリ構成を変更。

調査結果:
- OpenClawのデフォルトワークスペースは `~/.openclaw/workspace`
- `~/.openclaw/` 全体のバージョン管理は非推奨（機密データを含む）
- ワークスペースのバージョン管理は推奨
- `agent.workspace` 設定でワークスペースの場所をカスタマイズ可能

変更点:
- **ディレクトリ名変更**: `/opt/openclaw/projects` → `/opt/openclaw/workspace`（OpenClawの命名規則に合わせる）
- **`agent.workspace` 設定を追加**: `openclaw.json` に `agent.workspace: "/opt/openclaw/workspace"` を追加
- **`~/.openclaw/` はデフォルトのまま維持**: 機密データを含むため mode 700 のホームディレクトリ内が適切
- **バージョン管理方針**: ワークスペースを管理者のgitアカウントで管理。管理者はsudoなしで操作可能
- **`openclaw.json` のバージョン管理**: シークレットを含まない設計のため技術的には可能だが、変更頻度が低いため管理者が sudo で直接編集する運用
- **運用ガイドにgit初期設定手順を追加**

### miseの導入

ユーザーの提案により、clawアカウントのランタイム管理をmiseに変更。

変更点:
- **Phase 3.5-3.6を置き換え**: Homebrew経由のNode.js共有 + npm-global設定 → miseによるランタイム管理
  - `curl https://mise.run | sh` でインストール（sudo/brew不要）
  - `mise use -g node@24` でNode.jsインストール
- **管理者アカウントへの依存を削減**: Node.jsのインストール・アップデートがclaw自身で完結
- **systemPromptにmise情報を追加**: エージェントがmiseの存在を認識し、ランタイムの追加・更新を自分で実行できるよう明示
- **brew関連の記述を整理**: clawアカウントにはbrewが存在しないことを明確化

## 2026-03-18

### ワークスペースをGoogle Drive共有フォルダ方式に変更

ユーザーの提案により、ワークスペースの共有方式を見直し。

動機:
- `/opt/openclaw/workspace/` はホームディレクトリ外にあり、ACL設定が複雑
- 個人PCとMac Mini間でファイルを共有するシンプルな方法が必要
- git管理を個人PC側に集約したい

設計:
- Open Claw専用のGoogleアカウントを作成
- 個人のGoogle Driveにワークスペースフォルダを作成し、Open Clawアカウントを「編集者」として招待
- Mac Mini（clawアカウント）ではGoogle Drive for Desktopにサインインし、共有フォルダをミラーリングモードで同期
- git管理は個人PC側のみ。普通に `git init` する（Mac Mini側のエージェントはgitを使わないため、`.git`が同期されても問題なし）

PLAN.md・MANUAL.mdの変更点:
- **ディレクトリ構成**: `/opt/openclaw/workspace/` → Google Drive共有フォルダ
- **Phase 3.4を置き換え**: 共有ディレクトリ作成+ACL → Google Drive for Desktopインストール（`brew install --cask google-drive`）
- **Phase 3.5を新設**: Open ClawアカウントでGoogle Driveにサインイン、ミラーリング設定
- **Phase番号を繰り下げ**: mise (3.6), Node.js (3.7), 制限確認 (3.8)
- **agent.workspace**: Google Drive共有フォルダのパスに変更
- **systemPrompt**: ワークスペースの説明をGoogle Drive共有フォルダに更新
- **運用ガイド - バージョン管理**: 管理者のgit操作 → 個人PCでの通常の `git init` に変更
- **再起動手順**: Google Driveの同期確認ステップを追加
- **セキュリティチェックリスト**: `/opt/openclaw/workspace/` 関連 → Google Drive関連に置き換え
- **前提条件**: Open Claw専用Googleアカウントと共有フォルダの事前準備を追加

### GUI操作のCUI化 + セットアップスクリプト化

手動マニュアル形式から半自動セットアップスクリプトへリファクタリング。

#### GUI操作のCUI化調査結果

| GUI操作 | CUI化 | 方法 |
|---------|-------|------|
| 自動ログイン無効 | 可能 | `sudo sysadminctl -autologin off` |
| Screen Sharing有効化 | 部分的 | `launchctl enable/bootstrap` + `dseditgroup`。macOS 12.1+のTCC制限によりGUI推奨 |
| SSH有効化 | 可能 | `sudo systemsetup -setremotelogin on` |
| Google Drive サインイン/ミラーリング | 不可 | GUI必須（OAuth認証フロー、ミラーリング設定にはCLI APIなし） |

#### スクリプト構成

3つの独立したスクリプトを作成:

1. **`scripts/01-admin-macos-setup.sh`** (管理者ユーザーで実行)
   - macOSセキュリティ基盤（ファイアウォール、ステルスモード、スリープ防止、自動ログイン無効、Screen Sharing、SSH）
   - Tailscaleインストール・認証・デーモン起動
   - clawアカウント作成・権限設定
   - Google Drive for Desktopインストール
   - Tailscale Serve設定

2. **`scripts/02-claw-user-setup.sh`** (clawユーザーで実行)
   - Google Driveセットアップ（GUI操作をスクリプトがガイド、アプリ自動起動）
   - miseインストール・シェル統合
   - Node.jsインストール（mise経由）
   - 権限制限の自動検証（sudo/brew不可の確認）

3. **`scripts/03-openclaw-setup.sh`** (clawユーザーで実行)
   - OpenClawインストール (`npm install -g openclaw@latest`)
   - Telegram Bot情報の対話的入力
   - ワークスペースパスの自動検出
   - `openclaw.json` 設定ファイル自動生成
   - 環境変数設定（TELEGRAM_BOT_TOKEN → ~/.zprofile）
   - LLM APIキー設定（キーチェーン）
   - ファイルパーミッション設定
   - Gateway起動・セキュリティ監査
   - `--reinit` オプション: 既存インストールを初期化して再インストール
     - Gateway停止、LaunchAgent削除、設定バックアップ、データ削除、npm uninstall
     - その後通常のインストールフローを再実行

#### MANUAL.mdの変更

- 手動ステップ実行形式からスクリプト実行ガイドに変更
- 各Phaseの説明はスクリプトが何をするかの解説に変更
- 運用ガイド、セキュリティチェックリスト、再起動復旧手順は維持
- GUI操作が必要な箇所（Screen Sharing VNCパスワード設定、Google Driveサインイン）は明示

### MANUAL.md → README.md への移行

- MANUAL.mdの全内容をREADME.mdに移行し、MANUAL.mdを削除
- README.mdとして必要な情報を加筆:
  - アーキテクチャ図（PLAN.mdから）
  - セキュリティモデルの概要テーブル（レイヤー別の対策一覧）
  - プロジェクト構成・ディレクトリ構成
  - クイックスタートセクション（3行で全体の流れがわかる）
  - Telegram Bot の事前準備手順（BotFather操作、User ID取得方法）
- PLAN.mdのプロジェクト構成も `MANUAL.md` → `README.md` に更新

## 2026-03-19

### ワークスペースをシンボリックリンク方式に変更

`agent.workspace` で直接Google Driveのパスを指定する方式から、デフォルトワークスペース（`~/.openclaw/workspace`）にシンボリックリンクを置く方式に変更。

変更理由:
- 設定ファイルから `agent.workspace` を削除でき、OpenClawのデフォルト動作に任せられる
- パスの管理がファイルシステムレベルに統一される

変更点:
- **`scripts/03-openclaw-setup.sh`**:
  - `detect_workspace()` → Google Driveパス検出後、`~/.openclaw/workspace` にシンボリックリンクを作成
  - `generate_config()` → `"agent": { "workspace": "..." }` ブロックを削除
  - `do_reinit()` → シンボリックリンクの削除を追加（Google Driveの実体は保持）
- **README.md**: ディレクトリ構成にシンボリックリンクを追記、セキュリティチェックリスト更新
- **PLAN.md**: ディレクトリ構成・ワークスペース方針を更新
