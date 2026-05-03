#!/bin/bash
set -euo pipefail

source "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/lib.sh"

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

    info "Google Drive for Desktop の手順は README.md の「Google Drive セットアップ」セクションを参照してください"
    info "（専用 Google アカウントでサインイン → ミラーリング → openclaw-workspace 共有フォルダを My Drive に追加）"
    open -a "Google Drive" 2>/dev/null || warn "Google Drive を手動で起動してください"
    wait_user

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

    export PATH="$HOME/.local/bin:$PATH"
    eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true
}

# ============================================================
# Node.js Installation
# ============================================================
setup_nodejs() {
    step "4. Node.js インストール (mise経由)"

    if command -v node &>/dev/null; then
        info "Node.js はインストール済み: $(node --version 2>/dev/null || echo 'unknown')"
        if ! confirm "再インストールしますか?"; then
            return
        fi
    fi

    ~/.local/bin/mise use -g node@24
    success "Node.js インストール完了"

    eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true

    info "Node.js: $(node --version 2>/dev/null || echo 'not in path yet')"
    info "npm: $(npm --version 2>/dev/null || echo 'not in path yet')"
}

# ============================================================
# Verify Restrictions
# ============================================================
verify_restrictions() {
    step "5. 権限制限の確認 (sudo / brew が claw から不可)"
    local all_ok=true

    info "sudo が使えないことを確認..."
    if sudo -n true 2>/dev/null; then
        warn "sudo が実行可能です。セキュリティリスクの可能性があります。"
        all_ok=false
    else
        success "sudo 実行不可 (期待通り)"
    fi

    info "brew が使えないことを確認..."
    if command -v brew &>/dev/null; then
        warn "brew が利用可能です。claw アカウントには不要です。"
        all_ok=false
    else
        success "brew 未インストール (期待通り)"
    fi

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
