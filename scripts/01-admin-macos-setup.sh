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
    [[ "$(id -u)" -ne 0 ]] || error "rootではなく管理者ユーザーで実行してください"
    dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -qw "$(whoami)" \
        || error "現在のユーザー '$(whoami)' は管理者ではありません"
    command -v brew &>/dev/null || error "Homebrewが必要です: https://brew.sh"
    success "Pre-flight OK (admin: $(whoami), macOS $(sw_vers -productVersion))"
}

# ============================================================
# Phase 1: macOS Security
# ============================================================
setup_firewall() {
    step "1.1 ファイアウォール + ステルスモード"
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode
    success "ファイアウォール + ステルスモード有効化"
}

setup_home_dir() {
    step "1.2 管理者ホームディレクトリ保護"
    chmod 700 ~/
    success "~/  → mode 700"
}

setup_sleep() {
    step "1.3 スリープ防止設定 (24/7運用)"
    sudo pmset -a sleep 0 disksleep 0 displaysleep 0
    sudo pmset -a hibernatemode 0 powernap 0
    sudo pmset -a standby 0 autopoweroff 0
    sudo pmset -a autorestart 1
    success "スリープ防止設定完了"
}

setup_autologin() {
    step "1.4 自動ログイン無効化"
    sudo sysadminctl -autologin off 2>/dev/null || {
        sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
    }
    if defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1 | grep -q "does not exist"; then
        success "自動ログイン無効"
    else
        warn "自動ログインの状態を確認してください: システム設定 → ユーザとグループ → ログインオプション"
    fi
}

setup_screen_sharing() {
    step "1.5 Screen Sharing (画面共有)"
    # macOS 12.1+ではTCC制限によりCLIだけでは完全に有効化できない場合がある
    sudo launchctl enable system/com.apple.screensharing 2>/dev/null || true
    sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

    if sudo launchctl list 2>/dev/null | grep -q screensharing; then
        success "Screen Sharing サービス起動済み"
    else
        warn "Screen Sharing をCLIで有効化できませんでした"
        info "手動で有効化してください: システム設定 → 一般 → 共有 → 画面共有 → オン"
        wait_user
    fi

    info "VNCパスワードアクセスは無効にしてください（Tailscale経由のみ使用）"
    info "確認: システム設定 → 一般 → 共有 → 画面共有 → (i) ボタン"
}

setup_ssh() {
    step "1.6 リモートログイン (SSH)"
    sudo systemsetup -setremotelogin on 2>/dev/null || {
        sudo launchctl enable system/com.openssh.sshd 2>/dev/null || true
        sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    }
    local status
    status=$(sudo systemsetup -getremotelogin 2>&1 || true)
    if echo "$status" | grep -qi "on"; then
        success "SSH有効化"
    else
        warn "SSH の状態を確認してください: システム設定 → 一般 → 共有 → リモートログイン"
    fi
}

# ============================================================
# Phase 2: Tailscale
# ============================================================
setup_tailscale_install() {
    step "2.1 Tailscaleインストール"
    if command -v tailscale &>/dev/null; then
        info "Tailscale はインストール済み"
    else
        brew install tailscale
        success "Tailscale インストール完了"
    fi
}

setup_tailscale_daemon() {
    step "2.2 Tailscale システムデーモン起動"
    sudo brew services start tailscale 2>/dev/null || info "Tailscale サービスは既に起動中の可能性があります"
    success "Tailscale デーモン起動"
}

setup_tailscale_auth() {
    step "2.3 Tailscale認証"
    info "ブラウザでTailscale認証を完了してください..."
    sudo tailscale up
    success "Tailscale 認証完了"
}

setup_tailscale_verify() {
    step "2.4 Tailscale接続確認"
    tailscale status
    success "Tailscale 接続確認OK"
    info "再起動テスト: Mac Miniを再起動し、ログイン画面の状態で別デバイスから 'tailscale status' を確認してください"
}

# ============================================================
# Phase 3: claw アカウント作成 & ツール
# ============================================================
setup_claw_account() {
    step "3.1 'claw' 標準アカウント作成"
    if id "claw" &>/dev/null; then
        info "ユーザー 'claw' は既に存在します"
        if dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -qw claw; then
            error "'claw' が admin グループに所属しています。セキュリティリスクです。"
        fi
        success "'claw' は標準（非管理者）アカウント"
    else
        local claw_password claw_password_confirm
        while true; do
            read -rsp "'claw' アカウントのパスワードを入力: " claw_password
            echo
            read -rsp "パスワード確認: " claw_password_confirm
            echo
            [[ "$claw_password" == "$claw_password_confirm" ]] && break
            warn "パスワードが一致しません。もう一度入力してください。"
        done
        sudo sysadminctl -addUser claw -fullName "OpenClaw" -password "$claw_password"
        success "'claw' アカウント作成完了"
    fi

    step "3.2 claw ホームディレクトリ保護"
    sudo chmod 700 /Users/claw
    success "/Users/claw → mode 700"

    step "3.3 Screen Sharing アクセス設定"
    sudo dseditgroup -o create -q com.apple.access_screensharing 2>/dev/null || true
    sudo dseditgroup -o edit -a claw -t user com.apple.access_screensharing 2>/dev/null || true
    success "Screen Sharing アクセス: claw を許可"
}

setup_google_drive() {
    step "3.4 Google Drive for Desktop インストール"
    if [[ -d "/Applications/Google Drive.app" ]]; then
        info "Google Drive for Desktop はインストール済み"
    else
        brew install --cask google-drive
        success "Google Drive for Desktop インストール完了"
    fi
    info "Google Driveのサインインとミラーリング設定は claw アカウントで行います (02-claw-user-setup.sh)"
}

# ============================================================
# Phase 7: Tailscale Serve
# ============================================================
setup_tailscale_serve() {
    step "7. Tailscale Serve 設定"
    warn "tailscale funnel は絶対に使用しないでください（パブリック公開されます）"
    sudo tailscale serve --bg http://127.0.0.1:18789
    success "Tailscale Serve 設定完了"

    local hostname
    hostname=$(tailscale status --self --json 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null \
        || echo "<mac-mini-hostname>.your-tailnet.ts.net")
    info "OpenClawアクセスURL: https://${hostname}"
    info "OpenClawのインストール後にControl UIが表示されます"
}

# ============================================================
# Main
# ============================================================
main() {
    echo -e "${BOLD}OpenClaw Gateway - macOS Admin Setup${NC}"
    echo -e "${BOLD}=====================================${NC}"
    echo
    preflight
    echo
    info "このスクリプトは以下を実行します:"
    info "  1. macOSセキュリティ設定 (ファイアウォール, スリープ防止, 自動ログイン, 共有)"
    info "  2. Tailscaleのインストール・設定"
    info "  3. 'claw' 標準アカウント作成"
    info "  4. Google Drive for Desktop インストール"
    info "  5. Tailscale Serve 設定"
    echo
    confirm "実行しますか?" || { info "中止しました"; exit 0; }

    setup_firewall
    setup_home_dir
    setup_sleep
    setup_autologin
    setup_screen_sharing
    setup_ssh

    setup_tailscale_install
    setup_tailscale_daemon
    setup_tailscale_auth
    setup_tailscale_verify

    setup_claw_account
    setup_google_drive

    setup_tailscale_serve

    echo
    step "Admin Setup 完了!"
    info "次のステップ:"
    info "  1. Screen Sharing で 'claw' アカウントにログイン"
    info "  2. claw アカウントで 02-claw-user-setup.sh を実行"
    info "  3. claw アカウントで 03-openclaw-setup.sh を実行"
}

main "$@"
