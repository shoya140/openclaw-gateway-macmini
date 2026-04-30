#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}>>> $*${NC}"; }
wait_user() {
    echo -e "${YELLOW}"
    read -rp "完了したら Enter を押してください..." _
    echo -e "${NC}"
}
confirm() {
    read -rp "$(echo -e "${YELLOW}$* [y/N]: ${NC}")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
prompt_value() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BLUE}${prompt} [${default}]: ${NC}")" value
        echo "${value:-$default}"
    else
        local value
        read -rp "$(echo -e "${BLUE}${prompt}: ${NC}")" value
        echo "$value"
    fi
}
prompt_secret() {
    local prompt="$1"
    local value
    read -rsp "$(echo -e "${BLUE}${prompt}: ${NC}")" value
    echo >&2
    echo "$value"
}

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"

# ============================================================
# Pre-flight checks
# ============================================================
preflight() {
    [[ "$(uname)" == "Darwin" ]] || error "macOS専用スクリプトです"
    [[ "$(whoami)" == "claw" ]] || error "このスクリプトは 'claw' ユーザーで実行してください (現在: $(whoami))"

    export PATH="$HOME/.local/bin:$PATH"
    eval "$(~/.local/bin/mise activate bash 2>/dev/null)" || true

    command -v node &>/dev/null || error "Node.js が見つかりません。先に 02-claw-user-setup.sh を実行してください"
    command -v npm &>/dev/null || error "npm が見つかりません。先に 02-claw-user-setup.sh を実行してください"
    success "Pre-flight OK (user: claw, node: $(node --version))"
}

# ============================================================
# Backup existing install + reset (既存 ~/.openclaw があれば常時実行)
# ============================================================
backup_and_reset() {
    step "0. 既存インストールをバックアップして初期化"
    info "既存の ~/.openclaw + Google Drive 上の workspace 内容を ~/.openclaw-snapshot-<ts>/ に退避します"
    info "  - ~/.openclaw → snapshot にコピー (cp -a)"
    info "  - workspace 中身 → snapshot/workspace に mv（実体ファイル。Google Drive からは消える）"
    info "  - personal PC 側の Google Drive にも空状態が反映されます"

    info "旧 Watchdog があれば停止中（撤去済みだが古い環境のクリーンアップ）..."
    launchctl bootout "gui/$UID/ai.openclaw.watchdog" 2>/dev/null || true
    info "Gateway 停止中..."
    openclaw gateway stop 2>/dev/null || true

    local workspace_real=""
    if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real=$(readlink "$OPENCLAW_DIR/workspace")
    elif [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real="$OPENCLAW_DIR/workspace"
    fi

    local snapshot_dir="$HOME/.openclaw-snapshot-$(date +%Y%m%d-%H%M%S)"
    cp -a "$OPENCLAW_DIR" "$snapshot_dir"
    success "~/.openclaw → $snapshot_dir にコピー"

    if [[ -n "$workspace_real" && -d "$workspace_real" ]]; then
        rm -f "$snapshot_dir/workspace" 2>/dev/null || true
        mkdir -p "$snapshot_dir/workspace"

        shopt -s dotglob nullglob
        local entries=("$workspace_real"/*)
        shopt -u dotglob nullglob

        if [[ ${#entries[@]} -gt 0 ]]; then
            mv "${entries[@]}" "$snapshot_dir/workspace/"
            success "Workspace の中身 ${#entries[@]} 項目を $snapshot_dir/workspace/ に退避（実体ファイル）"
            info "Google Drive 上の workspace は空になりました（personal PC にも数十秒〜数分で反映）"
        else
            rmdir "$snapshot_dir/workspace" 2>/dev/null || true
            info "Workspace は既に空でした"
        fi
    else
        info "Workspace symlink/ディレクトリが見つからないため workspace の退避をスキップ"
    fi

    info "LaunchAgent 削除中..."
    launchctl remove ai.openclaw.gateway 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/ai.openclaw.watchdog.plist 2>/dev/null || true

    info "OpenClaw アンインストール中..."
    npm uninstall -g openclaw 2>/dev/null || true

    if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
        info "workspace シンボリックリンクを削除（Google Drive 実体は空状態で保持）..."
        rm "$OPENCLAW_DIR/workspace"
    fi

    info "データディレクトリ削除中..."
    rm -rf "$OPENCLAW_DIR"

    success "バックアップ + 初期化完了 → snapshot: $snapshot_dir"
    echo
}

# ============================================================
# Find latest snapshot
# ============================================================
find_latest_snapshot() {
    ls -1dt "$HOME"/.openclaw-snapshot-* 2>/dev/null | head -n 1
}

# ============================================================
# Recover: 最新 snapshot から workspace + cron を復元
# ============================================================
do_recover() {
    step "Recover: 最新 snapshot から workspace + cron を復元"

    local snapshot_dir
    snapshot_dir=$(find_latest_snapshot)

    if [[ -z "$snapshot_dir" || ! -d "$snapshot_dir" ]]; then
        warn "snapshot が見つかりません ($HOME/.openclaw-snapshot-*)。--recover をスキップします"
        return
    fi

    info "Snapshot: $snapshot_dir"

    if [[ -d "$snapshot_dir/workspace" ]]; then
        local workspace_real=""
        if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
            workspace_real=$(readlink "$OPENCLAW_DIR/workspace")
        elif [[ -d "$OPENCLAW_DIR/workspace" ]]; then
            workspace_real="$OPENCLAW_DIR/workspace"
        fi

        if [[ -n "$workspace_real" && -d "$workspace_real" ]]; then
            shopt -s dotglob nullglob
            local items=("$snapshot_dir/workspace"/*)
            shopt -u dotglob nullglob
            if [[ ${#items[@]} -gt 0 ]]; then
                cp -a "${items[@]}" "$workspace_real/"
                success "workspace 復元: $workspace_real （${#items[@]} 項目を Google Drive に書き戻し）"
            else
                info "snapshot/workspace は空でした"
            fi
        else
            warn "workspace の実体パスを検出できませんでした (~/.openclaw/workspace)"
        fi
    else
        info "snapshot に workspace がありません。スキップ"
    fi

    if [[ -d "$snapshot_dir/cron" ]]; then
        cp -a "$snapshot_dir/cron" "$OPENCLAW_DIR/"
        chmod -R go-rwx "$OPENCLAW_DIR/cron" 2>/dev/null || true
        success "cron 復元: $OPENCLAW_DIR/cron"
        info "Gateway を再起動して cron を読み込みます..."
        openclaw gateway restart || warn "gateway restart に失敗。手動で実行してください"
    else
        info "snapshot に cron がありません。スキップ"
    fi
}

# ============================================================
# Install OpenClaw
# ============================================================
install_openclaw() {
    step "1. OpenClaw インストール"

    if command -v openclaw &>/dev/null; then
        info "OpenClaw はインストール済み ($(openclaw --version 2>/dev/null || echo 'version unknown')). 再インストールします"
    fi

    npm install -g openclaw@latest
    success "OpenClaw インストール完了"
}

# ============================================================
# Telegram Bot Setup
# ============================================================
setup_telegram() {
    step "2. Telegram Bot 設定"

    info "Telegram Bot の情報が必要です"
    info "  BotFather で Bot を作成していない場合は、先に作成してください:"
    info "  1. Telegram で @BotFather を検索してチャットを開く"
    info "  2. /newbot を送信"
    info "  3. Bot名とユーザー名を入力"
    info "  4. 表示される Bot Token をコピー"
    echo
    info "グループで使う場合は BotFather で /setprivacy → Disable も実行してください"
    echo

    TELEGRAM_BOT_TOKEN=$(prompt_secret "Telegram Bot Token")
    [[ -n "$TELEGRAM_BOT_TOKEN" ]] || error "Bot Token は必須です"

    TELEGRAM_USER_ID=$(prompt_value "あなたの Telegram User ID (数値)")
    [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || error "User ID は数値で入力してください"

    success "Telegram 情報取得完了"
}

# ============================================================
# Detect Workspace & Create Symlink
# ============================================================
detect_workspace() {
    step "3. ワークスペースパス検出 + シンボリックリンク作成"

    local gdrive_path=""
    local candidates=""
    # Google Drive FileProvider のパスは find で辿れないことがあるため glob で検索
    for p in ~/Library/CloudStorage/GoogleDrive-*/My\ Drive/openclaw-workspace \
             ~/Library/CloudStorage/GoogleDrive-*/.shortcut-targets-by-id/*/openclaw-workspace \
             ~/Library/CloudStorage/GoogleDrive-*/Shared\ drives/*/openclaw-workspace; do
        if [[ -d "$p" ]]; then
            if [[ -n "$candidates" ]]; then
                candidates="$candidates"$'\n'"$p"
            else
                candidates="$p"
            fi
        fi
    done

    if [[ -n "$candidates" ]]; then
        local count
        count=$(echo "$candidates" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            gdrive_path="$candidates"
            info "ワークスペース検出: $gdrive_path"
        else
            info "複数のワークスペース候補が見つかりました:"
            echo "$candidates"
            gdrive_path=$(prompt_value "使用するワークスペースのフルパス")
        fi
    else
        warn "openclaw-workspace フォルダが見つかりません"
        gdrive_path=$(prompt_value "ワークスペースのフルパス (例: /Users/claw/Library/CloudStorage/GoogleDrive-.../My Drive/openclaw-workspace)")
    fi

    [[ -d "$gdrive_path" ]] || warn "指定されたパスが存在しません: $gdrive_path (後でGoogle Drive同期後に作成される場合があります)"

    local symlink_path="$OPENCLAW_DIR/workspace"
    mkdir -p "$OPENCLAW_DIR"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target=$(readlink "$symlink_path")
        if [[ "$current_target" == "$gdrive_path" ]]; then
            info "シンボリックリンクは既に正しく設定されています"
        else
            info "既存のシンボリックリンクを更新: $current_target → $gdrive_path"
            rm "$symlink_path"
            ln -s "$gdrive_path" "$symlink_path"
        fi
    elif [[ -e "$symlink_path" ]]; then
        warn "$symlink_path が既に存在します（シンボリックリンクではありません）。置き換えます"
        rm -rf "$symlink_path"
        ln -s "$gdrive_path" "$symlink_path"
    else
        ln -s "$gdrive_path" "$symlink_path"
    fi

    WORKSPACE_PATH="$gdrive_path"
    success "シンボリックリンク: $symlink_path → $gdrive_path"
}

# ============================================================
# Generate AGENTS.md (System Prompt)
# ============================================================
generate_agents_md() {
    step "3.5. ワークスペースに AGENTS.md 生成"

    local agents_md="$WORKSPACE_PATH/AGENTS.md"

    if [[ ! -d "$WORKSPACE_PATH" ]]; then
        warn "ワークスペースがまだ存在しません: $WORKSPACE_PATH"
        warn "AGENTS.md はGoogle Drive同期後に手動で作成してください"
        return
    fi

    if [[ -f "$agents_md" ]]; then
        info "AGENTS.md は既に存在します。上書きします"
    fi

    cat > "$agents_md" << 'AGENTSEOF'
あなたはclawアカウント（標準・非管理者）で動作しています。

## 環境
- ランタイムおよびCLI tool 管理: mise（~/.local/bin/mise）
  - 言語ランタイム（Node, Python, Go等）: `mise use -g <tool>@<version>`
    - 例: `mise use -g python@3.12`, `mise use -g go@1.22`
  - CLI tool（jq, ripgrep, fd, gh, bat 等）: `mise use -g aqua:<owner>/<repo>` または `mise use -g ubi:<owner>/<repo>`
    - 例: `mise use -g aqua:BurntSushi/ripgrep`, `mise use -g aqua:cli/cli`, `mise use -g aqua:jqlang/jq`
  - すべて `~/.local/share/mise/` 配下に隔離され、システムや admin に影響しません
- brew は利用できません（claw からの権限昇格を防ぐため）

## 実行モデル
- 隔離は OS レベルで実現されています（claw 標準アカウント、ホームディレクトリ 700、admin/他ユーザーのファイル不可視）
- exec は full mode で動作し、コマンド実行に都度承認は不要です。autonomous に動作してください

## シェルコマンドの実行ルール
- 通常のシェルコマンド（git, node, npm, python, ファイル操作, ビルド, テスト等）は自由に実行してください
- 言語ランタイム・CLI tool は mise で自分でインストールしてください
- 以下の操作は自分では実行できません。必要な場合はユーザーに実行すべきコマンド群を提示し、管理者アカウントでの手動実行を依頼してください:
  - sudo を必要とする操作（システム設定変更、サービス管理、パーミッション変更等）
  - brew を必要とする操作（formula / cask いずれも、admin アカウントでのみ実行）
  - LaunchDaemon の作成・変更（/Library/LaunchDaemons/）
  - システム全体に影響する設定変更

## 依頼時のフォーマット
ユーザーへの依頼は以下の形式で送信してください:

管理者権限が必要な作業があります

実行が必要なコマンド:
```bash
# （ここにコマンドを記述）
```

理由: （なぜこの作業が必要か簡潔に）

完了したら教えてください。

## ワークスペース
- 作業ディレクトリ: Google Drive共有フォルダ内
- このフォルダは個人PCのGoogle Driveと同期されています。ファイルの変更は自動的に個人PC側に反映されます。
AGENTSEOF

    success "AGENTS.md 生成: $agents_md"
}

# ============================================================
# Generate Config
# ============================================================
generate_config() {
    step "4. 設定ファイル生成"

    mkdir -p "$OPENCLAW_DIR"

    local gateway_token
    gateway_token=$(openssl rand -hex 32)
    info "Gateway auth token を生成しました"

    local tailscale_origin=""
    local ts_hostname
    ts_hostname=$(tailscale status --self --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null) || true
    if [[ -n "$ts_hostname" ]]; then
        tailscale_origin="https://${ts_hostname}"
        info "Tailscale ホスト名検出: ${ts_hostname}"
    else
        warn "Tailscale ホスト名を自動検出できません"
        tailscale_origin=$(prompt_value "Tailscale Serve の URL (例: https://mac-mini.tailnet-name.ts.net)")
    fi

    cat > "$OPENCLAW_CONFIG" << CONFIGEOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "${gateway_token}"
    },
    "tailscale": {
      "mode": "serve"
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyAllowHostHeaderOriginFallback": false,
      "dangerouslyDisableDeviceAuth": false,
      "allowedOrigins": ["${tailscale_origin}"]
    }
  },

  "channels": {
    "telegram": {
      "dmPolicy": "allowlist",
      "allowFrom": [
        ${TELEGRAM_USER_ID}
      ],
      "groupPolicy": "allowlist",
      "groupAllowFrom": [
        ${TELEGRAM_USER_ID}
      ],
      "errorPolicy": "always",
      "errorCooldownMs": 120000,
      "textChunkLimit": 3500,
      "mediaMaxMb": 20,
      "retry": {
        "attempts": 3,
        "minDelayMs": 100,
        "maxDelayMs": 5000,
        "jitter": 0.1
      },
      "timeoutSeconds": 60,
      "actions": {
        "sendMessage": true,
        "deleteMessage": false,
        "reactions": false,
        "sticker": false
      },
      "execApprovals": {
        "enabled": false,
        "approvers": [${TELEGRAM_USER_ID}],
        "target": "dm"
      },
      "network": {
        "autoSelectFamily": true,
        "dnsResultOrder": "ipv4first"
      },
      "streaming": {
        "mode": "partial",
        "preview": {
          "toolProgress": false
        }
      }
    }
  },

  "tools": {
    "profile": "coding",
    "deny": [],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "full"
    }
  },

  "browser": {
    "ssrfPolicy": {
      "dangerouslyAllowPrivateNetwork": false
    }
  },

  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-7",
        "fallbacks": ["anthropic/claude-sonnet-4-6"]
      },
      "sandbox": {
        "mode": "off"
      }
    }
  },

  "session": {
    "dmScope": "per-channel-peer"
  },

  "logging": {
    "redactSensitive": "tools"
  },

  "discovery": {
    "mdns": {
      "mode": "minimal"
    }
  }
}
CONFIGEOF

    success "設定ファイル生成: $OPENCLAW_CONFIG"
}

# ============================================================
# Setup Secrets (.env)
# ============================================================
setup_secrets() {
    step "5. シークレット設定 (~/.openclaw/.env)"

    local env_file="$OPENCLAW_DIR/.env"

    local anthropic_key
    anthropic_key=$(prompt_secret "Anthropic API Key (sk-ant-...)")
    [[ -n "$anthropic_key" ]] || error "Anthropic API Key は必須です"

    if [[ -f "$env_file" ]]; then
        sed -i '' '/^TELEGRAM_BOT_TOKEN=/d' "$env_file"
        sed -i '' '/^ANTHROPIC_API_KEY=/d' "$env_file"
        sed -i '' '/^OLLAMA_API_KEY=/d' "$env_file"
    fi

    cat >> "$env_file" << ENVEOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
ANTHROPIC_API_KEY="${anthropic_key}"
OLLAMA_API_KEY="ollama-local"
ENVEOF
    chmod 600 "$env_file"

    success "TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY, OLLAMA_API_KEY を $env_file に設定"

    info "確認中..."
    openclaw models status || true
}

# ============================================================
# File Permissions
# ============================================================
setup_permissions() {
    step "7. ファイルパーミッション設定"
    chmod 700 "$OPENCLAW_DIR"
    chmod 600 "$OPENCLAW_CONFIG"
    find "$OPENCLAW_DIR/credentials" -type f -exec chmod 600 {} \; 2>/dev/null || true
    success "パーミッション設定完了 (~/.openclaw: 700, 設定ファイル: 600)"
}

# ============================================================
# Spotlight 除外
# ============================================================
exclude_spotlight() {
    step "7.5. Spotlight インデックス除外"
    touch "$OPENCLAW_DIR/.metadata_never_index"
    success "$OPENCLAW_DIR を Spotlight インデックスから除外"
    if [[ -d "${WORKSPACE_PATH:-}" ]]; then
        touch "${WORKSPACE_PATH}/.metadata_never_index" 2>/dev/null \
            && success "${WORKSPACE_PATH} を Spotlight インデックスから除外" \
            || info "ワークスペースの除外はスキップ（権限なし）"
    fi
}

# ============================================================
# Shell Completion (zsh)
# ============================================================
install_completions() {
    step "7.6. シェル補完 (zsh) インストール"

    # --install: ~/.zshrc に source 行を追加（既存があれば idempotent）
    # --write-state: $OPENCLAW_STATE_DIR/completions/openclaw.zsh に補完スクリプトを書き込む
    if openclaw completion --shell zsh --install --write-state >/dev/null 2>&1; then
        success "zsh 補完を ~/.openclaw/completions/openclaw.zsh に生成"
        info "新しいシェルから有効になります（既存セッションは 'exec zsh' で再読込）"
    else
        warn "openclaw completion コマンドが失敗しました（補完なしで続行）"
    fi
}

# ============================================================
# Start Gateway & Verify
# ============================================================
start_and_verify() {
    step "8. Gateway デーモン登録・起動・検証"

    info "LaunchAgent 登録中..."
    openclaw gateway install --force
    success "LaunchAgent 登録完了"

    inject_launchagent_env

    info "Doctor fix 実行中..."
    openclaw doctor --fix || true

    info "Gateway 起動中..."
    if openclaw gateway restart; then
        success "Gateway 起動完了"
    else
        warn "Gateway 起動のヘルスチェックがタイムアウトしました"
        warn "ログを確認してください: openclaw logs --follow"
    fi

    step "9. セキュリティ監査"
    openclaw security audit || true
    echo
    openclaw security audit --deep || true

    step "10. インストール確認"
    openclaw doctor || true
    openclaw status || true
}

# ============================================================
# LaunchAgent plist に環境変数を注入
# ============================================================
inject_launchagent_env() {
    step "8.1 LaunchAgent plist に OPENCLAW_NO_RESPAWN=1 を注入"

    local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if [[ ! -f "$plist" ]]; then
        warn "LaunchAgent plist が見つかりません: $plist"
        return
    fi

    # 既存のキーがあれば削除してから追加（idempotent）
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:OPENCLAW_NO_RESPAWN" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OPENCLAW_NO_RESPAWN string 1" "$plist"

    success "OPENCLAW_NO_RESPAWN=1 を $plist に注入"
    info "config 変更時の SIGUSR1 in-process restart による respawn ループを防止"
}

# ============================================================
# Telegram Verification
# ============================================================
verify_telegram() {
    step "11. Telegram 動作確認"
    info "Telegram で作成した Bot にDMを送信して、応答が返ることを確認してください"
    info "allowlist に含まれない別ユーザーからのメッセージがブロックされることも確認してください"
    wait_user
    success "Telegram 動作確認完了"
}

# ============================================================
# Usage
# ============================================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OpenClaw のインストールと設定を行います。"
    echo "既存の ~/.openclaw がある場合は自動的に ~/.openclaw-snapshot-<ts>/ にバックアップを取り、"
    echo "クリーン状態で再構築します。Google Drive 上の workspace 中身も snapshot に退避されます。"
    echo "（初回セットアップ時はバックアップをスキップします）"
    echo ""
    echo "Options:"
    echo "  --recover  セットアップ完了後、最新の ~/.openclaw-snapshot-* から workspace と"
    echo "             ~/.openclaw/cron を復元します。それ以外（identity, telegram, agents 等）の"
    echo "             復元はユーザーが手動で行ってください。"
    echo "  --help     このヘルプを表示"
}

# ============================================================
# Main
# ============================================================
main() {
    local recover=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recover) recover=true; shift ;;
            --help)    usage; exit 0 ;;
            *)         error "Unknown option: $1\nRun '$0 --help' for usage." ;;
        esac
    done

    echo -e "${BOLD}OpenClaw Gateway - OpenClaw Setup${NC}"
    echo -e "${BOLD}==================================${NC}"
    echo
    preflight

    if [[ -d "$OPENCLAW_DIR" ]]; then
        backup_and_reset
    else
        info "既存の ~/.openclaw が見つからないためバックアップをスキップ（初回セットアップ）"
    fi

    echo
    info "このスクリプトは以下を実行します:"
    info "  1. OpenClaw インストール"
    info "  2. Telegram Bot 設定"
    info "  3. ワークスペースパス検出 + AGENTS.md 生成"
    info "  4. 設定ファイル生成 (openclaw.json)"
    info "  5. 環境変数・APIキー設定"
    info "  6. ファイルパーミッション設定 + Spotlight 除外"
    info "  7. シェル補完 (zsh) インストール"
    info "  8. Gateway デーモン登録・OPENCLAW_NO_RESPAWN 注入・検証"
    if $recover; then
        info "  9. snapshot から workspace + cron を復元 (--recover)"
    fi
    echo

    install_openclaw
    setup_telegram
    detect_workspace
    generate_agents_md
    generate_config
    setup_secrets
    setup_permissions
    exclude_spotlight
    install_completions
    start_and_verify
    verify_telegram

    if $recover; then
        do_recover
    fi

    echo
    step "OpenClaw Setup 完了!"
    info ""
    info "再起動後の復旧手順:"
    info "  1. Tailscaleは自動接続 (LaunchDaemon)"
    info "  2. Screen Sharing で claw アカウントにログイン"
    info "  3. OpenClaw は LaunchAgent で自動起動 (KeepAlive によりプロセス死亡時に自動復帰)"
    info "  4. Google Drive の同期完了を確認"
    info "  5. Telegram からメッセージを送信して動作確認"
    info ""
    info "snapshot から workspace + cron を復元する場合（次回セットアップ時に指定）:"
    info "  $0 --recover"
}

main "$@"
