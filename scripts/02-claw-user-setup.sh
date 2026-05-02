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

# ============================================================
# Project .env loader
# OLLAMA_MODEL を読み込む。未設定時は setup_ollama_preload で既定値を適用。
# ============================================================
load_project_env() {
    local script_dir project_root project_env
    script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    project_root="$( dirname "$script_dir" )"
    project_env="$project_root/.env"
    if [[ -f "$project_env" ]]; then
        # shellcheck source=/dev/null
        set -a
        source "$project_env"
        set +a
        info "プロジェクト .env を読み込みました: $project_env"
    fi
}

# ============================================================
# Pre-flight checks
# ============================================================
preflight() {
    [[ "$(uname)" == "Darwin" ]] || error "macOS専用スクリプトです"
    [[ "$(whoami)" == "claw" ]] || error "このスクリプトは 'claw' ユーザーで実行してください (現在: $(whoami))"
    success "Pre-flight OK (user: claw)"
}

# ============================================================
# Google Drive Setup (GUI必須)
# ============================================================
setup_google_drive() {
    step "1. Google Drive セットアップ"

    if [[ ! -d "/Applications/Google Drive.app" ]]; then
        error "Google Drive for Desktop がインストールされていません。先に 01-admin-macos-setup.sh を実行してください"
    fi

    info "Google Drive for Desktop のセットアップが必要です（GUI操作）"
    info ""
    info "以下の手順を実行してください:"
    info "  1. Google Drive アプリを起動 (自動で開きます)"
    info "  2. Open Claw専用Googleアカウントでサインイン"
    info "  3. 同期モードを「ミラーリング」に設定:"
    info "     Google Driveメニュー → 設定 → Google Drive → ミラーリング"
    info "  4. 個人が共有したワークスペースフォルダが表示されることを確認"
    info "  5. 共有フォルダをMy Driveに追加"
    info "     (右クリック → 整理 → ショートカットを追加 → マイドライブ)"
    echo

    open -a "Google Drive" 2>/dev/null || warn "Google Drive を手動で起動してください"

    wait_user

    # ワークスペースパスの検出
    local workspace_candidates
    workspace_candidates=$(find ~/Library/CloudStorage/ -maxdepth 3 -type d -name "openclaw-workspace" 2>/dev/null || true)

    if [[ -n "$workspace_candidates" ]]; then
        info "ワークスペース候補:"
        echo "$workspace_candidates"
        success "Google Drive ワークスペース検出済み"
    else
        warn "openclaw-workspace フォルダが見つかりません"
        info "Google Driveの同期が完了した後、以下のパスを確認してください:"
        info "  ~/Library/CloudStorage/GoogleDrive-<account>/My Drive/openclaw-workspace/"
    fi
}

# ============================================================
# mise Installation
# ============================================================
setup_mise() {
    step "2. mise インストール"

    if command -v mise &>/dev/null; then
        info "mise はインストール済み ($(mise --version 2>/dev/null || echo 'version unknown'))"
    elif [[ -f ~/.local/bin/mise ]]; then
        info "mise はインストール済み (パス未設定)"
    else
        info "mise をインストール中..."
        curl -fsSL https://mise.run | sh
        success "mise インストール完了"
    fi

    step "3. シェル設定"
    local mise_init='eval "$(~/.local/bin/mise activate zsh)"'

    if ! grep -qF "compinit" ~/.zshrc 2>/dev/null; then
        sed -i '' '1i\
autoload -Uz compinit \&\& compinit\
' ~/.zshrc 2>/dev/null || {
            echo "autoload -Uz compinit && compinit" > /tmp/.zshrc_new
            echo "" >> /tmp/.zshrc_new
            cat ~/.zshrc >> /tmp/.zshrc_new 2>/dev/null
            mv /tmp/.zshrc_new ~/.zshrc
        }
        success "~/.zshrc に compinit 初期化を追加"
    fi

    if grep -qF "mise activate" ~/.zshrc 2>/dev/null; then
        info "mise のシェル統合は設定済み"
    else
        echo "" >> ~/.zshrc
        echo "# mise runtime manager" >> ~/.zshrc
        echo "$mise_init" >> ~/.zshrc
        success "~/.zshrc に mise 設定を追加"
    fi

    # 現在のシェルで mise を有効化
    export PATH="$HOME/.local/bin:$PATH"
    eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true
}

# ============================================================
# Node.js Installation
# ============================================================
setup_nodejs() {
    step "4. Node.js インストール (mise経由)"

    if command -v node &>/dev/null; then
        local node_ver
        node_ver=$(node --version 2>/dev/null || echo "unknown")
        info "Node.js はインストール済み: ${node_ver}"
        if ! confirm "再インストールしますか?"; then
            return
        fi
    fi

    ~/.local/bin/mise use -g node@24
    success "Node.js インストール完了"

    # mise 経由で有効化
    eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true

    info "Node.js: $(node --version 2>/dev/null || echo 'not in path yet')"
    info "npm: $(npm --version 2>/dev/null || echo 'not in path yet')"
}

# ============================================================
# Ollama モデル pull
# Ollama daemon 自体は 01-admin-macos-setup.sh が claw として常駐させている。
# OLLAMA_MODEL（未指定時は qwen3.6:35b-a3b）を pull する。
# `ollama pull` は冪等で、既に最新ならすぐに完了する。
# ============================================================
setup_ollama_pull() {
    step "5. Ollama モデル pull"
    local model="${OLLAMA_MODEL:-qwen3.6:35b-a3b}"
    local ollama_bin="/opt/homebrew/bin/ollama"

    [[ -x "$ollama_bin" ]] || error "ollama CLI が見つかりません: $ollama_bin (先に 01-admin-macos-setup.sh を実行してください)"

    # Daemon 起動待ち
    local i
    for i in $(seq 1 30); do
        curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1 && break
        sleep 2
    done
    curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1 \
        || error "Ollama daemon (127.0.0.1:11434) に接続できません。/Library/LaunchDaemons/io.shoya.ollama.plist の起動状態を確認してください"
    info "Ollama daemon 起動確認"

    info "ollama pull $model (既に最新の場合は即終了)..."
    "$ollama_bin" pull "$model" || error "ollama pull $model に失敗しました"
    success "モデル $model 用意完了"
}

# ============================================================
# Ollama preload LaunchAgent
# 起動時に OLLAMA_MODEL を keep_alive=-1 で温める。
# ============================================================
setup_ollama_preload() {
    step "6. Ollama preload LaunchAgent"
    local model="${OLLAMA_MODEL:-qwen3.6:35b-a3b}"
    local agent_dir="$HOME/Library/LaunchAgents"
    local plist="$agent_dir/io.shoya.ollama-preload.plist"
    mkdir -p "$agent_dir"

    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.shoya.ollama-preload</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>for i in \$(seq 1 30); do curl -sf http://127.0.0.1:11434/api/tags &gt; /dev/null 2&gt;&amp;1 &amp;&amp; break; sleep 2; done; curl -sf http://127.0.0.1:11434/api/chat -d '{"model":"${model}","messages":[],"keep_alive":-1}' &gt; /dev/null 2&gt;&amp;1</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ollama-preload.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ollama-preload.err.log</string>
</dict>
</plist>
PLIST
    chmod 644 "$plist"

    # 旧 ai.ollama.preload があれば停止 + 削除
    if [[ -f "$agent_dir/ai.ollama.preload.plist" ]]; then
        launchctl bootout "gui/$UID/ai.ollama.preload" 2>/dev/null || true
        rm -f "$agent_dir/ai.ollama.preload.plist"
    fi

    launchctl bootout "gui/$UID/io.shoya.ollama-preload" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$plist"
    success "Preload LaunchAgent 配置 (model=$model)"
}

# ============================================================
# Verify Restrictions
# ============================================================
verify_restrictions() {
    step "7. 権限制限の確認"
    local all_ok=true

    # sudo チェック
    info "sudo が使えないことを確認..."
    if sudo -n true 2>/dev/null; then
        warn "sudo が実行可能です。セキュリティリスクの可能性があります。"
        all_ok=false
    else
        success "sudo 実行不可 (期待通り)"
    fi

    # brew チェック
    info "brew が使えないことを確認..."
    if command -v brew &>/dev/null; then
        warn "brew が利用可能です。claw アカウントには不要です。"
        all_ok=false
    else
        success "brew 未インストール (期待通り)"
    fi

    # mise チェック
    info "mise が使えることを確認..."
    if ~/.local/bin/mise --version &>/dev/null; then
        success "mise 利用可能"
    else
        warn "mise が見つかりません"
        all_ok=false
    fi

    if $all_ok; then
        success "全ての権限チェックに合格"
    else
        warn "一部のチェックで警告があります。上記の出力を確認してください。"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo -e "${BOLD}OpenClaw Gateway - Claw User Setup${NC}"
    echo -e "${BOLD}====================================${NC}"
    echo
    preflight
    load_project_env
    echo
    info "このスクリプトは以下を実行します:"
    info "  1. Google Drive セットアップ (GUI操作あり)"
    info "  2. mise (ランタイムマネージャ) インストール"
    info "  3. Node.js インストール"
    info "  4. Ollama モデル pull (OLLAMA_MODEL or qwen3.6:35b-a3b)"
    info "  5. Ollama preload LaunchAgent (起動時にモデルを温める)"
    info "  6. 権限制限の確認"
    echo
    confirm "実行しますか?" || { info "中止しました"; exit 0; }

    setup_google_drive
    setup_mise
    setup_nodejs
    setup_ollama_pull
    setup_ollama_preload
    verify_restrictions

    echo
    step "Claw User Setup 完了!"
    info "次のステップ:"
    info "  03-openclaw-setup.sh を実行して OpenClaw をインストール・設定してください"
}

main "$@"
