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

# 実行ユーザー (admin) — Ollama LaunchDaemon の UserName / HOME に流し込む
ADMIN_USER=""
ADMIN_HOME=""

# ============================================================
# Project .env loader
# OLLAMA_MODEL を読み込む。未設定時は setup_ollama_pull で既定値を適用。
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
    [[ "$(id -u)" -ne 0 ]] || error "rootではなく管理者ユーザーで実行してください"
    dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -qw "$(whoami)" \
        || error "現在のユーザー '$(whoami)' は管理者ではありません"
    command -v brew &>/dev/null || error "Homebrewが必要です: https://brew.sh"
    ADMIN_USER="$(whoami)"
    ADMIN_HOME="$HOME"
    success "Pre-flight OK (admin: ${ADMIN_USER}, macOS $(sw_vers -productVersion))"
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
# Phase 4: claw アカウント作成 & ツール
# ============================================================
setup_claw_account() {
    step "4.1 'claw' 標準アカウント作成"
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

    step "4.2 claw ホームディレクトリ保護"
    sudo chmod 700 /Users/claw
    success "/Users/claw → mode 700"

    step "4.3 Screen Sharing アクセス設定"
    sudo dseditgroup -o create -q com.apple.access_screensharing 2>/dev/null || true
    sudo dseditgroup -o edit -a claw -t user com.apple.access_screensharing 2>/dev/null || true
    success "Screen Sharing アクセス: claw を許可"
}

setup_google_drive() {
    step "4.4 Google Drive for Desktop インストール"
    if [[ -d "/Applications/Google Drive.app" ]]; then
        info "Google Drive for Desktop はインストール済み"
    else
        brew install --cask google-drive
        success "Google Drive for Desktop インストール完了"
    fi
    info "Google Driveのサインインとミラーリング設定は claw アカウントで行います (02-claw-user-setup.sh)"
}

# ============================================================
# Phase 3: Ollama (admin ユーザーとして常駐するシステム LaunchDaemon)
# ============================================================
setup_ollama_install() {
    step "3.1 Ollama インストール"
    if command -v ollama &>/dev/null; then
        info "Ollama はインストール済み ($(ollama --version 2>&1 | head -1))"
    else
        brew install ollama
        success "Ollama インストール完了"
    fi
}

setup_ollama_daemon() {
    step "3.2 Ollama LaunchDaemon (UserName=${ADMIN_USER}, 永続常駐)"
    [[ -n "$ADMIN_USER" && -n "$ADMIN_HOME" ]] || error "ADMIN_USER/ADMIN_HOME 未設定。preflight が走っていません"

    # ログは admin の ~/Library/Logs に置く。/var/log は root しか書けないため、
    # UserName=admin で走る daemon が StandardOut/ErrorPath を開けず即死するのを避ける。
    local log_dir="${ADMIN_HOME}/Library/Logs"
    local stdout_log="${log_dir}/ollama.log"
    local stderr_log="${log_dir}/ollama.error.log"
    mkdir -p "$log_dir"

    # 旧構成（root として走っていた頃）の残骸を片付ける。今後は新しいログパスを使う。
    if [[ -e /var/log/ollama.log || -e /var/log/ollama.error.log ]]; then
        sudo rm -f /var/log/ollama.log /var/log/ollama.error.log
        info "旧 /var/log/ollama.{log,error.log} (root 所有) を削除"
    fi

    local plist=/Library/LaunchDaemons/io.shoya.ollama.plist
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.shoya.ollama</string>
    <key>UserName</key>
    <string>${ADMIN_USER}</string>
    <key>GroupName</key>
    <string>staff</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/ollama</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${stdout_log}</string>
    <key>StandardErrorPath</key>
    <string>${stderr_log}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${ADMIN_HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>-1</string>
        <key>OLLAMA_MAX_LOADED_MODELS</key>
        <string>3</string>
    </dict>
</dict>
</plist>
PLIST
    sudo install -m 0644 -o root -g wheel "$tmp" "$plist"
    rm -f "$tmp"

    # 順序が重要: (load 済みなら bootout) → enable → bootstrap。
    # disabled override が残っていると bootstrap が "Input/output error" (EIO, errno 5) で失敗するため、
    # bootstrap の前に enable で disabled 状態をクリアしておく。
    # bootout は未 load 時に macOS バージョン依存で "No such process" / "Could not find" を吐くので、
    # print で存在確認してから bootout する（メッセージのブレに依存しない）。
    if sudo launchctl print system/io.shoya.ollama &>/dev/null; then
        info "既存の system/io.shoya.ollama を bootout"
        sudo launchctl bootout system/io.shoya.ollama
        # bootout は非同期。次の bootstrap までに完全に unload させるため軽く待つ。
        sleep 1
    fi
    sudo launchctl enable system/io.shoya.ollama
    sudo launchctl bootstrap system "$plist"
    success "Ollama LaunchDaemon 配置 + 起動 (${ADMIN_USER} として serve、モデル置き場は ${ADMIN_HOME}/.ollama)"

    # Spotlight + Time Machine から ${ADMIN_HOME}/.ollama を除外（数十GB の blob インデックス防止）
    # mdutil はボリューム単位なので、ディレクトリ単位の除外には .metadata_never_index を使う
    mkdir -p "${ADMIN_HOME}/.ollama"
    touch "${ADMIN_HOME}/.ollama/.metadata_never_index"
    tmutil addexclusion "${ADMIN_HOME}/.ollama" >/dev/null 2>&1 || true
    success "Spotlight + Time Machine から ${ADMIN_HOME}/.ollama を除外"
}

# ============================================================
# Phase 3.3: Ollama モデル pull
# daemon は admin として走り、モデル本体は ${ADMIN_HOME}/.ollama に保存される。
# pull 自体は HTTP API 経由なのでどのユーザーから呼んでも結果は同じだが、
# 所有関係を揃えて 01 (admin) で実行する。OLLAMA_MODEL（未指定時は qwen3.6:35b-a3b）を pull する。
# `ollama pull` は冪等で、既に最新ならすぐに完了する。
# ============================================================
setup_ollama_pull() {
    step "3.3 Ollama モデル pull"
    local model="${OLLAMA_MODEL:-qwen3.6:35b-a3b}"
    local ollama_bin="/opt/homebrew/bin/ollama"

    [[ -x "$ollama_bin" ]] || error "ollama CLI が見つかりません: $ollama_bin"

    # Daemon 起動待ち（bootstrap 直後で listening まで数秒かかる）
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
# Phase 3.4: Ollama モデル preload LaunchDaemon
# 起動時に OLLAMA_MODEL を一度だけ /api/generate (empty prompt) で
# メモリにロードし、初回 Telegram メッセージのコールドロード待ちを排除する。
# OLLAMA_KEEP_ALIVE=-1 (io.shoya.ollama 側) によりロード後は永続常駐する。
# ============================================================
setup_ollama_preload() {
    step "3.4 Ollama preload LaunchDaemon (起動時に OLLAMA_MODEL をメモリへロード)"
    [[ -n "$ADMIN_USER" && -n "$ADMIN_HOME" ]] || error "ADMIN_USER/ADMIN_HOME 未設定。preflight が走っていません"

    local model="${OLLAMA_MODEL:-qwen3.6:35b-a3b}"
    local log_dir="${ADMIN_HOME}/Library/Logs"
    local stdout_log="${log_dir}/ollama-preload.log"
    local stderr_log="${log_dir}/ollama-preload.error.log"
    mkdir -p "$log_dir"

    local plist=/Library/LaunchDaemons/io.shoya.ollama-preload.plist
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.shoya.ollama-preload</string>
    <key>UserName</key>
    <string>${ADMIN_USER}</string>
    <key>GroupName</key>
    <string>staff</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>for i in \$(seq 1 60); do curl -sf http://127.0.0.1:11434/api/tags &gt;/dev/null 2&gt;&amp;1 &amp;&amp; break; sleep 2; done; curl -sf -X POST http://127.0.0.1:11434/api/generate -H 'Content-Type: application/json' -d '{"model":"${model}","prompt":"","keep_alive":-1}' &gt;/dev/null</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${stdout_log}</string>
    <key>StandardErrorPath</key>
    <string>${stderr_log}</string>
</dict>
</plist>
PLIST
    sudo install -m 0644 -o root -g wheel "$tmp" "$plist"
    rm -f "$tmp"

    # 順序: (load 済みなら bootout) → enable → bootstrap（io.shoya.ollama と同じ EIO 対策）
    if sudo launchctl print system/io.shoya.ollama-preload &>/dev/null; then
        info "既存の system/io.shoya.ollama-preload を bootout"
        sudo launchctl bootout system/io.shoya.ollama-preload
        sleep 1
    fi
    sudo launchctl enable system/io.shoya.ollama-preload
    sudo launchctl bootstrap system "$plist"
    success "Ollama preload LaunchDaemon 配置 + 起動 (model=${model})"
}

# ============================================================
# Phase 5: Tailscale Serve
# ============================================================
setup_tailscale_serve() {
    step "5. Tailscale Serve 設定"
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
    load_project_env
    echo
    info "このスクリプトは以下を実行します:"
    info "  1. macOSセキュリティ設定 (ファイアウォール, スリープ防止, 自動ログイン, 共有)"
    info "  2. Tailscaleのインストール・設定"
    info "  3. Ollama インストール + LaunchDaemon (UserName=${ADMIN_USER}) + モデル pull + 起動時 preload"
    info "  4. 'claw' 標準アカウント作成 + Google Drive for Desktop インストール"
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

    setup_ollama_install
    setup_ollama_daemon
    setup_ollama_pull
    setup_ollama_preload

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
