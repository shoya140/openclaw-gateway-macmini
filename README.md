# OpenClaw Gateway on Mac Mini

Mac Mini に OpenClaw をインストールし、Telegram から利用するためのセットアップスクリプト + 運用マニュアル。

## 概要

```
[Telegram] <---> [OpenClaw Gateway (localhost:18789)] <---> [LLM API (Anthropic 等)]
                        ↑
              [Tailscale Serve (tailnet 内のみアクセス可)]
```

- Gateway は Mac Mini 上で loopback bind。外部アクセスは Tailscale Serve 経由（tailnet 内のみ）。パブリックポート開放なし
- OpenClaw は専用の標準（非管理者）アカウント `claw` で実行。`sudo` / `brew` は OS レベルで使えないため、claw が乗っ取られても admin への昇格経路がない
- ワークスペースは Google Drive 共有フォルダにあり、個人 PC と同期される。git 管理は個人 PC 側で行う

| レイヤー | 主な対策 |
|---------|---------|
| OS | 専用標準アカウント `claw`、ファイアウォール + ステルスモード、FileVault 無効（リモート復旧優先） |
| ネットワーク | loopback bind、Tailscale Serve、`browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false`、Telegram は IPv4 強制（`channels.telegram.network.autoSelectFamily: false`） |
| 認証 | Gateway トークン認証、Telegram allowlist（DM/グループ別）、controlUi の dangerous flags すべて off（execApprovals は autonomy 重視で off） |
| アプリ | sandbox off（OS 分離で代替）、`coding` profile、`tools.deny: []`（ユーザー権限の自走を最大化）、`exec.security: full`、`fs.workspaceOnly: true`、CLI tool は mise (aqua/ubi) で claw 配下に隔離 |
| データ | `~/.openclaw` 700、設定ファイル 600、シークレットは `.env`、Spotlight 除外 |
| 可用性 | `OPENCLAW_NO_RESPAWN=1` で respawn ループ防止、Watchdog LaunchAgent (60秒) で自己回復 |

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
- Telegram アカウント + BotFather で作成した Bot Token + 自分の User ID（`@userinfobot` で確認）
- LLM API キー（Anthropic 等）
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

2回目以降の実行は既存の `~/.openclaw` を自動的に `~/.openclaw-snapshot-<ts>/` にバックアップしてからクリーン状態で再構築します。同時に workspace と cron を最新 snapshot から復元したい場合は `./scripts/03-openclaw-setup.sh --recover` を指定してください。詳細は [バックアップ / リストア](#バックアップ--リストア) 参照。

---

## 各スクリプトが行うこと

### `01-admin-macos-setup.sh`（管理者アカウント）

- ファイアウォール + ステルスモード有効化
- 24/7 運用向け `pmset`（スリープ無効、再起動後の自動復帰）
- 自動ログイン無効化、Screen Sharing 有効化、SSH 有効化
- Tailscale インストール・認証 + `tailscale serve --bg http://127.0.0.1:18789`
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

対話で Telegram Bot Token / User ID / Anthropic API Key を入力する。

- OpenClaw インストール（`npm install -g openclaw@latest`）
- Google Drive 内の `openclaw-workspace` を自動検出し、`~/.openclaw/workspace` にシンボリックリンクを作成
- ワークスペースに `AGENTS.md`（mise で CLI tool を自分で導入するルール、sudo/brew が必要な作業はユーザーへ依頼するルール）を配置
- `~/.openclaw/openclaw.json` 生成（loopback / token auth / Tailscale Serve / Telegram allowlist / `exec.security: full` / `tools.deny: []` / `execApprovals: off` / `fs.workspaceOnly: true` / `ssrfPolicy` / `model.primary: anthropic/claude-opus-4-7`, `model.fallbacks: [anthropic/claude-sonnet-4-6]` / `channels.telegram.network.autoSelectFamily: false`（IPv6 経路の polling stall 回避のため IPv4 強制） 等。実値は [`scripts/03-openclaw-setup.sh`](scripts/03-openclaw-setup.sh) の `generate_config` を参照）
- `TELEGRAM_BOT_TOKEN` / `ANTHROPIC_API_KEY` を `~/.openclaw/.env` に保存
- `~/.openclaw` 700 / 設定ファイル 600 / Spotlight 除外
- zsh 補完を `~/.openclaw/completions/openclaw.zsh` に生成し、`~/.zshrc` に source 行を追加（`openclaw completion --shell zsh --install --write-state`）
- Gateway LaunchAgent 登録 + `OPENCLAW_NO_RESPAWN=1` 注入 + Watchdog LaunchAgent (60秒間隔) 登録
- `openclaw security audit` 実行

実行後、Telegram から Bot に DM して応答が返れば完了。

---

## モデルの切り替え

デフォルトは `anthropic/claude-opus-4-7`（primary）+ `anthropic/claude-sonnet-4-6`（fallback）。別モデルに切り替えるには `claw` アカウントで:

```bash
openclaw models set <provider/model>     # primary を変更
openclaw gateway restart
```

または `~/.openclaw/openclaw.json` の `agents.defaults.model.primary` / `model.fallbacks` を直接編集して `openclaw gateway restart`。

### Ollama（ローカル LLM）に切り替える例

Mac Mini 上の Ollama (`http://127.0.0.1:11434`) で起動済みのモデルに切り替える場合:

```bash
# 1. ローカル検出を有効化（marker placeholder。実際の API キーではない）
echo 'OLLAMA_API_KEY="ollama-local"' >> ~/.openclaw/.env
chmod 600 ~/.openclaw/.env

# 2. プライマリモデルを ollama/qwen3.6:35b-a3b に切り替え
openclaw models set ollama/qwen3.6:35b-a3b

# 3. Anthropic を fallback として残したい場合は openclaw.json を直接編集
#    "model": { "primary": "ollama/qwen3.6:35b-a3b",
#               "fallbacks": ["anthropic/claude-opus-4-7"] }

openclaw gateway restart
openclaw models status   # primary / fallbacks / 認証状態を確認
```

> Ollama は `127.0.0.1:11434` がデフォルトなので追加の `providers` 設定は不要。別ホストやポートを使う場合は `models.providers.ollama.baseUrl` を `openclaw.json` に明示する。

---

## 再起動後のリモート復旧手順

Mac Mini が再起動した場合（停電・macOS アップデート等）、Tailscale は LaunchDaemon で自動接続される。別の Tailscale 接続済み Mac から `open vnc://<mac-mini-tailscale-ip>` で **claw アカウント**にログインすれば、Gateway LaunchAgent + Watchdog LaunchAgent + Google Drive for Desktop が自動起動する。Google Drive の同期と `openclaw status` の起動を確認し、`Ctrl+Cmd+Q` で画面ロックして Telegram から疎通確認する。万一 Gateway が停止していても 60 秒以内に Watchdog が `launchctl kickstart` で再起動する。

---

## バックアップ / リストア

### 自動バックアップ（スクリプト再実行）

`./scripts/03-openclaw-setup.sh` は既存の `~/.openclaw` を検出すると自動的に `~/.openclaw-snapshot-<timestamp>/` に退避してから、クリーン状態で OpenClaw を再構築します（初回セットアップ時はスキップ）。流れ:

1. Watchdog / Gateway / LaunchAgent を停止・削除し、`~/.openclaw` を snapshot にコピー
2. Google Drive 上の workspace 中身（dotfile / `.git` 含む全項目）は snapshot に **`mv`**（symlink ではなく実体）。Google Drive workspace は空になる（personal PC にも数十秒〜数分で反映）
3. npm uninstall + `~/.openclaw/` 削除のうえ、通常フロー（Bot Token / User ID / API Key を対話で再入力）で再構築。空の Google Drive workspace に symlink を張り直し、新しい `AGENTS.md` だけが配置される

snapshot は workspace 実体を含む self-contained なバックアップで、Google Drive から消えても Mac Mini 上に残ります。

### `--recover` で自動復元（workspace + cron）

```bash
./scripts/03-openclaw-setup.sh --recover
```

セットアップ完了後の最終ステップで **最新の `~/.openclaw-snapshot-*` から `workspace` と `cron/` を自動復元**します:

- `workspace/`: snapshot 内の実体ファイルを Google Drive 上の workspace パスに `cp -a` で書き戻し（personal PC にも sync）
- `cron/`: snapshot から `~/.openclaw/cron` にコピーし、`openclaw gateway restart` で反映

それ以外（identity / telegram / agents / memory / media / flows / tasks / plugins / skills 等）は `--recover` の対象外です。必要があれば下記の手動リストアで個別に対応します。

### 手動リストア（identity / telegram など、その他の状態）

```bash
SNAP=~/.openclaw-snapshot-<ts>   # 実際のディレクトリ名に置き換え

# 最低限（同じ Telegram Bot を継続使用するなら必須）
cp -a "$SNAP/identity" "$SNAP/telegram" ~/.openclaw/

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
