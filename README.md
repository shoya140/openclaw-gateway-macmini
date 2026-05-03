# OpenClaw Gateway on Mac Mini

Mac Mini に OpenClaw をインストールし、Telegram から利用するためのセットアップスクリプト + 運用マニュアル。

## 概要

```
[Telegram official Bot] ─┐
                         ├─> [OpenClaw Gateway (localhost:18789)] ─┬─> [Anthropic API]   (official-agent)
[Telegram personal Bot] ─┘             ↑                          └─> [Ollama 127.0.0.1] (personal-agent)
                            [Tailscale Serve (tailnet 内のみアクセス可)]
```

- 1 gateway で 2 つの Telegram Bot を運用。`channels.telegram.accounts.{official,personal}` + top-level `bindings[]` で account → agent をルーティングし、`agents.list[]` で agent ごとに別モデル（official=Claude Opus 4.7、personal=Qwen via Ollama）
- Gateway は Mac Mini 上で loopback bind。外部アクセスは Tailscale Serve 経由（tailnet 内のみ）。パブリックポート開放なし
- OpenClaw は専用の標準（非管理者）アカウント `claw` で実行。`sudo` / `brew` は OS レベルで使えないため、claw が乗っ取られても admin への昇格経路がない
- ワークスペースは Google Drive 共有フォルダにあり、個人 PC と同期される。git 管理は個人 PC 側で行う

| レイヤー | 主な対策 |
|---------|---------|
| OS | 専用標準アカウント `claw`、ファイアウォール + ステルスモード、FileVault 無効（リモート復旧優先） |
| ネットワーク | loopback bind、Tailscale Serve、`browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false`、Telegram は IPv4 優先（`channels.telegram.network.dnsResultOrder: "ipv4first"`）+ polling stall 対策（`timeoutSeconds: 60`） |
| 認証 | Gateway トークン認証、Telegram allowlist（DM/グループ別）、controlUi の dangerous flags すべて off（execApprovals は autonomy 重視で off） |
| アプリ | sandbox off（OS 分離で代替）、`coding` profile、`tools.deny: []`（ユーザー権限の自走を最大化）、`exec.security: full`、`fs.workspaceOnly: true`、CLI tool は mise (aqua/ubi) で claw 配下に隔離 |
| データ | `~/.openclaw` 700、設定ファイル 600、シークレットは `.env`、Spotlight 除外 |
| 可用性 | `OPENCLAW_NO_RESPAWN=1` で respawn ループ防止、LaunchAgent KeepAlive でプロセス死亡時に自動復帰 |

> `exec.security: full` + `tools.deny: []` + `execApprovals: off` で「ユーザー権限内のあらゆる操作を承認なしに自走」する設計。`gateway` / `cron` / `sessions_spawn` ツールも開放されているため、エージェント自身が `openclaw.json` を書き換えたり、永続化スケジュールを作ったり、サブエージェントを spawn できる。`claw` 専用標準アカウントによる OS 分離（sudo/brew 不可、admin・他ユーザーのファイル不可視）が最後の砦。
>
> 設定では防げない領域は別レイヤーで補う:
> - **Anthropic console で月額 spend cap** を設定（API キー流出 or runaway loop 時の被害金額を有限化）
> - **Tailscale ACL** で Mac Mini ノードから他 tailnet ノードへの egress を制限
> - **`fs.workspaceOnly: true`** は維持（Read 系の越境を制限。ホーム全体露出を避ける）
> - **`controlUi.dangerously*: false`** + **`browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false`** は維持
>
> CVE 動向（2026年1月の 1-click RCE、ClawHavoc キャンペーン等）に対応するため、`claw` で週次に `openclaw security audit --deep` + `npm outdated -g openclaw` を実行する。

---

## 準備物

- Mac Mini（Apple Silicon 推奨）+ macOS 15 以降
- インターネット接続
- 管理者アカウントに Homebrew インストール済み
- Telegram アカウント + BotFather で作成した **2 つの Bot Token**（official 用 / personal 用）+ 自分の User ID（`@userinfobot` で確認）
- LLM API キー（Anthropic 等）
- Ollama 本体・LaunchDaemon (UserName = admin)・モデル pull は全て `01-admin-macos-setup.sh` が実行する。daemon と モデル置き場 (`/Users/admin/.ollama/`) はどちらも admin 所有なので、所有関係を揃えるために `ollama pull` も 01 に集約。既定モデルは `qwen3.6:35b-a3b`、`<repo>/.env` の `OLLAMA_MODEL` で変更可
- OpenClaw 専用 Google アカウント
- 個人の Google Drive で `openclaw-workspace` フォルダを作成し、専用 Google アカウントを「編集者」として共有済み

---

## クイックスタート

```bash
# 1. 管理者アカウントで実行
./scripts/01-admin-macos-setup.sh

# 2. Screen Sharing で claw アカウントにログインし、claw で実行
./scripts/02-claw-user-setup.sh

# 3. 引き続き claw で実行
./scripts/03-openclaw-setup.sh
```

2回目以降の実行は既存の `~/.openclaw` を自動的に `~/.openclaw-snapshot-<ts>/` にバックアップしてからクリーン状態で再構築します。同時に workspace と cron を snapshot から復元したい場合は `./scripts/03-openclaw-setup.sh --recover` を指定してください（最新 snapshot を自動選択）。特定の snapshot から復元する場合は `--recover ~/.openclaw-snapshot-<ts>` のようにパスを渡します。詳細は [バックアップ / リストア](#バックアップ--リストア) 参照。

### `.env` で対話入力をスキップ

何度もセットアップを再実行する場合、プロジェクトルート（このリポジトリの直下）に `.env` を置いておくと、`03-openclaw-setup.sh` が読み込んで対話入力を省略します（`OLLAMA_MODEL` は `01-admin-macos-setup.sh` も読み込んで `ollama pull` の対象に使う）。`.env` は `.gitignore` 済みでコミットされません。

```dotenv
# <repo>/.env  (chmod 600 推奨)
TELEGRAM_OFFICIAL_BOT_TOKEN="..."
TELEGRAM_PERSONAL_BOT_TOKEN="..."
TELEGRAM_USER_ID="..."
ANTHROPIC_API_KEY="sk-ant-..."
OLLAMA_API_KEY="ollama-local"   # 省略可。未指定時は "ollama-local"
OLLAMA_MODEL="qwen3.6:35b-a3b"  # 省略可。01 の ollama pull + 03 の personal-agent.model に反映
```

- セットされている項目だけスキップされ、未設定の項目は従来通り対話入力されます
- シェルから `export` した環境変数（`ANTHROPIC_API_KEY=... ./scripts/03-...`）も同様に優先されます
- Telegram Bot Token は最終的に `~/.openclaw/credentials/telegram/{official,personal}.token` (chmod 600) に書き込まれ、`ANTHROPIC_API_KEY` / `OLLAMA_API_KEY` は `~/.openclaw/.env` (chmod 600) に書き込まれます

---

## 各スクリプトが行うこと

### `01-admin-macos-setup.sh`（管理者アカウント）

- ファイアウォール + ステルスモード有効化
- 24/7 運用向け `pmset`（スリープ無効、再起動後の自動復帰）
- 自動ログイン無効化、Screen Sharing 有効化、SSH 有効化
- Tailscale インストール・認証 + `tailscale serve --bg http://127.0.0.1:18789`
- Ollama インストール + `/Library/LaunchDaemons/io.shoya.ollama.plist` 配置 + モデル pull + 起動時 preload
  - **`UserName` = admin** で起動。モデル置き場は admin の `~/.ollama/`
  - 環境変数: `OLLAMA_KEEP_ALIVE=-1`（一度ロードしたモデルをメモリ常駐）、`OLLAMA_MAX_LOADED_MODELS=3`（運用中モデルを常駐させたまま `ollama run <別モデル>` で検証用にもう 2 つ並行ロードできる枠）
  - admin の `~/.ollama/` を Spotlight + Time Machine から除外（数十GB の blob インデックス防止）
  - daemon の起動を待ったうえで `ollama pull "${OLLAMA_MODEL:-qwen3.6:35b-a3b}"` を実行（`<repo>/.env` の `OLLAMA_MODEL` を読み込み済みならその値）
  - もう 1 つの LaunchDaemon `io.shoya.ollama-preload`（one-shot, `RunAtLoad=true` / `KeepAlive=false`）を配置。**boot 後に ollama daemon の listening を待ってから `POST /api/generate` (空 prompt + `keep_alive:-1`) で `OLLAMA_MODEL` をメモリへロード**。初回 Telegram メッセージのコールドロード待ち（35B で ~数十秒）を排除する。ログは `~admin/Library/Logs/ollama-preload.{log,error.log}`
- `claw` 標準アカウント作成（パスワード対話入力）
- Google Drive for Desktop インストール

> **手動確認が必要**:
> - Screen Sharing の VNC パスワードアクセスが無効であること（Tailscale 経由のみ使用）
> - 再起動後に Tailscale が自動接続されること（`tailscale status`）
>
> **FileVault は無効のまま**。有効にするとコールドブート時にリモート復旧ができなくなるため。

### `02-claw-user-setup.sh`（`claw` アカウント）

Screen Sharing 等で claw にログインしてから実行する。

- Google Drive セットアップ（GUI 操作。専用 Google アカウントでサインイン → ミラーリング → 共有フォルダ追加。スクリプトが指示する）
- mise インストール + シェル統合
- Node.js インストール（`mise use -g node@24`）
- sudo / brew が claw から使えないことの自動検証

### `03-openclaw-setup.sh`（`claw` アカウント）

対話で **2 つの Telegram Bot Token (official / personal)** / User ID / Anthropic API Key を入力する（プロジェクト直下の `.env` に値があればその項目はスキップ。詳細は [`.env` で対話入力をスキップ](#env-で対話入力をスキップ) 参照）。

- OpenClaw インストール（`npm install -g openclaw@latest`）
- **Telegram 拡張 peer deps の手動 install**: `grammy` / `@grammyjs/runner` / `@grammyjs/transformer-throttler` を `$(npm root -g)/openclaw` 配下に `--no-save` で install。OpenClaw の `dist/` がこれらを require するが `package.json` に未宣言で、`npm install -g openclaw@latest` のたびに消えるため毎回再 install（上流 packaging bug。openclaw/openclaw#59867, #60263, #60309, #62425, #63103, #70615 等）。上流が修正したら 03 の `install_telegram_peer_deps` 関数は不要になる
- Google Drive 内の `openclaw-workspace` を自動検出し、`~/.openclaw/workspace` にシンボリックリンクを作成
- ワークスペースに `AGENTS.md`（mise で CLI tool を自分で導入するルール、sudo/brew が必要な作業はユーザーへ依頼するルール）を配置
- 入力された 2 つの Bot Token を `~/.openclaw/credentials/telegram/{official,personal}.token` (chmod 600) に書き込み（OpenClaw の `tokenFile` 仕様。symlink 不可・実ファイルのみ）
- `~/.openclaw/openclaw.json` 生成（主な設定）:
  - **マルチアカウント Telegram**: `channels.telegram.accounts.{official,personal}` 各々に `tokenFile` + `dmPolicy: "allowlist"` + `allowFrom: [USER_ID]` + `groupPolicy` / `groupAllowFrom` を指定。`defaultAccount: official`。**allowlist は account 単位**（チャンネル直下に書くと Doctor が `accounts.default` に切り出してしまい、official/personal は allowlist 無し扱いになる）
  - **エージェント**: `agents.list[]` に `official-agent` (`anthropic/claude-opus-4-7` primary + `anthropic/claude-sonnet-4-6` fallback) と `personal-agent` (`ollama/${OLLAMA_MODEL}`、未指定時は `ollama/qwen3.6:35b-a3b`)。`personal-agent` には `workspace: ~/.openclaw/workspace` を明示し、official と同じ Google Drive 配下の workspace を共有させる（明示しない場合 openclaw は `~/.openclaw/workspace-personal-agent` を自動生成して別 workspace になる）。さらに `agents.defaults.model` にも同じ Claude Opus + Sonnet fallback を設定し、main / 未バインド agent が OpenClaw 組み込み既定 (`openai/gpt-5.5`) にフォールバックするのを防止
  - **Ollama provider**: `models.providers.ollama.models[]` で `OLLAMA_MODEL` 用の `params.num_ctx: 8192` + `keep_alive: -1` を明示。`num_ctx` は **Ollama の runtime context window**（KV キャッシュ確保サイズ）。明示しないと OpenAI-compat 経路で 4096 にサイレント truncation するか、Modelfile の最大値（35b-a3b は 32k〜）でメモリを過剰確保して prefill が遅くなる。Mac Mini の統合メモリ前提では 8192 がレスポンス速度と文脈量のバランス点。文脈不足を感じたら 16384 に上げる（速度低下と引き換え）。**`agents.defaults.models.*.params.num_ctx` 経路は OpenClaw issue #44550 で discovery 由来の GGUF context_length に上書きされるため使わない**
  - **ルーティング**: top-level `bindings[]` で `accountId: official → official-agent`、`accountId: personal → personal-agent`
  - **オーナー権限**: top-level `commands.ownerAllowFrom: ["telegram:<USER_ID>"]` で owner-only コマンド（`/diagnostics`, `/export-trajectory`, `/config`, exec 承認）を自分の Telegram アカウントに許可
  - **共通**: loopback / token auth / Tailscale Serve / `exec.security: full` / `tools.deny: []` / `execApprovals: off` / `fs.workspaceOnly: true` / `ssrfPolicy` / `channels.telegram.network.dnsResultOrder: "ipv4first"`（IPv6 経路の polling stall 回避のため IPv4 優先。`autoSelectFamily: false` は Node 22+ で getUpdates timeout cascade を引き起こす既知バグがあるため `true` のまま Happy Eyeballs を有効化） / `channels.telegram.timeoutSeconds: 60`（90s の polling stall threshold より先に HTTP timeout を発火させて zombie 状態を回避） / `channels.telegram.streaming.mode: "partial"` + `streaming.preview.toolProgress: false`（ツール進捗の逐次プレビューを抑止し送信スパムを軽減）
  - 実値は [`scripts/03-openclaw-setup.sh`](scripts/03-openclaw-setup.sh) の `generate_config` を参照
- `ANTHROPIC_API_KEY` / `OLLAMA_API_KEY="ollama-local"` を `~/.openclaw/.env` に保存（Ollama はローカル marker のため最初から書き込み。Telegram トークンは `.env` ではなく `credentials/telegram/*.token` 経由）
- `~/.openclaw` 700 / 設定ファイル 600 / Spotlight 除外
- zsh 補完を `~/.openclaw/completions/openclaw.zsh` に生成し、`~/.zshrc` に source 行を追加（`openclaw completion --shell zsh --install --write-state`）
- Gateway LaunchAgent 登録 + `OPENCLAW_NO_RESPAWN=1` 注入
- `openclaw security audit` 実行

実行後、Telegram から Bot に DM して応答が返れば完了。

---

## モデルの切り替え

デフォルトは official-agent = `anthropic/claude-opus-4-7` (+ `anthropic/claude-sonnet-4-6` fallback)、personal-agent = `ollama/qwen3.6:35b-a3b`（`.env` の `OLLAMA_MODEL` で変更可）、`agents.defaults.model` = `anthropic/claude-opus-4-7` (+ Sonnet fallback)。

agent ID は人格 (Telegram bot identity) に紐付いており、bindings (account → agent) と token ファイル名 (`credentials/telegram/{official,personal}.token`) は固定。**モデルだけを差し替える場合は `~/.openclaw/openclaw.json` の `agents.list[].model` を編集**して `openclaw gateway restart`:

```jsonc
"agents": {
  "defaults": {
    "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] }
  },
  "list": [
    { "id": "official-agent", "model": { "primary": "anthropic/claude-opus-4-7", "fallbacks": ["anthropic/claude-sonnet-4-6"] } },
    { "id": "personal-agent", "model": "ollama/qwen3.6:35b-a3b", "workspace": "/Users/claw/.openclaw/workspace" }
  ]
}
```

`model` は文字列 (`"provider/model"`) または `{ primary, fallbacks }` オブジェクトのどちらでも可。`agents.defaults.model` は `agents.list[]` で個別 model 指定の無い agent（`main` 等）に適用され、未設定だと OpenClaw は組み込み既定 `openai/gpt-5.5` にフォールバックして OpenAI auth を要求するため、Anthropic に明示する。`openclaw models set` は `agents.defaults.model` を書き換える CLI なので、`agents.list[]` の個別 model を変えたいときは openclaw.json の直接編集が必要。

### Ollama（ローカル LLM）モデルの差し替え例

Mac Mini 上の Ollama (`http://127.0.0.1:11434`) は `OLLAMA_API_KEY="ollama-local"` がセット済み（`03-openclaw-setup.sh` で `~/.openclaw/.env` に自動投入）。**`personal-agent` のモデルと 01 の pull 対象モデルは `<repo>/.env` の `OLLAMA_MODEL` で一括指定**する：

```bash
# 1. <repo>/.env の OLLAMA_MODEL を書き換え
#    OLLAMA_MODEL="<新しいモデル>"

# 2. 反映 (01 が admin として新モデル pull、03 が claw として openclaw.json 更新)
./scripts/01-admin-macos-setup.sh   # admin で実行
./scripts/03-openclaw-setup.sh      # claw で実行
```

スクリプトを再実行せず手動で反映したい場合は、admin として `ollama pull <model>`（モデルは admin の `~/.ollama/` に保存される）後に claw として `~/.openclaw/openclaw.json` の `agents.list[].model` と `models.providers.ollama.models[].id` を直接編集して `openclaw gateway restart`。新モデルは初回呼び出し時にロードされ、`OLLAMA_KEEP_ALIVE=-1` でメモリに常駐する。`OLLAMA_MAX_LOADED_MODELS=3` の枠を超えると最古ロードのモデルから自動アンロードされる。新モデルを次回 boot から自動 preload したい場合は `<repo>/.env` の `OLLAMA_MODEL` を更新して `01-admin-macos-setup.sh` を再実行（`io.shoya.ollama-preload.plist` が新モデル名で再生成される）。

### Ollama の context window (num_ctx) 調整

Ollama は `num_ctx` を明示しないと OpenAI-compat 経路で 4096 にサイレント truncation するため、`models.providers.ollama.models[].params.num_ctx` で必ず明示する。デフォルトは 8192（Mac Mini 統合メモリ前提でのレスポンス速度と文脈量のバランス点）。文脈不足を感じたら `~/.openclaw/openclaw.json` を編集して `openclaw gateway restart`:

```jsonc
"models": {
  "providers": {
    "ollama": {
      "baseUrl": "http://127.0.0.1:11434",
      "api": "ollama",
      "models": [
        { "id": "qwen3.6:35b-a3b", "name": "qwen3.6:35b-a3b", "params": { "num_ctx": 16384, "keep_alive": -1 } }
      ]
    }
  }
}
```

`num_ctx` の目安: 4096 = 速度最大だが Telegram 履歴込みで即溢れる / **8192 = 既定（速度寄り）** / 16384 = バランス / 32k 以上 = qwen3 系で Ollama 0.12.x 系の slowdown バグ報告あり。**`agents.defaults.models.*.params.num_ctx` には書かない**（OpenClaw issue #44550 で discovery 由来の GGUF context_length に上書きされる。必ず `models.providers.ollama.models[].params` 側へ）。

### 新しい人格 (3 つ目以降の Bot) を追加する場合

1. BotFather で新 Bot を作成して token を取得
2. `~/.openclaw/credentials/telegram/<新名前>.token` を chmod 600 で配置
3. `openclaw.json` の `channels.telegram.accounts` / `agents.list[]` / `bindings[]` にエントリ追加
4. `openclaw gateway restart`

---

## 再起動後のリモート復旧手順

Mac Mini が再起動した場合（停電・macOS アップデート等）、Tailscale は LaunchDaemon で自動接続される。別の Tailscale 接続済み Mac から `open vnc://<mac-mini-tailscale-ip>` で **claw アカウント**にログインすれば、Gateway LaunchAgent + Google Drive for Desktop が自動起動する。Google Drive の同期と `openclaw status` の起動を確認し、`Ctrl+Cmd+Q` で画面ロックして Telegram から疎通確認する。Gateway プロセスが死んだ場合は LaunchAgent の KeepAlive により自動再起動される。プロセスは生きているのに応答しないハング状態に陥った場合は、claw アカウントで `launchctl kickstart -k gui/$UID/ai.openclaw.gateway` を実行して手動で蹴り直す。

---

## バックアップ / リストア

### 自動バックアップ（スクリプト再実行）

`./scripts/03-openclaw-setup.sh` は既存の `~/.openclaw` を検出すると自動的に `~/.openclaw-snapshot-<timestamp>/` に退避してから、クリーン状態で OpenClaw を再構築します（初回セットアップ時はスキップ）。流れ:

1. Gateway / LaunchAgent を停止・削除し、`~/.openclaw` を snapshot にコピー
2. Google Drive 上の workspace 中身（dotfile / `.git` 含む全項目）は snapshot に **`mv`**（symlink ではなく実体）。Google Drive workspace は空になる（personal PC にも数十秒〜数分で反映）
3. npm uninstall + `~/.openclaw/` 削除のうえ、通常フロー（Bot Token / User ID / API Key を対話で再入力）で再構築。空の Google Drive workspace に symlink を張り直し、新しい `AGENTS.md` だけが配置される

snapshot は workspace 実体を含む self-contained なバックアップで、Google Drive から消えても Mac Mini 上に残ります。

### `--recover` で自動復元（workspace + cron）

```bash
./scripts/03-openclaw-setup.sh --recover                              # 最新 snapshot を自動選択
./scripts/03-openclaw-setup.sh --recover ~/.openclaw-snapshot-<ts>    # 特定の snapshot を指定
```

セットアップ完了後の最終ステップで snapshot から `workspace` と `cron/` を自動復元します:

- `workspace/`: snapshot 内の実体ファイルを Google Drive 上の workspace パスに `cp -a` で書き戻し（personal PC にも sync）
- `cron/`: snapshot から `~/.openclaw/cron` にコピーし、`openclaw gateway restart` で反映

引数なしの場合は `~/.openclaw-snapshot-*` から最新を自動選択。古い snapshot や別パスから復元したい場合はディレクトリパスを **空白区切り** で渡してください（上の例 2 行目）。zsh/bash は `--recover=~/path` の形式では `~` をシェル展開しないため、空白区切り (`--recover ~/...`) のほうが取り違えが起きにくく推奨です。`--recover=DIR` 形式も使用可能で、その場合は先頭の `~` をスクリプト側で `$HOME` に展開します。

それ以外（identity / telegram / agents / memory / media / flows / tasks / plugins / skills 等）は `--recover` の対象外です。必要があれば下記の手動リストアで個別に対応します。

### 手動リストア（identity / telegram など、その他の状態）

```bash
SNAP=~/.openclaw-snapshot-<ts>   # 実際のディレクトリ名に置き換え

# 最低限（同じ Telegram Bot を継続使用するなら必須）
cp -a "$SNAP/identity" "$SNAP/telegram" "$SNAP/credentials" ~/.openclaw/

# 履歴・カスタム設定（必要なものだけ選択）
cp -a "$SNAP/agents" "$SNAP/memory" "$SNAP/media" ~/.openclaw/
cp -a "$SNAP/flows" "$SNAP/tasks" "$SNAP/plugins" "$SNAP/skills" ~/.openclaw/

openclaw gateway restart
```

| ディレクトリ | 役割 | 復元判断 |
|----|----|----|
| `workspace/` | ワークスペース実体（snapshot は symlink ではなくファイル） | `--recover` で自動復元 |
| `cron/` | スケジュールされたタスク定義 | `--recover` で自動復元 |
| `identity/` | デバイス identity・暗号鍵 | 手動。必須（再 pairing 回避） |
| `telegram/` | Telegram pairing 状態・update offset | 手動。必須 |
| `credentials/telegram/*.token` | official / personal の Bot Token | 手動。必須（再入力したくなければ復元） |
| `agents/`, `memory/`, `media/` | セッション履歴・累積メモリ・受信メディア | 手動。履歴を引き継ぎたい場合（`agents/` を入れるなら `media/` もセット） |
| `flows/`, `tasks/`, `plugins/`, `skills/` | ユーザー定義 | 手動。カスタムしていれば復元 |
| `exec-approvals.json`, `*.bak*`, `*.last-good`, `logs/` | 履歴・キャッシュ | 復元しない（新 config と競合 / 不要） |

`gateway.auth.token` を引き継いでリモートクライアント再設定を避けたい場合は、snapshot の `openclaw.json` から token 値を抜き出して新 `openclaw.json` の同フィールドに書き戻し、`chmod 600` の上で `openclaw gateway restart`。動作確認できたら `rm -rf "$SNAP"`。

---

## 参考資料

- [OpenClaw 公式 - Install](https://docs.openclaw.ai/install) / [Security](https://docs.openclaw.ai/gateway/security) / [Telegram](https://docs.openclaw.ai/channels/telegram) / [Tailscale](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw + Mac Mini + Tailscale ガイド](https://www.mager.co/blog/2026-02-22-openclaw-mac-mini-tailscale/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Security Hardening Guide](https://aimaker.substack.com/p/openclaw-security-hardening-guide)
