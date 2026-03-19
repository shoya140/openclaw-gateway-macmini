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
# Reinit: アンインストール・クリーンアップ
# ============================================================
do_reinit() {
    step "Reinit: OpenClaw の初期化"
    warn "既存のOpenClawインストールを完全に削除し、再インストールします"

    if ! confirm "本当に実行しますか?"; then
        info "中止しました"
        exit 0
    fi

    # Gateway 停止
    info "Gateway 停止中..."
    openclaw gateway stop 2>/dev/null || true

    # LaunchAgent 削除
    info "LaunchAgent 削除中..."
    launchctl remove ai.openclaw.gateway 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true

    # 設定のバックアップ
    if [[ -f "$OPENCLAW_CONFIG" ]]; then
        local backup="/tmp/openclaw-config-backup-$(date +%Y%m%d%H%M%S).json"
        cp "$OPENCLAW_CONFIG" "$backup"
        info "設定ファイルをバックアップ: $backup"
    fi

    # OpenClaw アンインストール
    info "OpenClaw アンインストール中..."
    npm uninstall -g openclaw 2>/dev/null || true

    # ワークスペースのシンボリックリンクを削除（実体のGoogle Driveフォルダは保持）
    if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
        info "ワークスペースのシンボリックリンクを削除（Google Driveの実体は保持）..."
        rm "$OPENCLAW_DIR/workspace"
    fi

    # データディレクトリ削除
    info "データディレクトリ削除中..."
    rm -rf "$OPENCLAW_DIR"

    success "OpenClaw の初期化完了"
    echo
    info "再インストールを続行します..."
    echo
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
- ランタイム管理: mise（~/.local/bin/mise）
  - 新しいランタイムが必要な場合は `mise use -g <tool>@<version>` で自分でインストールできます
  - 例: `mise use -g python@3.12`, `mise use -g go@1.22`
- Node.js: mise経由でインストール済み

## シェルコマンドの実行ルール
- 通常のシェルコマンド（git, node, npm, python, ファイル操作, ビルド, テスト等）は自由に実行してください。
- miseで管理可能なランタイムのインストール・バージョン変更は自分で実行してください。
- 以下の操作は自分では実行できません。必要な場合はユーザーに実行すべきコマンド群を提示し、管理者アカウントでの手動実行を依頼してください:
  - sudo を必要とする操作（システム設定変更、サービス管理、パーミッション変更等）
  - brew を必要とする操作（ソフトウェアのインストール・アンインストール）
  - LaunchDaemonの作成・変更（/Library/LaunchDaemons/）
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
      "allowInsecureAuth": false
    }
  },

  "channels": {
    "telegram": {
      "dmPolicy": "allowlist",
      "allowFrom": [
        ${TELEGRAM_USER_ID}
      ],
      "groupPolicy": "allowlist",
      "mediaMaxMb": 20,
      "retry": {
        "attempts": 3,
        "minDelayMs": 100,
        "maxDelayMs": 5000,
        "jitter": 0.1
      },
      "timeoutSeconds": 30,
      "actions": {
        "deleteMessage": false,
        "sticker": false
      },
      "execApprovals": {
        "enabled": true,
        "approvers": [${TELEGRAM_USER_ID}],
        "target": "dm"
      }
    }
  },

  "tools": {
    "profile": "coding",
    "deny": [
      "sessions_spawn",
      "sessions_send",
      "gateway",
      "cron"
    ],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "full"
    }
  },

  "agents": {
    "defaults": {
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

    # Anthropic API Key
    local anthropic_key
    anthropic_key=$(prompt_secret "Anthropic API Key (sk-ant-...)")
    [[ -n "$anthropic_key" ]] || error "Anthropic API Key は必須です"

    # 既存のエントリを削除してから書き込み
    if [[ -f "$env_file" ]]; then
        sed -i '' '/^TELEGRAM_BOT_TOKEN=/d' "$env_file"
        sed -i '' '/^ANTHROPIC_API_KEY=/d' "$env_file"
    fi

    cat >> "$env_file" << ENVEOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
ANTHROPIC_API_KEY="${anthropic_key}"
ENVEOF
    chmod 600 "$env_file"

    success "TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY を $env_file に設定"

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
# Start Gateway & Verify
# ============================================================
start_and_verify() {
    step "8. Gateway デーモン登録・起動・検証"

    info "LaunchAgent 登録中..."
    openclaw gateway install --force
    success "LaunchAgent 登録完了"

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
    echo ""
    echo "Options:"
    echo "  --reinit    既存のインストールを削除し、再インストールする"
    echo "  --help      このヘルプを表示"
}

# ============================================================
# Main
# ============================================================
main() {
    local reinit=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reinit) reinit=true; shift ;;
            --help)   usage; exit 0 ;;
            *)        error "Unknown option: $1\nRun '$0 --help' for usage." ;;
        esac
    done

    echo -e "${BOLD}OpenClaw Gateway - OpenClaw Setup${NC}"
    echo -e "${BOLD}==================================${NC}"
    echo
    preflight

    if $reinit; then
        do_reinit
    fi

    echo
    info "このスクリプトは以下を実行します:"
    info "  1. OpenClaw インストール"
    info "  2. Telegram Bot 設定"
    info "  3. ワークスペースパス検出 + AGENTS.md 生成"
    info "  4. 設定ファイル生成 (openclaw.json)"
    info "  5. 環境変数・APIキー設定"
    info "  6. ファイルパーミッション設定"
    info "  7. Gateway デーモン登録・起動・検証"
    echo

    install_openclaw
    setup_telegram
    detect_workspace
    generate_agents_md
    generate_config
    setup_secrets
    setup_permissions
    start_and_verify
    verify_telegram

    echo
    step "OpenClaw Setup 完了!"
    info ""
    info "再起動後の復旧手順:"
    info "  1. Tailscaleは自動接続 (LaunchDaemon)"
    info "  2. Screen Sharing で claw アカウントにログイン"
    info "  3. OpenClaw は LaunchAgent で自動起動"
    info "  4. Google Drive の同期完了を確認"
    info "  5. Telegram からメッセージを送信して動作確認"
    info ""
    info "再インストールが必要な場合:"
    info "  $0 --reinit"
}

main "$@"
