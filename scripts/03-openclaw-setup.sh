#!/bin/bash
set -euo pipefail

source "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/lib.sh"

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
WORKSPACE_BASENAME="openclaw-workspace"

# ============================================================
# Workspace path validation
# パスは必ず .../openclaw-workspace で終わること、かつ実ディレクトリ
# (symlink 経由含む) であることを保証する。
# 過去に detect_workspace のフォールバック入力で My Drive ルートが
# 受け入れられ、--recover 時に Google Drive のトップディレクトリへ
# workspace の中身が散布される事故を防ぐためのガード。
# ============================================================
validate_workspace_path() {
    local path="$1" context="${2:-workspace}"
    [[ -n "$path" ]] || error "${context}: パスが空です"
    local base
    base=$(basename "$path")
    [[ "$base" == "$WORKSPACE_BASENAME" ]] \
        || error "${context}: パスは '${WORKSPACE_BASENAME}' で終わる必要があります (実際: $path)"
    [[ -d "$path" ]] \
        || error "${context}: ディレクトリが存在しません: $path"
}

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
    step "既存インストールをバックアップして初期化"
    info "既存の ~/.openclaw + Google Drive 上の workspace 内容を ~/.openclaw-snapshot-<ts>/ に退避します"
    info "  - ~/.openclaw → snapshot にコピー (cp -a)"
    info "  - workspace 中身 → snapshot/workspace に mv（実体ファイル。Google Drive からは消える）"
    info "  - personal PC 側の Google Drive にも空状態が反映されます"

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
        validate_workspace_path "$workspace_real" "backup_and_reset"
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
# Recover: snapshot から workspace + cron を復元
# 引数なし: 最新 snapshot ($HOME/.openclaw-snapshot-*) を自動選択
# 引数あり: 指定された snapshot ディレクトリを使用
# ============================================================
do_recover() {
    local snapshot_arg="${1:-}"
    local snapshot_dir

    if [[ -n "$snapshot_arg" ]]; then
        step "Recover: 指定 snapshot から workspace + cron を復元"
        snapshot_dir="$snapshot_arg"
        if [[ ! -d "$snapshot_dir" ]]; then
            error "指定された snapshot ディレクトリが存在しません: $snapshot_dir"
        fi
        info "Snapshot (指定): $snapshot_dir"
    else
        step "Recover: 最新 snapshot から workspace + cron を復元"
        snapshot_dir=$(find_latest_snapshot)
        if [[ -z "$snapshot_dir" || ! -d "$snapshot_dir" ]]; then
            warn "snapshot が見つかりません ($HOME/.openclaw-snapshot-*)。--recover をスキップします"
            return
        fi
        info "Snapshot (最新): $snapshot_dir"
    fi

    if [[ -d "$snapshot_dir/workspace" ]]; then
        local workspace_real=""
        if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
            workspace_real=$(readlink "$OPENCLAW_DIR/workspace")
        elif [[ -d "$OPENCLAW_DIR/workspace" ]]; then
            workspace_real="$OPENCLAW_DIR/workspace"
        fi

        if [[ -n "$workspace_real" && -d "$workspace_real" ]]; then
            validate_workspace_path "$workspace_real" "do_recover"
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
    step "OpenClaw インストール"

    if command -v openclaw &>/dev/null; then
        info "OpenClaw はインストール済み ($(openclaw --version 2>/dev/null || echo 'version unknown')). 再インストールします"
    fi

    npm install -g openclaw@latest
    success "OpenClaw インストール完了"
}

# ============================================================
# Telegram 拡張 peer deps の手動 install (上流 packaging bug の workaround)
# OpenClaw の dist/ は grammy / @grammyjs/runner / @grammyjs/transformer-throttler
# を runtime で require するが package.json に宣言されていないため、
# `npm install -g openclaw@latest` のたびに消える。
# 関連 issue: openclaw/openclaw#59867, #60263, #60309, #62425, #63103, #70615
# 上流が修正したらこの関数は不要になる。
# ============================================================
install_telegram_peer_deps() {
    step "Telegram 拡張 peer deps install (上流 packaging bug の workaround)"

    local openclaw_root
    openclaw_root="$(npm root -g)/openclaw"
    if [[ ! -d "$openclaw_root" ]]; then
        warn "OpenClaw グローバル install ディレクトリが見つかりません: $openclaw_root"
        return
    fi

    local deps=(
        "grammy@^1.42.0"
        "@grammyjs/runner@^2.0.3"
        "@grammyjs/transformer-throttler@^1.2.1"
    )

    info "install 先: $openclaw_root"
    info "対象: ${deps[*]}"

    if (cd "$openclaw_root" && npm install "${deps[@]}" --no-save --omit=dev --legacy-peer-deps); then
        success "Telegram 拡張 peer deps install 完了"
    else
        warn "Telegram 拡張 peer deps の install に失敗しました（手動で実行してください）"
        warn "  cd $openclaw_root && npm install ${deps[*]} --no-save --omit=dev --legacy-peer-deps"
    fi
}

# ============================================================
# Telegram Bot Setup
# ============================================================
setup_telegram() {
    step "Telegram Bot 設定 (official + personal の 2 アカウント)"

    local official_token="${TELEGRAM_OFFICIAL_BOT_TOKEN:-}"
    local personal_token="${TELEGRAM_PERSONAL_BOT_TOKEN:-}"
    local user_id_env="${TELEGRAM_USER_ID:-}"
    local need_prompt=false
    [[ -z "$official_token" || -z "$personal_token" || -z "$user_id_env" ]] && need_prompt=true

    if $need_prompt; then
        info "BotFather で 2 つの Bot を作成してください（official / personal）"
        info "  1. Telegram で @BotFather を検索してチャットを開く"
        info "  2. /newbot を送信して 2 回繰り返す（Bot 名は任意。例: official 用 / personal 用）"
        info "  3. それぞれの Bot Token をコピー"
        echo
        info "グループで使う場合は BotFather で /setprivacy → Disable も実行してください"
        echo
    fi

    if [[ -n "$official_token" ]]; then
        info "TELEGRAM_OFFICIAL_BOT_TOKEN を環境変数から取得"
    else
        official_token=$(prompt_secret "Telegram Bot Token [official]")
        [[ -n "$official_token" ]] || error "official の Bot Token は必須です"
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
        [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || error "TELEGRAM_USER_ID は数値で指定してください (.env): $TELEGRAM_USER_ID"
    else
        TELEGRAM_USER_ID=$(prompt_value "あなたの Telegram User ID (数値)")
        [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || error "User ID は数値で入力してください"
    fi

    local cred_dir="$OPENCLAW_DIR/credentials/telegram"
    mkdir -p "$cred_dir"
    chmod 700 "$OPENCLAW_DIR" 2>/dev/null || true
    chmod 700 "$OPENCLAW_DIR/credentials" 2>/dev/null || true
    chmod 700 "$cred_dir"

    printf '%s' "$official_token" > "$cred_dir/official.token"
    chmod 600 "$cred_dir/official.token"
    printf '%s' "$personal_token" > "$cred_dir/personal.token"
    chmod 600 "$cred_dir/personal.token"

    success "Token ファイル生成: $cred_dir/{official,personal}.token (chmod 600)"
}

# ============================================================
# Detect Workspace & Create Symlink
# ============================================================
detect_workspace() {
    step "ワークスペースパス検出 + シンボリックリンク作成"

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

    validate_workspace_path "$gdrive_path" "detect_workspace"

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
    step "ワークスペースに AGENTS.md 生成"

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
# Build LM Studio models[] JSON for openclaw.json
# LM Studio v0 native API (http://127.0.0.1:1234/api/v0/models) からロード可能な
# LLM / VLM 一覧を取得し、各モデルに max_context_length を付与した OpenClaw 形式の
# models[] JSON 配列を生成する。これにより claw 側で `agents.list[].model` を書き
# 換えるだけでモデル切り替えが完結し、contextWindow も自動追従する。
# API 失敗時は ${LMSTUDIO_MODEL} 1 個だけのフォールバックを返す。
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
# Generate Config
# ============================================================
generate_config() {
    step "設定ファイル生成"

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

    local lmstudio_model="${LMSTUDIO_MODEL:-unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit}"
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
      "defaultAccount": "official",
      "accounts": {
        "official": {
          "tokenFile": "${HOME}/.openclaw/credentials/telegram/official.token",
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
      "workspace": "${HOME}/.openclaw/workspace",
      "sandbox": {
        "mode": "off"
      }
    },
    "list": [
      {
        "id": "main",
        "model": {
          "primary": "anthropic/claude-opus-4-7",
          "fallbacks": ["anthropic/claude-sonnet-4-6"]
        }
      },
      {
        "id": "official-agent",
        "model": {
          "primary": "anthropic/claude-opus-4-7",
          "fallbacks": ["anthropic/claude-sonnet-4-6"]
        }
      },
      {
        "id": "personal-agent",
        "model": "lmstudio/${lmstudio_model}"
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
      "agentId": "official-agent",
      "match": { "channel": "telegram", "accountId": "official" }
    },
    {
      "agentId": "personal-agent",
      "match": { "channel": "telegram", "accountId": "personal" }
    }
  ],

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

    success "設定ファイル生成: $OPENCLAW_CONFIG"
}

# ============================================================
# Setup Secrets (.env)
# ============================================================
setup_secrets() {
    step "シークレット設定 (~/.openclaw/.env)"

    local env_file="$OPENCLAW_DIR/.env"

    local anthropic_key="${ANTHROPIC_API_KEY:-}"
    if [[ -n "$anthropic_key" ]]; then
        info "ANTHROPIC_API_KEY を環境変数から取得"
    else
        anthropic_key=$(prompt_secret "Anthropic API Key (sk-ant-...)")
        [[ -n "$anthropic_key" ]] || error "Anthropic API Key は必須です"
    fi

    # LM Studio はローカルなので任意の marker。OpenAI 互換 API を使うため
    # provider 側で API key 必須とされた場合に備えて常に値を入れる。
    local lmstudio_key="${LMSTUDIO_API_KEY:-lm-studio}"

    if [[ -f "$env_file" ]]; then
        sed -i '' '/^TELEGRAM_BOT_TOKEN=/d' "$env_file"
        sed -i '' '/^ANTHROPIC_API_KEY=/d' "$env_file"
        sed -i '' '/^OLLAMA_API_KEY=/d' "$env_file"
        sed -i '' '/^LMSTUDIO_API_KEY=/d' "$env_file"
    fi

    cat >> "$env_file" << ENVEOF
ANTHROPIC_API_KEY="${anthropic_key}"
LMSTUDIO_API_KEY="${lmstudio_key}"
ENVEOF
    chmod 600 "$env_file"

    success "ANTHROPIC_API_KEY, LMSTUDIO_API_KEY を $env_file に設定 (Telegram token は credentials/telegram/*.token)"

    info "確認中..."
    openclaw models status || true
}

# ============================================================
# File Permissions
# ============================================================
setup_permissions() {
    step "ファイルパーミッション設定"
    chmod 700 "$OPENCLAW_DIR"
    chmod 600 "$OPENCLAW_CONFIG"
    find "$OPENCLAW_DIR/credentials" -type f -exec chmod 600 {} \; 2>/dev/null || true
    success "パーミッション設定完了 (~/.openclaw: 700, 設定ファイル: 600)"
}

# ============================================================
# Spotlight 除外
# ============================================================
exclude_spotlight() {
    step "Spotlight インデックス除外"
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
    step "シェル補完 (zsh) インストール"

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
    step "Gateway デーモン登録・起動・検証"

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

    step "セキュリティ監査"
    openclaw security audit || true
    echo
    openclaw security audit --deep || true

    step "インストール確認"
    openclaw doctor || true
    openclaw status || true
}

# ============================================================
# LaunchAgent plist に環境変数を注入
# ============================================================
inject_launchagent_env() {
    step "LaunchAgent plist に OPENCLAW_NO_RESPAWN=1 を注入"

    local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if [[ ! -f "$plist" ]]; then
        warn "LaunchAgent plist が見つかりません: $plist"
        return
    fi

    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:OPENCLAW_NO_RESPAWN" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OPENCLAW_NO_RESPAWN string 1" "$plist"

    success "OPENCLAW_NO_RESPAWN=1 を $plist に注入"
    info "config 変更時の SIGUSR1 in-process restart による respawn ループを防止"
}

# ============================================================
# Cleanup config backups
# Doctor は config 書き換えのたびに ~/.openclaw/openclaw.json.{bak,bak.N,last-good}
# を生成する。Setup 直後はこれらの backup は不要 (snapshot に元 config が残っているため)
# なので一括削除する。
# ============================================================
cleanup_config_backups() {
    step "Doctor が生成した config backup を削除"
    local removed=0
    for f in "$OPENCLAW_CONFIG".bak "$OPENCLAW_CONFIG".bak.* "$OPENCLAW_CONFIG".last-good; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            removed=$((removed + 1))
        fi
    done
    if [[ $removed -gt 0 ]]; then
        success "${removed} 個の backup file を削除 (snapshot に元 config が残っているため安全)"
    else
        info "削除対象の backup file はありませんでした"
    fi
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
    echo "  --recover [DIR]  セットアップ完了後、snapshot から workspace と ~/.openclaw/cron を復元します。"
    echo "                   DIR を指定しない場合は最新の ~/.openclaw-snapshot-* を自動選択。"
    echo "                   DIR を指定する場合は snapshot ディレクトリのパスを空白区切りで渡します"
    echo "                   (例: --recover ~/.openclaw-snapshot-20260502-100534)。"
    echo "                   --recover=DIR の形式も可（先頭 ~ は内部で \$HOME に展開）。"
    echo "                   それ以外（identity, telegram, agents 等）の復元は手動で行ってください。"
    echo "  --help           このヘルプを表示"
    echo ""
    echo "環境変数 / .env:"
    echo "  プロジェクトルート (このスクリプトのある repo) に .env があれば読み込み、"
    echo "  下記キーがセットされている項目は対話入力を省略します。"
    echo "    TELEGRAM_OFFICIAL_BOT_TOKEN  official Bot の Token"
    echo "    TELEGRAM_PERSONAL_BOT_TOKEN  personal Bot の Token"
    echo "    TELEGRAM_USER_ID             Telegram User ID (数値)"
    echo "    ANTHROPIC_API_KEY            Anthropic API Key"
    echo "    LMSTUDIO_API_KEY             未指定時は \"lm-studio\" (LM Studio はローカルなので marker)"
    echo "    LMSTUDIO_MODEL               01 の lms get 対象 + 03 の personal-agent.model 初期値"
    echo "                                 (未指定時は unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit)"
    echo "                                 ※ 他の LM Studio モデルへの切り替えは openclaw.json の"
    echo "                                    agents.list[].model を編集すれば追従する"
    echo "  シェルから export した環境変数も同様に優先されます。"
}

# ============================================================
# Main
# ============================================================
main() {
    local recover=false
    local recover_snapshot=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recover)
                recover=true
                shift
                if [[ $# -gt 0 && "$1" != -* ]]; then
                    recover_snapshot="$1"
                    shift
                fi
                ;;
            --recover=*)
                recover=true
                recover_snapshot="${1#--recover=}"
                shift
                ;;
            --help) usage; exit 0 ;;
            *)      error "Unknown option: $1\nRun '$0 --help' for usage." ;;
        esac
    done

    # zsh/bash は --recover=~/path の形式では ~ をシェル展開しない。
    # 引数として受け取った先頭の ~ を $HOME に正規化する。
    if [[ "$recover_snapshot" == "~" || "$recover_snapshot" == "~/"* ]]; then
        recover_snapshot="${HOME}${recover_snapshot#\~}"
    fi

    echo -e "${BOLD}OpenClaw Gateway - OpenClaw Setup${NC}"
    echo -e "${BOLD}==================================${NC}"
    echo
    preflight
    load_project_env

    if [[ -d "$OPENCLAW_DIR" ]]; then
        backup_and_reset
    else
        info "既存の ~/.openclaw が見つからないためバックアップをスキップ（初回セットアップ）"
    fi

    echo
    info "このスクリプトは以下を実行します:"
    info "  - OpenClaw インストール"
    info "  - Telegram 拡張 peer deps install (上流 packaging bug 対応)"
    info "  - Telegram Bot 設定"
    info "  - ワークスペースパス検出 + AGENTS.md 生成"
    info "  - 設定ファイル生成 (openclaw.json)"
    info "  - 環境変数・APIキー設定"
    info "  - ファイルパーミッション設定 + Spotlight 除外"
    info "  - シェル補完 (zsh) インストール"
    info "  - Gateway デーモン登録・OPENCLAW_NO_RESPAWN 注入・検証"
    if $recover; then
        if [[ -n "$recover_snapshot" ]]; then
            info "  - 指定 snapshot から workspace + cron を復元 (--recover $recover_snapshot)"
        else
            info "  - 最新 snapshot から workspace + cron を復元 (--recover)"
        fi
    fi
    info "  - Doctor が生成した openclaw.json.{bak,bak.N,last-good} を削除"
    echo

    install_openclaw
    install_telegram_peer_deps
    setup_telegram
    detect_workspace
    generate_agents_md
    generate_config
    setup_secrets
    setup_permissions
    exclude_spotlight
    install_completions
    start_and_verify

    if $recover; then
        do_recover "$recover_snapshot"
    fi

    cleanup_config_backups

    echo
    step "OpenClaw Setup 完了!"
    info ""
    info "Telegram から official / personal の各 Bot に DM を送って応答が返れば完了です。"
    info ""
    info "snapshot から workspace + cron を復元する場合（次回セットアップ時に指定）:"
    info "  $0 --recover                                 # 最新 snapshot を自動選択"
    info "  $0 --recover ~/.openclaw-snapshot-<ts>       # 特定 snapshot を指定"
}

main "$@"
