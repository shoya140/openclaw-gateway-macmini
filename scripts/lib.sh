#!/bin/bash
# scripts/lib.sh — 3 つの setup スクリプトで共有する関数群。
# 利用側は `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"` で読み込む。

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
    local value
    read -rp "$(echo -e "${BLUE}$1: ${NC}")" value
    echo "$value"
}

prompt_secret() {
    local value
    read -rsp "$(echo -e "${BLUE}$1: ${NC}")" value
    echo >&2
    echo "$value"
}

# ============================================================
# プロジェクトルート (このリポジトリの直下) の .env を環境変数として読み込む。
# 既に export されている値は上書きされない（set -a 経由のため、export 時は
# 子プロセスに継承される）。
# ============================================================
load_project_env() {
    local script_dir project_root project_env
    script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[1]}" )" &> /dev/null && pwd )"
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
