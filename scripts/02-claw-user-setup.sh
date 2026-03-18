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
    eval "$(~/.local/bin/mise activate zsh)" 2>/dev/null || true
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
    eval "$(~/.local/bin/mise activate zsh)" 2>/dev/null || true

    info "Node.js: $(node --version 2>/dev/null || echo 'not in path yet')"
    info "npm: $(npm --version 2>/dev/null || echo 'not in path yet')"
}

# ============================================================
# Verify Restrictions
# ============================================================
verify_restrictions() {
    step "5. 権限制限の確認"
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
    echo
    info "このスクリプトは以下を実行します:"
    info "  1. Google Drive セットアップ (GUI操作あり)"
    info "  2. mise (ランタイムマネージャ) インストール"
    info "  3. Node.js インストール"
    info "  4. 権限制限の確認"
    echo
    confirm "実行しますか?" || { info "中止しました"; exit 0; }

    setup_google_drive
    setup_mise
    setup_nodejs
    verify_restrictions

    echo
    step "Claw User Setup 完了!"
    info "次のステップ:"
    info "  03-openclaw-setup.sh を実行して OpenClaw をインストール・設定してください"
}

main "$@"
