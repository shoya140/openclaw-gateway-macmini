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
    echo
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
    eval "$(~/.local/bin/mise activate zsh 2>/dev/null)" || true

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

    # ~/.zprofile から TELEGRAM_BOT_TOKEN を削除
    if [[ -f ~/.zprofile ]]; then
        sed -i '' '/^export TELEGRAM_BOT_TOKEN=/d' ~/.zprofile 2>/dev/null || true
        info "~/.zprofile から TELEGRAM_BOT_TOKEN を削除"
    fi

    # OpenClaw アンインストール
    info "OpenClaw アンインストール中..."
    npm uninstall -g openclaw 2>/dev/null || true

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
        info "OpenClaw はインストール済み ($(openclaw --version 2>/dev/null || echo 'version unknown'))"
        if ! confirm "再インストールしますか?"; then
            return
        fi
    fi

    npm install -g openclaw@latest
    success "OpenClaw インストール完了"

    info "初期セットアップ実行中..."
    openclaw onboard --install-daemon
    success "初期セットアップ完了"
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
# Detect Workspace
# ============================================================
detect_workspace() {
    step "3. ワークスペースパス検出"

    local candidates
    candidates=$(find ~/Library/CloudStorage/ -maxdepth 3 -type d -name "openclaw-workspace" 2>/dev/null || true)

    if [[ -n "$candidates" ]]; then
        local count
        count=$(echo "$candidates" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            WORKSPACE_PATH="$candidates"
            info "ワークスペース検出: $WORKSPACE_PATH"
            if ! confirm "このパスを使用しますか?"; then
                WORKSPACE_PATH=$(prompt_value "ワークスペースのフルパス")
            fi
        else
            info "複数のワークスペース候補が見つかりました:"
            echo "$candidates"
            WORKSPACE_PATH=$(prompt_value "使用するワークスペースのフルパス")
        fi
    else
        warn "openclaw-workspace フォルダが見つかりません"
        WORKSPACE_PATH=$(prompt_value "ワークスペースのフルパス (例: /Users/claw/Library/CloudStorage/GoogleDrive-.../My Drive/openclaw-workspace)")
    fi

    [[ -d "$WORKSPACE_PATH" ]] || warn "指定されたパスが存在しません: $WORKSPACE_PATH (後でGoogle Drive同期後に作成される場合があります)"
    success "ワークスペースパス: $WORKSPACE_PATH"
}

# ============================================================
# Generate Config
# ============================================================
generate_config() {
    step "4. 設定ファイル生成"

    mkdir -p "$OPENCLAW_DIR"

    cat > "$OPENCLAW_CONFIG" << CONFIGEOF
{
  "gateway": {
    "bind": "loopback",
    "auth": {
      "mode": "token"
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
        "jitter": true
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

  "agent": {
    "workspace": "${WORKSPACE_PATH}"
  },

  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "exec",
        "workspaceAccess": "rw"
      },
      "tools": {
        "profile": "developer",
        "deny": [
          "sessions_spawn",
          "sessions_send",
          "gateway",
          "cron"
        ],
        "fs": {
          "workspaceOnly": false,
          "deny": [
            "/Users/*/.*",
            "/etc/**",
            "/Library/**"
          ]
        },
        "exec": {
          "security": "sandbox"
        }
      },
      "systemPrompt": "あなたはclawアカウント（標準・非管理者）で動作しています。\n\n## 環境\n- ランタイム管理: mise（~/.local/bin/mise）\n  - 新しいランタイムが必要な場合は \`mise use -g <tool>@<version>\` で自分でインストールできます\n  - 例: \`mise use -g python@3.12\`, \`mise use -g go@1.22\`\n- Node.js: mise経由でインストール済み\n\n## シェルコマンドの実行ルール\n- 通常のシェルコマンド（git, node, npm, python, ファイル操作, ビルド, テスト等）は自由に実行してください。\n- miseで管理可能なランタイムのインストール・バージョン変更は自分で実行してください。\n- 以下の操作は自分では実行できません。必要な場合はユーザーに実行すべきコマンド群を提示し、管理者アカウントでの手動実行を依頼してください:\n  - sudo を必要とする操作（システム設定変更、サービス管理、パーミッション変更等）\n  - brew を必要とする操作（ソフトウェアのインストール・アンインストール）\n  - LaunchDaemonの作成・変更（/Library/LaunchDaemons/）\n  - システム全体に影響する設定変更\n\n## 依頼時のフォーマット\nユーザーへの依頼は以下の形式で送信してください:\n\n管理者権限が必要な作業があります\n\n実行が必要なコマンド:\n```bash\n# （ここにコマンドを記述）\n```\n\n理由: （なぜこの作業が必要か簡潔に）\n\n完了したら教えてください。\n\n## ワークスペース\n- 作業ディレクトリ: Google Drive共有フォルダ内（agent.workspaceで設定されたパス）\n- このフォルダは個人PCのGoogle Driveと同期されています。ファイルの変更は自動的に個人PC側に反映されます。"
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
# Setup Environment Variables
# ============================================================
setup_env() {
    step "5. 環境変数設定"

    # TELEGRAM_BOT_TOKEN
    if grep -q "^export TELEGRAM_BOT_TOKEN=" ~/.zprofile 2>/dev/null; then
        if confirm "TELEGRAM_BOT_TOKEN は既に設定済みです。上書きしますか?"; then
            sed -i '' '/^export TELEGRAM_BOT_TOKEN=/d' ~/.zprofile
        else
            info "TELEGRAM_BOT_TOKEN はそのまま維持"
            setup_api_keys
            return
        fi
    fi

    {
        echo ""
        echo "# OpenClaw - Telegram Bot Token"
        echo "export TELEGRAM_BOT_TOKEN=\"${TELEGRAM_BOT_TOKEN}\""
    } >> ~/.zprofile

    export TELEGRAM_BOT_TOKEN
    success "TELEGRAM_BOT_TOKEN を ~/.zprofile に設定"

    setup_api_keys
}

setup_api_keys() {
    step "6. LLM APIキー設定"

    info "APIキーをキーチェーンに安全に保存します"
    info "プロンプトに従いAPIキーを入力してください"
    echo

    if confirm "Anthropic APIキーを設定しますか?"; then
        openclaw auth add anthropic
        success "Anthropic APIキー設定完了"
    fi

    if confirm "他のLLMプロバイダーのAPIキーを設定しますか?"; then
        local provider
        provider=$(prompt_value "プロバイダー名 (例: openai, google)")
        openclaw auth add "$provider"
        success "${provider} APIキー設定完了"
    fi
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
    step "8. Gateway 起動・検証"

    # .zprofile を読み込んで環境変数を有効化
    source ~/.zprofile 2>/dev/null || true

    info "Gateway 起動中..."
    openclaw gateway restart

    step "9. セキュリティ監査"
    openclaw security audit || true
    echo
    if confirm "Deep audit を実行しますか?"; then
        openclaw security audit --deep || true
    fi

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
    info "  3. ワークスペースパス検出"
    info "  4. 設定ファイル生成 (openclaw.json)"
    info "  5. 環境変数・APIキー設定"
    info "  6. ファイルパーミッション設定"
    info "  7. Gateway 起動・検証"
    echo
    confirm "実行しますか?" || { info "中止しました"; exit 0; }

    install_openclaw
    setup_telegram
    detect_workspace
    generate_config
    setup_env
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
