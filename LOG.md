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

### ファイルシステムアクセス制御の修正

調査の結果、`fs.deny` は公式スキーマに存在しない設定であり、実際には機能していないことが判明。公式にサポートされている `workspaceOnly` + `allowedRoots` 方式に変更。

変更前:
```json
"fs": {
  "workspaceOnly": false,
  "deny": ["/Users/*/.*", "/etc/**", "/Library/**"]
}
```

変更後:
```json
"fs": {
  "workspaceOnly": true,
  "allowedRoots": ["/Users/claw"]
}
```

変更理由:
- `fs.deny` は公式JSONスキーマに存在せず、`additionalProperties: false` のため無視される可能性が高い
- 変更前は実質的にファイルシステム全体にアクセス可能な状態だった
- `workspaceOnly: true` が公式にサポートされた設定（`allowedRoots` は PR #43565 で提案中だが未マージ）
- `/Users/claw/` 以下は自由に読み書き可能、それ以外はアクセス拒否される
- コマンド実行（exec）はfs設定とは独立しており、PATH上のコマンドは引き続き利用可能
- `~/.openclaw/openclaw.json` はエージェントから書き換え可能になるが、mode 600で防御

変更ファイル:
- `scripts/03-openclaw-setup.sh`: fs設定の変更
- `README.md`: 設定テーブルとセキュリティチェックリストにfs設定を追加

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

### README.md と PLAN.md の冗長性見直し

PLAN.mdからREADME.mdと重複していた以下のセクションを削除し、目的と作業ステップのみに整理:
- アーキテクチャ概要
- ディレクトリ構成
- ワークスペース共有方式
- セキュリティ方針
- プロジェクト構成
- 参考資料

役割分担: README.md = システム概要・設定詳細・運用手順、PLAN.md = 計画・作業ステップ

### mise activate のシェル指定修正

`02-claw-user-setup.sh` と `03-openclaw-setup.sh` で `mise activate zsh` を bash スクリプト内で `eval` していたため、zsh専用の `typeset -g` が macOS の `/bin/bash` (v3.2) で失敗していた。

修正箇所:
- `scripts/02-claw-user-setup.sh`: スクリプト内で `eval` する箇所を `mise activate bash` に変更（2箇所）。`.zshrc` に書き込む設定は `zsh` のまま維持。
- `scripts/03-openclaw-setup.sh`: `mise activate zsh` → `mise activate bash` に変更（1箇所）

### openclaw onboard ウィザードの廃止

`openclaw onboard --install-daemon` の対話的ウィザードを廃止し、すべての設定をファイルベースで管理する方式に変更。

背景:
- `openclaw onboard` はQuickStart/Manualの対話的ウィザードで設定を生成する
- しかしスクリプトの `generate_config()` が直後に設定ファイルを上書きしていた
- その際、onboardが自動生成した `gateway.auth.token` が消失する問題があった
- ウィザードの設定（Tailscale off等）とスクリプトの設定（Tailscale serve等）が不整合だった

変更点:
- **`install_openclaw()`**: `openclaw onboard --install-daemon` を削除。`npm install -g openclaw@latest` のみに簡素化
- **`generate_config()`**: `gateway.auth.token` をスクリプト側で `openssl rand -hex 32` により生成して設定ファイルに含める。`gateway.port: 18789` も明示的に設定
- **`start_and_verify()`**: `openclaw gateway install --force` を追加してLaunchAgentを登録（onboardのデーモン登録機能を代替）
- **README.md**: スクリプト説明、設定テーブル、セキュリティチェックリストを更新

利点:
- 対話的ウィザードが不要になり、完全に非対話的にセットアップ可能
- 設定がすべて `generate_config()` に集約され、Single Source of Truth になる
- gateway tokenの消失問題が解消

### openclaw.json スキーマの修正

実際にスクリプトを実行した際にOpenClawのバリデーションエラーが発生。公式スキーマに合わせて設定構造を修正。

エラー内容:
- `agents.defaults.sandbox.mode: "exec"` → 許可値は "off", "non-main", "all" のみ
- `agents.defaults.tools`, `agents.defaults.systemPrompt` → 認識されないキー
- `channels.telegram.retry.jitter: true` → 数値型が必要（booleanは不可）
- `openclaw auth add` → 存在しないコマンド

修正内容:
- **`agents.defaults.sandbox.mode`**: `"exec"` → `"off"`（Docker未使用のため。OSレベルのアカウント分離で代替）
- **`tools` セクション**: `agents.defaults.tools` からトップレベル `tools` に移動（正しいスキーマ位置）
- **`tools.profile`**: `"developer"` → `"coding"`（有効値: minimal, coding, messaging, full）
- **`tools.exec.security`**: `"sandbox"` → `"full"`（有効値: deny, allowlist, full。OSレベルのアカウント分離により権限昇格不可のため full で運用）
- **`tools.fs.allowedRoots`**: 削除（PR #43565 は未マージで v2026.3.13 では未サポート。`workspaceOnly: true` のみで運用。ワークスペース外は exec ツール経由でアクセス可能）
- **`systemPrompt`**: openclaw.jsonから削除 → ワークスペースの `AGENTS.md` に移行（OpenClawはワークスペース内のブートストラップファイルを自動読み込み）
- **`retry.jitter`**: `true` → `0.1`
- **`openclaw auth add`**: `openclaw models auth paste-token --provider` に変更
- **README.md**: 設定テーブル、セキュリティチェックリスト、CLIコマンド例、ディレクトリ構成を更新

### 対話的確認の削除 + APIキー設定方式の変更

変更点:
- **全 `[y/N]` 確認を削除**: install_openclaw, detect_workspace, generate_agents_md, setup_env, start_and_verify の各関数からconfirm呼び出しを除去。全ステップを自動実行
- **他のLLMプロバイダー設定を削除**: Anthropic APIキーのみ設定
- **APIキー設定方式の変更**: `openclaw models auth paste-token` → `~/.openclaw/.env` に `ANTHROPIC_API_KEY` を書き込む方式に変更。paste-token はOAuthトークン用であり、LaunchAgentデーモン運用では .env ファイルが推奨（GitHub Issue #9141）。設定後に `openclaw models status` で確認
- **README.md**: APIキー管理の説明をすべて .env 方式に更新

### シークレット管理の統一

`TELEGRAM_BOT_TOKEN` が `~/.zprofile`、`ANTHROPIC_API_KEY` が `~/.openclaw/.env` と管理場所が不整合だったため、すべて `~/.openclaw/.env` に統一。

変更点:
- **`setup_env()` + `setup_api_keys()` → `setup_secrets()` に統合**: 両シークレットを `~/.openclaw/.env` に書き込む
- **`do_reinit()`**: `~/.zprofile` からの `TELEGRAM_BOT_TOKEN` 削除を除去（`~/.openclaw/` 削除で `.env` ごと削除される）
- **`start_and_verify()`**: `source ~/.zprofile` を除去（Gatewayは `.env` を自動読み込み）
- **README.md**: reinit説明、セキュリティモデル、チェックリストを更新

### .env 書き込みバグの修正

Telegramが「no token」でセットアップ状態のまま動作しない問題を修正。

原因:
1. `prompt_secret()` の表示用 `echo`（`read -s` 後の改行補完）が stdout に出力されており、`$(prompt_secret ...)` の command substitution で値の先頭に改行が混入していた
2. `.env` の値がクォートされていなかったため、Botトークン内のコロン等が `.env` パーサーで誤解釈される可能性があった

結果として `.env` が以下のような不正な形式になっていた:
```
TELEGRAM_BOT_TOKEN=
<実際のトークン>
```

修正内容:
- **`prompt_secret()`**: `echo` → `echo >&2` に変更（表示用改行を stderr に出力し、command substitution にキャプチャされないようにする）
- **`setup_secrets()`**: `.env` の値をダブルクォートで囲むように変更（`KEY=value` → `KEY="value"`）

### .zshrc に compinit 初期化を追加

SSH接続時に `zsh: command not found: compdef` エラーが発生。

原因: `mise activate zsh` と OpenClaw の補完スクリプトが `compdef` を使用するが、zsh の補完システム (`compinit`) が初期化されていなかった。

修正内容:
- **`scripts/02-claw-user-setup.sh`**: `.zshrc` に mise 設定を追加する前に `autoload -Uz compinit && compinit` を挿入するように変更

### Gateway Dashboard の origin not allowed エラー修正

Tailscale Serve 経由で Gateway Dashboard にアクセスすると「origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)」エラーが発生。

原因: `controlUi.allowedOrigins` が設定されておらず、Tailscale Serve 経由のアクセス（Origin: `https://<hostname>.ts.net`）が拒否されていた。

修正内容:
- **`scripts/03-openclaw-setup.sh`**: `generate_config()` で `tailscale status --self --json` から Tailscale ホスト名を自動検出し、`controlUi.allowedOrigins` に追加。自動検出できない場合は手動入力を求める
- **`README.md`**: 設定テーブルに `gateway.controlUi.allowedOrigins` を追加

## 2026-04-28

### ベストプラクティス全面更新

公式 docs (gateway/security, channels/telegram, platforms/macos, help/environment) と複数のサードパーティガイド (aimaker substack, dirkpaessler.blog, mager.co, theothermartian/openclaw-mac-mini-setup, nebius blog) を調査し、以下を反映。

#### ポリシー判断: brew share は採用せず撤回

当初は claw に brew formula を許可（admin が staff グループ書き込み権限を付与）する案を検討したが、以下のリスクで撤回:
- `/opt/homebrew/bin/*` を staff 書き込み可能にすると、claw を乗っ取った攻撃者が brew 本体や git 等のバイナリを差し替え可能
- 後日 admin が `brew upgrade` 等を実行した際、admin の権限で攻撃者のコードが実行される（水平→垂直の権限昇格）
- 管理者は sudo 持ちなので root 権限まで一直線
- OpenClaw は Telegram 経由でインターネット露出するため、claw 乗っ取りを前提に設計すべき

代替として、CLI tool（jq, ripgrep, fd, gh 等）は mise の aqua/ubi バックエンドで claw 配下にインストールする方針に。すべて `~/.local/share/mise/` に隔離され admin に影響しない。

最終的な構成:
- **`scripts/01-admin-macos-setup.sh`**: brew share 関連の変更なし（元のまま）
- **`scripts/02-claw-user-setup.sh`**: 既存の `verify_restrictions()` を維持。brew prefix への書き込み不可を能動的にチェックする検査を追加（万一 admin が誤って共有してしまった場合の検出）
- **AGENTS.md**: brew は利用不可と明記。CLI tool は `mise use -g aqua:<owner>/<repo>` で導入、と具体例つきで案内

#### `--reinit` にスナップショット作成機能を追加（自動復元は意図的に撤回）

旧仕様の `--reinit` は `~/.openclaw/` を全削除するため、Telegram Bot Token / API Key / pairing / sessions / skills が失われ毎回再入力必須だった。これを改修:

- **`do_reinit()`**: 削除前に `~/.openclaw-snapshot-<ts>/` へ `cp -a` でスナップショット作成
- 自動値抽出・自動 state 復元は実装しない方針に決定。理由: ユーザーが「どのファイルを引き継ぐべきか自分で把握する」運用設計のため。自動化すると引き継いだ内容と引き継がなかった内容が不透明になる
- 復元は `cp -a ~/.openclaw-snapshot-<ts>/<item> ~/.openclaw/` で手動実行
- README に「手動復元の参考」セクションを追加し、各候補（credentials/agents/sessions/skills/exec-approvals.json/TOOLS.md/`gateway.auth.token`）のコマンド例を記載

なお自動復元の実装案（`extract_snapshot_values()` で `RESTORED_*` 環境変数に抽出 → 各 setup 関数で参照、`restore_state_from_snapshot()` で state コピー、`--no-restore` フラグ）は一度コミットしたが、この方針判断で撤回した。

## 2026-04-29

### exec.security を "full" に戻す + exec-approvals.json 削除

ユーザーから「専用アカウント作っているからできるだけ自律させたい」との要望。`exec.security: allowlist` + `ask: on-miss` の効果を再評価:

- allowlist でブロックされる脅威の多くは結局「読み取り + curl 外部送信」のような組み合わせで、個々のコマンドは allowlist に入る or 一度承認すれば後は自由
- 真の脅威（API キー流出、Telegram Bot 乗っ取り、tailnet ピボット、API コスト暴走）は exec の allowlist では防げない
- 一方、autonomy を犠牲にしてプロンプト承認を頻発させる UX コストは大きい
- claw 専用アカウントによる OS レベル隔離が既に主要な防御を提供（admin/他ユーザー不可視、sudo 不可、システム改変不可）

判断: **`exec.security: "full"` に戻す**。代わりに以下を別レイヤーで補う方針を README に明記:
- Anthropic console での月額 spend cap (API キー流出時の被害金額の上限化)
- Tailscale ACL (claw マシンから他 tailnet ノードへの egress 制限)
- 既存の `tools.deny` (gateway, sessions_spawn, sessions_send, cron 等の自己拡張・永続化を抑止)
- `tools.fs.workspaceOnly: true` (FS アクセスを workspace に限定)
- `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false` (内部ネットワーク到達を抑止)

実装変更:
- **`scripts/03-openclaw-setup.sh`**: `tools.exec` を `{"security": "full"}` に簡略化。`generate_exec_approvals()` 関数ごと削除し、main() 呼び出しと step 紹介から除去
- **`AGENTS.md` 生成テンプレート**: 「危険コマンドは exec allowlist 制御下にあり、未知のコマンドは Telegram 経由で承認を求めます」→「exec は full mode で動作し、コマンド実行に都度承認は不要です。autonomous に動作してください」
- **`README.md`**: 設定テーブルから `tools.exec.ask` / `askFallback` 行を削除、`tools.exec.security` を `"full"` に戻す。「スクリプトが行うこと」から exec-approvals 生成ステップを削除（11→10ステップ）。ディレクトリ構成テーブルから `~/.openclaw/exec-approvals.json` 行を削除。手動復元の参考表からも該当行を削除。Anthropic spend cap / Tailscale ACL の補完推奨を追記
- **`PLAN.md`**: 経緯を追記

### errorPolicy のハルシネーション値修正

reinit 後、gateway が起動せず Telegram が応答しなかった。原因: `channels.telegram.errorPolicy: "reply"` が invalid。OpenClaw 2026.4.26 が受け付ける値は `"always"` / `"once"` / `"silent"` のみ。

`"reply"` という値は当初の docs.openclaw.ai/channels/telegram の WebFetch 要約結果に含まれていたが、実機で reject された。docs 要約のハルシネーションだった可能性が高い。

修正:
- **`scripts/03-openclaw-setup.sh`** の `generate_config()`: `"reply"` → `"always"` (旧来の動作 = エラー時に常時返信。`errorCooldownMs: 120000` がスパム抑制)
- **`README.md`**: 設定テーブルと「スクリプトが行うこと」内の値を更新

ユーザーは即時対応として `python3` ワンライナーで `~/.openclaw/openclaw.json` を編集 + `openclaw gateway restart` で復旧。

### デフォルトモデルを Anthropic Claude Opus 4.7 に設定

OpenClaw のデフォルトモデルは OpenAI の `gpt-5.5` のため、`ANTHROPIC_API_KEY` のみ設定した状態だと `Missing API key for provider "openai"` エラーが発生。

設定上 `agents.defaults.model` を明示しないとデフォルトに従ってしまう。修正:
- **`scripts/03-openclaw-setup.sh`**: `agents.defaults` に `"model": "anthropic/claude-opus-4-7"` を追加
- **`README.md`**: 設定テーブルに `agents.defaults.model` 行追加、Phase 3 説明にも明記

#### sandbox 設計の判断

公式は `non-main` (default) または `all` を推奨するが、本構成では sandbox.mode は **"off" のまま維持**。理由:
- 既に claw 専用標準アカウントで OS レベル分離（admin 権限不可、admin/他ユーザーのファイル読取不可）
- Docker Desktop は 2-4GB RAM 消費、tool 実行レイテンシ増、GUI ログイン依存と運用複雑性
- 個人用 Telegram Bot (単一ユーザー) では Docker による追加防御の ROI が見合わない
- ユーザーからの明示的フィードバックで Docker 不要と判断

#### 設定の改善 (`scripts/03-openclaw-setup.sh` の `generate_config`)

- `tools.exec.security`: `"full"` → `"allowlist"`、`ask: "on-miss"` + `askFallback: "deny"` を追加
- `tools.deny`: `"group:automation"`, `"group:runtime"` をグループ単位で追加
- `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false` を明示
- `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback`, `dangerouslyDisableDeviceAuth` を明示的に false
- Telegram に `groupAllowFrom`, `errorPolicy: "reply"`, `errorCooldownMs: 120000`, `textChunkLimit: 3500`, `actions.sendMessage: true`, `actions.reactions: false` を追加

#### exec-approvals.json の初期生成

- 新規関数 `generate_exec_approvals()` で `~/.openclaw/exec-approvals.json` を生成
- 安全コマンド (ls, cat, head, tail, grep, rg, fd, find, wc, pwd, echo, which, env, git status/log/diff/branch/show, node/npm/mise --version) を allowlist 初期登録
- 未登録コマンドは Telegram 経由で承認 (ask: on-miss)

#### LaunchAgent の安定化

- 新規関数 `inject_launchagent_env()`: `openclaw gateway install --force` 直後に `/usr/libexec/PlistBuddy` で plist の `EnvironmentVariables` に `OPENCLAW_NO_RESPAWN=1` を注入。SIGUSR1 in-process restart による respawn ループを防止。
- 新規関数 `install_watchdog()`: `~/.openclaw/scripts/watchdog.sh` と `~/Library/LaunchAgents/local.openclaw.watchdog.plist` を生成。60秒間隔で `openclaw gateway status` を確認し、停止していたら `launchctl kickstart -k gui/$UID/ai.openclaw.gateway` を発火。ログは `~/.openclaw/logs/watchdog.log`。
- `do_reinit()` で watchdog plist の bootout と削除も行うよう修正

#### Spotlight 除外

- 新規関数 `exclude_spotlight()`: `~/.openclaw/.metadata_never_index` と workspace に `.metadata_never_index` を touch（Spotlight インデックス除外の Apple 規約ファイル）

#### README.md 更新

- セキュリティモデル表に「可用性」レイヤー追加（OPENCLAW_NO_RESPAWN, watchdog）
- 設定テーブルを最新キーに刷新（exec.allowlist, browser.ssrfPolicy, controlUi 全項目, telegram error policy 等）
- Phase 1 に Step 10「Homebrew staff グループ書き込み可能化」を追加
- Phase 3 Step 8 に PlistBuddy / watchdog コマンド追加
- 運用ガイドに「Skill / MCP インストールルール」セクション追加（ClawHavoc 注意）
- 週次セキュリティ監査に CVE 対応追記（2026年1月の 1-click RCE）
- ログ確認に `watchdog.log` 追加
- インシデント対応手順に watchdog の bootout 追加
