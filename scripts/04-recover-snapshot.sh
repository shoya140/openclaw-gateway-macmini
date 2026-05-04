#!/bin/bash
set -euo pipefail

source "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/lib.sh"

OPENCLAW_DIR="$HOME/.openclaw"
WORKSPACE_BASENAME="openclaw-workspace"
LAUNCHAGENT_LABEL="ai.openclaw.gateway"

# ============================================================
# Pre-flight
# ============================================================
preflight() {
    [[ "$(uname)" == "Darwin" ]] || error "macOS 専用スクリプトです"
    [[ "$(whoami)" == "claw" ]] || error "このスクリプトは 'claw' ユーザーで実行してください (現在: $(whoami))"
    [[ -d "$OPENCLAW_DIR" ]] || error "~/.openclaw が存在しません。先に 03-openclaw-setup.sh を実行してください"
    success "Pre-flight OK (user: claw)"
}

# ============================================================
# Workspace path validation
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
# workspace 復元: snapshot/workspace/* → Google Drive 上の openclaw-workspace
# ============================================================
recover_workspace() {
    local snapshot_dir="$1"

    if [[ ! -d "$snapshot_dir/workspace" ]]; then
        info "snapshot に workspace ディレクトリがありません。スキップ"
        return
    fi

    step "workspace 復元 (snapshot → Google Drive 上の workspace)"

    local workspace_real=""
    if [[ -L "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real=$(readlink "$OPENCLAW_DIR/workspace")
    elif [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        workspace_real="$OPENCLAW_DIR/workspace"
    fi

    [[ -n "$workspace_real" ]] \
        || error "~/.openclaw/workspace の実体パスを検出できません。03 を実行して symlink を作成してください"
    [[ -d "$workspace_real" ]] \
        || error "~/.openclaw/workspace の実体ディレクトリが存在しません: $workspace_real"

    validate_workspace_path "$workspace_real" "recover_workspace (target)"

    info "Source: $snapshot_dir/workspace"
    info "Target: $workspace_real"

    shopt -s dotglob nullglob
    local items=("$snapshot_dir/workspace"/*)
    shopt -u dotglob nullglob

    if [[ ${#items[@]} -eq 0 ]]; then
        info "snapshot/workspace は空でした"
        return
    fi

    cp -a "${items[@]}" "$workspace_real/"
    success "workspace 復元: ${#items[@]} 項目を $workspace_real に書き戻し (Google Drive 経由で個人 PC にも sync)"
}

# ============================================================
# cron 復元: snapshot/cron → ~/.openclaw/cron (既存は削除して置き換え)
# ============================================================
recover_cron() {
    local snapshot_dir="$1"

    if [[ ! -d "$snapshot_dir/cron" ]]; then
        info "snapshot に cron ディレクトリがありません。スキップ"
        return
    fi

    step "cron 復元 (snapshot → ~/.openclaw/cron)"

    info "Source: $snapshot_dir/cron"
    info "Target: $OPENCLAW_DIR/cron"

    rm -rf "$OPENCLAW_DIR/cron"
    cp -a "$snapshot_dir/cron" "$OPENCLAW_DIR/"
    chmod -R go-rwx "$OPENCLAW_DIR/cron" 2>/dev/null || true

    success "cron 復元: $OPENCLAW_DIR/cron"
}

# ============================================================
# Gateway を再ロード (新しい cron を反映)
# 二重 polling 防止のため kickstart のみで restart はしない
# ============================================================
reload_gateway() {
    step "Gateway を再ロード (新しい cron を反映)"

    local uid
    uid=$(id -u)

    if launchctl print "gui/${uid}/${LAUNCHAGENT_LABEL}" &>/dev/null; then
        if launchctl kickstart -k "gui/${uid}/${LAUNCHAGENT_LABEL}"; then
            success "LaunchAgent kickstart 完了"
        else
            warn "kickstart に失敗。手動で 'launchctl kickstart -k gui/${uid}/${LAUNCHAGENT_LABEL}' を実行してください"
        fi
    else
        warn "LaunchAgent (${LAUNCHAGENT_LABEL}) が登録されていません。03 を実行してください"
    fi
}

# ============================================================
# Usage
# ============================================================
usage() {
    cat <<USAGE
Usage: $0 <snapshot-dir>

snapshot ディレクトリから workspace と cron を復元します (上書き)。

引数:
  <snapshot-dir>  ~/.openclaw-snapshot-<ts> 形式のディレクトリパス
                  (先頭の '~' は \$HOME に展開されます)

復元対象:
  - <snapshot-dir>/workspace/* → ~/.openclaw/workspace の symlink 先 (Google Drive 上の openclaw-workspace) に cp -a
  - <snapshot-dir>/cron/       → ~/.openclaw/cron に cp -a (既存は削除して置き換え)

復元しないもの (必要な場合は手動コピーしてください):
  identity / telegram / credentials / agents / memory / media / flows / tasks / plugins / skills 等

復元後は LaunchAgent を kickstart して新しい cron を反映します。

例:
  $0 ~/.openclaw-snapshot-20260504-110000
  $0 --help
USAGE
}

# ============================================================
# Main
# ============================================================
main() {
    local snapshot_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help) usage; exit 0 ;;
            --*)    error "Unknown option: $1\nRun '$0 --help' for usage." ;;
            *)
                if [[ -z "$snapshot_arg" ]]; then
                    snapshot_arg="$1"
                else
                    error "snapshot ディレクトリは 1 つだけ指定してください"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$snapshot_arg" ]]; then
        usage
        echo
        error "snapshot ディレクトリが指定されていません"
    fi

    if [[ "$snapshot_arg" == "~" || "$snapshot_arg" == "~/"* ]]; then
        snapshot_arg="${HOME}${snapshot_arg#\~}"
    fi

    [[ -d "$snapshot_arg" ]] || error "指定された snapshot ディレクトリが存在しません: $snapshot_arg"

    echo -e "${BOLD}OpenClaw Gateway - Snapshot Recover${NC}"
    echo -e "${BOLD}====================================${NC}"
    echo

    preflight

    info "Snapshot: $snapshot_arg"
    info "復元対象: workspace, cron"
    echo

    recover_workspace "$snapshot_arg"
    recover_cron "$snapshot_arg"
    reload_gateway

    echo
    step "Snapshot Recover 完了"
}

main "$@"
