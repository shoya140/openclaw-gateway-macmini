#!/bin/bash
set -euo pipefail

source "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/lib.sh"

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
WORKSPACE_BASENAME="openclaw-workspace"
LAUNCHAGENT_LABEL="ai.openclaw.gateway"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"

# ============================================================
# Pre-flight
# ============================================================
preflight() {
    [[ "$(uname)" == "Darwin" ]] || error "macOS 専用スクリプトです"
    [[ "$(whoami)" == "claw" ]] || error "このスクリプトは 'claw' ユーザーで実行してください (現在: $(whoami))"

    export PATH="$HOME/.local/bin:$PATH"
    eval "$(~/.local/bin/mise activate bash 2>/dev/null)" || true

    command -v node &>/dev/null || error "Node.js が見つかりません。先に 02-claw-user-setup.sh を実行してください"
    command -v npm &>/dev/null || error "npm が見つかりません。先に 02-claw-user-setup.sh を実行してください"
    success "Pre-flight OK (user: claw, node: $(node --version))"
}

# ============================================================
# Workspace path validation
# パスは '...openclaw-workspace' で終わる実ディレクトリであることを保証する。
# Google Drive ルートが誤って渡された場合の事故 (中身が散布) を防ぐガード。
# ============================================================
validate_workspace_path() {
    local path="$1" context="${2:-workspace}"
    [[ -n "$path" ]] || error "${context}: パスが空です"
    local base
    base=$(basename "$path")
    [[ "$base" == "$WORKSPACE_BASENAME" ]] \
        || error "${context}: パスは '${WORKSPACE_BASENAME}' で終わる必要があります (実際: $path)"
    [[ -d "$path" ]] || error "${context}: ディレクトリが存在しません: $path"
}

# ============================================================
# 既存 Gateway 停止
# 二重 polling 防止のため、LaunchAgent と CLI 両方経由で確実に停止する
# ============================================================
stop_existing_gateway() {
    if [[ -f "$LAUNCHAGENT_PLIST" ]]; then
        info "既存 LaunchAgent を bootout..."
        launchctl bootout "gui/$(id -u)/${LAUNCHAGENT_LABEL}" 2>/dev/null || true
    fi
    info "openclaw gateway stop (フォールバック)..."
    openclaw gateway stop 2>/dev/null || true
    sleep 1
}

# ============================================================
# 既存 ~/.openclaw を snapshot にバックアップして削除
# Google Drive 上の workspace 中身は移動しない (個人 PC との同期を維持)
# ============================================================
backup_existing() {
    [[ -d "$OPENCLAW_DIR" ]] || { info "既存 ~/.openclaw なし。バックアップスキップ"; return; }

    step "既存 ~/.openclaw を snapshot にバックアップ"
    info "  - ~/.openclaw → snapshot にコピー (cp -a)"
    info "  - workspace 中身 → snapshot/workspace に mv (実体ファイル化、Google Drive 上は空になる)"
    info "  - 個人 PC 側の Google Drive にも空状態が反映されます (04 で書き戻し可能)"

    stop_existing_gateway

    local workspace_real=""
    if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real=$(readlink "$OPENCLAW_DIR/workspace")
    elif [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real="$OPENCLAW_DIR/workspace"
    fi

    local snapshot_dir="$HOME/.openclaw-snapshot-$(date +%Y%m%d-%H%M%S)"
    cp -a "$OPENCLAW_DIR" "$snapshot_dir"
    success "~/.openclaw → $snapshot_dir に退避"

    if [[ -n "$workspace_real" && -d "$workspace_real" ]]; then
        validate_workspace_path "$workspace_real" "backup_existing"
        rm -f "$snapshot_dir/workspace" 2>/dev/null || true
        mkdir -p "$snapshot_dir/workspace"

        shopt -s dotglob nullglob
        local entries=("$workspace_real"/*)
        shopt -u dotglob nullglob

        if [[ ${#entries[@]} -gt 0 ]]; then
            mv "${entries[@]}" "$snapshot_dir/workspace/"
            success "Workspace の中身 ${#entries[@]} 項目を $snapshot_dir/workspace/ に退避 (実体ファイル)"
            info "Google Drive 上の workspace は空になりました (個人 PC にも数十秒〜数分で反映)"
        else
            rmdir "$snapshot_dir/workspace" 2>/dev/null || true
            info "Workspace は空でした"
        fi
    else
        info "workspace symlink/ディレクトリが見つからないため workspace の退避をスキップ"
    fi

    info "LaunchAgent plist 削除..."
    rm -f "$LAUNCHAGENT_PLIST"

    info "OpenClaw アンインストール..."
    npm uninstall -g openclaw 2>/dev/null || true

    info "~/.openclaw 削除..."
    rm -rf "$OPENCLAW_DIR"

    success "バックアップ + 初期化完了 → snapshot: $snapshot_dir"
    echo
}

# ============================================================
# Install OpenClaw
# ============================================================
install_openclaw() {
    step "OpenClaw インストール"
    npm install -g openclaw@latest
    success "OpenClaw $(openclaw --version 2>/dev/null || echo '(version unknown)') インストール完了"
}

# ============================================================
# Telegram 拡張 peer deps の動的判定 + install
# 上流 packaging bug の workaround。最新 openclaw が grammy を含めて配布する
# ようになっていれば skip する。
# ============================================================
install_telegram_peer_deps() {
    step "Telegram 拡張 peer deps の状態確認"

    local openclaw_root="$(npm root -g)/openclaw"
    local pkg_json="$openclaw_root/package.json"

    if [[ ! -f "$pkg_json" ]]; then
        warn "openclaw の package.json が見つかりません: $pkg_json"
        return
    fi

    local needed=("grammy" "@grammyjs/runner" "@grammyjs/transformer-throttler")
    local missing=()
    for dep in "${needed[@]}"; do
        if ! node -e 'const p=require(process.argv[1]); const d={...(p.dependencies||{}),...(p.peerDependencies||{}),...(p.optionalDependencies||{})}; if(!d[process.argv[2]]) process.exit(1)' "$pkg_json" "$dep" 2>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "openclaw に Telegram 拡張依存が含まれているため peer deps install は不要"
        return
    fi

    info "openclaw に未宣言の依存があります: ${missing[*]}"
    info "上流 packaging bug の workaround として ${openclaw_root} に install します"

    local args=("grammy@^1.42.0" "@grammyjs/runner@^2.0.3" "@grammyjs/transformer-throttler@^1.2.1")
    if (cd "$openclaw_root" && npm install "${args[@]}" --no-save --omit=dev --legacy-peer-deps); then
        success "Telegram 拡張 peer deps install 完了"
    else
        warn "Telegram 拡張 peer deps の install に失敗 (手動で実行してください)"
        warn "  cd $openclaw_root && npm install ${args[*]} --no-save --omit=dev --legacy-peer-deps"
    fi
}

# ============================================================
# Telegram Bot setup
# token は credentials/telegram/{main,personal}.token に書き込む
# (.env ではなく tokenFile 経由)
# ============================================================
setup_telegram() {
    step "Telegram Bot 設定 (main + personal)"

    local main_token="${TELEGRAM_MAIN_BOT_TOKEN:-}"
    local personal_token="${TELEGRAM_PERSONAL_BOT_TOKEN:-}"
    local user_id_env="${TELEGRAM_USER_ID:-}"

    if [[ -z "$main_token" || -z "$personal_token" || -z "$user_id_env" ]]; then
        info "BotFather で 2 つの Bot を作成し、Token を取得してください (main / personal)"
        info "User ID は @userinfobot で確認できます"
        echo
    fi

    if [[ -n "$main_token" ]]; then
        info "TELEGRAM_MAIN_BOT_TOKEN を環境変数から取得"
    else
        main_token=$(prompt_secret "Telegram Bot Token [main]")
        [[ -n "$main_token" ]] || error "main の Bot Token は必須です"
    fi

    if [[ -n "$personal_token" ]]; then
        info "TELEGRAM_PERSONAL_BOT_TOKEN を環境変数から取得"
    else
        personal_token=$(prompt_secret "Telegram Bot Token [personal]")
        [[ -n "$personal_token" ]] || error "personal の Bot Token は必須です"
    fi

    if [[ -n "$user_id_env" ]]; then
        info "TELEGRAM_USER_ID を環境変数から取得 ($user_id_env)"
        TELEGRAM_USER_ID="$user_id_env"
        [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || error "TELEGRAM_USER_ID は数値で指定してください"
    else
        TELEGRAM_USER_ID=$(prompt_value "あなたの Telegram User ID (数値)")
        [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || error "User ID は数値で入力してください"
    fi

    local cred_dir="$OPENCLAW_DIR/credentials/telegram"
    mkdir -p "$cred_dir"
    chmod 700 "$OPENCLAW_DIR" "$OPENCLAW_DIR/credentials" "$cred_dir"

    printf '%s' "$main_token" > "$cred_dir/main.token"
    chmod 600 "$cred_dir/main.token"
    printf '%s' "$personal_token" > "$cred_dir/personal.token"
    chmod 600 "$cred_dir/personal.token"

    success "Token ファイル生成: $cred_dir/{main,personal}.token (chmod 600)"
}

# ============================================================
# Google Drive workspace 検出 + symlink
# ============================================================
detect_workspace() {
    step "Google Drive ワークスペース検出 + symlink 作成"

    local candidates=()
    local p
    for p in ~/Library/CloudStorage/GoogleDrive-*/My\ Drive/${WORKSPACE_BASENAME} \
             ~/Library/CloudStorage/GoogleDrive-*/.shortcut-targets-by-id/*/${WORKSPACE_BASENAME} \
             ~/Library/CloudStorage/GoogleDrive-*/Shared\ drives/*/${WORKSPACE_BASENAME}; do
        [[ -d "$p" ]] && candidates+=("$p")
    done

    local gdrive_path=""
    if [[ ${#candidates[@]} -eq 1 ]]; then
        gdrive_path="${candidates[0]}"
        info "ワークスペース検出: $gdrive_path"
    elif [[ ${#candidates[@]} -gt 1 ]]; then
        info "複数の候補が見つかりました:"
        printf '  - %s\n' "${candidates[@]}"
        gdrive_path=$(prompt_value "使用するワークスペースのフルパス")
    else
        warn "openclaw-workspace フォルダが見つかりません"
        info "Google Drive で openclaw-workspace を共有・ミラーリングしてから再実行してください"
        gdrive_path=$(prompt_value "ワークスペースのフルパス")
    fi

    validate_workspace_path "$gdrive_path" "detect_workspace"

    local symlink_path="$OPENCLAW_DIR/workspace"
    mkdir -p "$OPENCLAW_DIR"
    rm -rf "$symlink_path" 2>/dev/null || true
    ln -s "$gdrive_path" "$symlink_path"

    WORKSPACE_PATH="$gdrive_path"
    success "シンボリックリンク: $symlink_path → $gdrive_path"
}

# ============================================================
# LM Studio v0 native API (http://127.0.0.1:1234/api/v0/models) からロード可能な
# LLM/VLM 一覧を取得し、各モデルに max_context_length を付与した OpenClaw 形式の
# models[] JSON 配列を生成する。これにより agents.list[].personal.model を
# lmstudio/<modelKey> に書き換えるだけでモデル切り替えが完結し contextWindow も
# 自動追従する。API 失敗時は ${LMSTUDIO_MODEL} 1 個だけのフォールバックを返す。
# ============================================================
build_lmstudio_models_json() {
    local raw fallback_model
    fallback_model="${LMSTUDIO_MODEL:-unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit}"
    raw=$(curl -sf --max-time 5 http://127.0.0.1:1234/api/v0/models 2>/dev/null) || raw=""

    if [[ -n "$raw" ]]; then
        local result
        result=$(printf '%s' "$raw" | python3 -c '
import json, sys
data = json.load(sys.stdin)
items = []
for m in data.get("data", []):
    if m.get("type") not in ("llm", "vlm", "vision-llm"):
        continue
    entry = {"id": m["id"], "name": m["id"]}
    ctx = m.get("max_context_length")
    if isinstance(ctx, int) and ctx > 0:
        entry["contextWindow"] = ctx
    items.append(entry)
if not items:
    sys.exit(1)
print(json.dumps(items, indent=10, ensure_ascii=False))
' 2>/dev/null) && [[ -n "$result" ]] && {
            info "LM Studio v0 API から $(printf '%s' "$result" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') 個の LLM/VLM を取得" >&2
            printf '%s' "$result"
            return 0
        }
    fi

    warn "LM Studio v0 API 取得失敗。${fallback_model} 1 個のみで models[] を構築 (後で openclaw.json を編集して追記してください)" >&2
    cat <<FALLBACK
[
          {
            "id": "${fallback_model}",
            "name": "${fallback_model}"
          }
        ]
FALLBACK
}

# ============================================================
# openclaw.json 生成
# ============================================================
generate_config() {
    step "openclaw.json 生成"

    mkdir -p "$OPENCLAW_DIR"

    local gateway_token
    gateway_token=$(openssl rand -hex 32)

    local ts_hostname tailscale_origin
    ts_hostname=$(tailscale status --self --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null) || true
    if [[ -n "$ts_hostname" ]]; then
        tailscale_origin="https://${ts_hostname}"
        info "Tailscale ホスト名検出: ${ts_hostname}"
    else
        warn "Tailscale ホスト名を自動検出できません"
        tailscale_origin=$(prompt_value "Tailscale Serve の URL (例: https://mac-mini.tailnet-name.ts.net)")
    fi

    local lmstudio_model="${LMSTUDIO_MODEL:-unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit}"
    info "personal agent モデル: lmstudio/${lmstudio_model}"

    local lmstudio_models_json
    lmstudio_models_json=$(build_lmstudio_models_json)

    cat > "$OPENCLAW_CONFIG" << CONFIGEOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "trustedProxies": ["127.0.0.1", "::1"],
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
      "defaultAccount": "main",
      "accounts": {
        "main": {
          "tokenFile": "${HOME}/.openclaw/credentials/telegram/main.token",
          "dmPolicy": "allowlist",
          "allowFrom": [${TELEGRAM_USER_ID}],
          "groupPolicy": "allowlist",
          "groupAllowFrom": [${TELEGRAM_USER_ID}]
        },
        "personal": {
          "tokenFile": "${HOME}/.openclaw/credentials/telegram/personal.token",
          "dmPolicy": "allowlist",
          "allowFrom": [${TELEGRAM_USER_ID}],
          "groupPolicy": "allowlist",
          "groupAllowFrom": [${TELEGRAM_USER_ID}]
        }
      },
      "timeoutSeconds": 60,
      "pollingStallThresholdMs": 120000,
      "network": {
        "autoSelectFamily": true,
        "dnsResultOrder": "ipv4first"
      },
      "streaming": {
        "mode": "off",
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
    },
    "loopDetection": {
      "enabled": true,
      "historySize": 20,
      "warningThreshold": 6,
      "criticalThreshold": 12,
      "globalCircuitBreakerThreshold": 18,
      "unknownToolThreshold": 5,
      "detectors": {
        "genericRepeat": true,
        "knownPollNoProgress": true,
        "pingPong": true
      },
      "postCompactionGuard": {
        "windowSize": 2
      }
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
        "primary": "openai-codex/gpt-5.5",
        "fallbacks": ["openai-codex/gpt-5.4-mini"]
      },
      "workspace": "${HOME}/.openclaw/workspace",
      "sandbox": {
        "mode": "off"
      },
      "timeoutSeconds": 1800
    },
    "list": [
      {
        "id": "main",
        "model": {
          "primary": "openai-codex/gpt-5.5",
          "fallbacks": ["openai-codex/gpt-5.4-mini"]
        }
      },
      {
        "id": "personal",
        "model": "lmstudio/${lmstudio_model}",
        "tools": {
          "loopDetection": {
            "enabled": true,
            "warningThreshold": 4,
            "criticalThreshold": 8,
            "globalCircuitBreakerThreshold": 12
          }
        }
      }
    ]
  },
  "models": {
    "providers": {
      "lmstudio": {
        "baseUrl": "http://127.0.0.1:1234/v1",
        "api": "openai-completions",
        "models": ${lmstudio_models_json}
      }
    }
  },
  "bindings": [
    {
      "agentId": "main",
      "match": { "channel": "telegram", "accountId": "main" }
    },
    {
      "agentId": "personal",
      "match": { "channel": "telegram", "accountId": "personal" }
    }
  ],
  "messages": {
    "queue": {
      "mode": "collect"
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "commands": {
    "ownerAllowFrom": ["telegram:${TELEGRAM_USER_ID}"]
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

    success "openclaw.json 生成: $OPENCLAW_CONFIG"
}

# ============================================================
# シークレット (~/.openclaw/.env)
# Telegram token は credentials/telegram/*.token 経由のため .env には書かない
# main agent は ChatGPT Pro Codex サブスク (openai-codex auth profile) で動かすため
# OpenAI API key は .env に書かない (OAuth credential は OpenClaw が auth store で管理)
# LMSTUDIO_API_KEY は marker 値 ("lm-studio") をハードコード
# 後方互換: ANTHROPIC_API_KEY が設定されていれば書き込む (Anthropic に戻す場合に利用)
# ============================================================
setup_secrets() {
    step "シークレット設定 (~/.openclaw/.env)"

    local env_file="$OPENCLAW_DIR/.env"

    {
        printf 'LMSTUDIO_API_KEY="lm-studio"\n'
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            info "ANTHROPIC_API_KEY を環境変数から取得 (Anthropic に戻す場合の後方互換用)"
            printf 'ANTHROPIC_API_KEY="%s"\n' "${ANTHROPIC_API_KEY}"
        fi
    } > "$env_file"
    chmod 600 "$env_file"

    success "LMSTUDIO_API_KEY を $env_file に書き込み (chmod 600)"
    info "main agent (openai-codex/gpt-5.5) は OAuth ログインが必要です。完了メッセージの手順を参照してください"
}

# ============================================================
# Permissions + Spotlight
# ============================================================
setup_permissions() {
    step "ファイルパーミッション設定"
    chmod 700 "$OPENCLAW_DIR"
    chmod 600 "$OPENCLAW_CONFIG"
    find "$OPENCLAW_DIR/credentials" -type f -exec chmod 600 {} \; 2>/dev/null || true
    success "~/.openclaw → 700, openclaw.json → 600"
}

exclude_spotlight() {
    step "Spotlight インデックス除外"
    touch "$OPENCLAW_DIR/.metadata_never_index"
    success "$OPENCLAW_DIR を Spotlight 除外"
    if [[ -d "${WORKSPACE_PATH:-}" ]]; then
        touch "${WORKSPACE_PATH}/.metadata_never_index" 2>/dev/null \
            && success "${WORKSPACE_PATH} を Spotlight 除外" \
            || info "ワークスペースの除外はスキップ (権限なし)"
    fi
}

# ============================================================
# LaunchAgent 登録 + OPENCLAW_NO_RESPAWN 注入
# OPENCLAW_NO_RESPAWN=1: config 変更時の SIGUSR1 in-process restart を抑制
# (二重 polling の原因の一つ)
# ============================================================
install_launchagent() {
    step "Gateway LaunchAgent 登録 + OPENCLAW_NO_RESPAWN 注入"
    openclaw gateway install --force
    success "LaunchAgent 登録: $LAUNCHAGENT_PLIST"

    [[ -f "$LAUNCHAGENT_PLIST" ]] || error "LaunchAgent plist が生成されていません: $LAUNCHAGENT_PLIST"

    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:OPENCLAW_NO_RESPAWN" "$LAUNCHAGENT_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$LAUNCHAGENT_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OPENCLAW_NO_RESPAWN string 1" "$LAUNCHAGENT_PLIST"
    success "OPENCLAW_NO_RESPAWN=1 を plist に注入"
}

# ============================================================
# Gateway 起動
# bootout → bootstrap → kickstart の順で確実に新環境変数で再ロード
# ============================================================
start_gateway() {
    step "Gateway 起動 (launchctl kickstart)"

    local uid
    uid=$(id -u)

    launchctl bootout "gui/${uid}/${LAUNCHAGENT_LABEL}" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/${uid}" "$LAUNCHAGENT_PLIST"
    launchctl kickstart -k "gui/${uid}/${LAUNCHAGENT_LABEL}"
    success "LaunchAgent 起動シグナル送信"

    info "起動を待機 (最大 30 秒)..."
    local i
    for i in $(seq 1 15); do
        if openclaw gateway status &>/dev/null; then
            success "Gateway 起動確認"
            return
        fi
        sleep 2
    done
    warn "Gateway のヘルスチェックがタイムアウトしました (ログ確認: openclaw logs --follow)"
}

# ============================================================
# 検証 (read-only)
# doctor --fix は呼ばない (config 書き換えを防ぐため)
# ============================================================
verify_install() {
    step "インストール検証 (read-only)"
    openclaw doctor || warn "doctor で警告あり (上記参照、必要に応じて 03 を編集して再実行)"
    echo
    openclaw security audit || true
    echo
    openclaw status || true
}

# ============================================================
# Doctor / audit が生成した bak ファイル削除
# read-only でも稀に書き換えが起こるため最後に掃除する
# ============================================================
cleanup_config_backups() {
    step "openclaw.json.{bak,bak.*,last-good} を削除"
    local removed=0
    local f
    for f in "$OPENCLAW_CONFIG".bak "$OPENCLAW_CONFIG".bak.* "$OPENCLAW_CONFIG".last-good; do
        [[ -f "$f" ]] && { rm -f "$f"; removed=$((removed + 1)); }
    done
    if [[ $removed -gt 0 ]]; then
        success "${removed} 個の bak ファイルを削除"
    else
        info "削除対象の bak ファイルなし"
    fi
}

# ============================================================
# Usage
# ============================================================
usage() {
    cat <<USAGE
Usage: $0 [--help]

OpenClaw Gateway を claw アカウントにセットアップします。

このスクリプトは以下を実行します:
  - 既存の ~/.openclaw を ~/.openclaw-snapshot-<ts>/ に cp -a でバックアップ
    (Google Drive 上の workspace 中身は移動しません)
  - OpenClaw を npm install -g
  - Telegram 拡張 peer deps が openclaw に未宣言なら手動 install (動的判定)
  - Telegram Bot Token を ~/.openclaw/credentials/telegram/{main,personal}.token に書き込み
  - Google Drive 上の openclaw-workspace を検出し ~/.openclaw/workspace に symlink
  - openclaw.json を生成 (Telegram 2 アカウント, main→OpenAI Codex / personal→LM Studio)
  - ~/.openclaw/.env に LMSTUDIO_API_KEY を書き込み (ANTHROPIC_API_KEY は環境にあれば後方互換で追記)
  - パーミッション設定 + Spotlight 除外
  - Gateway LaunchAgent 登録 + OPENCLAW_NO_RESPAWN=1 注入 + 起動
  - openclaw doctor / security audit / status で検証 (read-only)
  - Doctor が生成した bak ファイルを削除

環境変数 / .env:
  プロジェクト直下の .env を読み込みます。下記キーがセットされていれば対話入力を省略します。
    TELEGRAM_MAIN_BOT_TOKEN      main Bot Token (必須)
    TELEGRAM_PERSONAL_BOT_TOKEN  personal Bot Token (必須)
    TELEGRAM_USER_ID             Telegram User ID 数値 (必須)
    LMSTUDIO_MODEL               personal agent モデル (省略可、既定: unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit)
    ANTHROPIC_API_KEY            (省略可) Anthropic に戻す場合の後方互換用。設定すれば .env に書き込みます

main agent (openai-codex/gpt-5.5) は ChatGPT Pro サブスクの OAuth 認証を使用するため、03 完了後に
device-code フローでログインしてください:
    openclaw models auth login --provider openai-codex --method device-code
USAGE
}

# ============================================================
# Main
# ============================================================
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1\nRun '$0 --help' for usage." ;;
        esac
    done

    echo -e "${BOLD}OpenClaw Gateway - OpenClaw Setup${NC}"
    echo -e "${BOLD}==================================${NC}"
    echo

    preflight
    load_project_env
    backup_existing
    install_openclaw
    install_telegram_peer_deps
    setup_telegram
    detect_workspace
    generate_config
    setup_secrets
    setup_permissions
    exclude_spotlight
    install_launchagent
    start_gateway
    verify_install
    cleanup_config_backups

    echo
    step "OpenClaw Setup 完了"
    info ""
    info "次の手動作業: main agent (openai-codex/gpt-5.5) の OAuth ログイン (ChatGPT Pro サブスク経由)"
    info "  1. claw ユーザーで以下を実行:"
    info "       openclaw models auth login --provider openai-codex --method device-code"
    info "  2. 表示された URL とユーザーコードを別マシンのブラウザで開く"
    info "  3. ChatGPT Pro アカウントでサインイン → コードを承認"
    info "  4. ログイン完了後、LaunchAgent を再ロード:"
    info "       launchctl kickstart -k gui/$(id -u)/${LAUNCHAGENT_LABEL}"
    info ""
    info "Telegram から main / personal の各 Bot に DM を送って応答が返れば完了です。"
    info ""
    info "重要: 二重 polling 防止のため、手動で 'openclaw gateway start/restart' は使わないでください。"
    info "  - 設定変更後の再ロードは: launchctl kickstart -k gui/$(id -u)/${LAUNCHAGENT_LABEL}"
    info "  - もしくは 03 を再実行 (snapshot 経由で確実に再ロード)"
}

main "$@"
