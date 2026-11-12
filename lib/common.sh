#!/usr/bin/env bash
# Mirra - Common Utilities, OS Detection, Backup & Config Loader
# shellcheck disable=SC2034

MIRRA_VERSION="2.0.0"
MIRRA_REPO="Nzrmohammad/Mirra"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${MIRRA_REPO}/main"
GITHUB_MIRRORS_URL="${GITHUB_RAW_BASE}/mirrors.json"

MIRRA_BACKUP_DIR="/var/backups/mirra"
MIRRA_SHARE_DIR="/usr/local/share/mirra"
MIRRA_BIN_PATH="/usr/local/bin/mirra"

# Runtime flags
DRY_RUN=${DRY_RUN:-0}
AUTO_YES=${AUTO_YES:-0}
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
MIRRA_OFFLINE=${MIRRA_OFFLINE:-0}
JSON_OUTPUT=${JSON_OUTPUT:-0}

# Colors
BOLD='\033[1m'
RED='\033[0;31m'
BRED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[i]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
log_dry()  { echo -e "${CYAN}[DRY-RUN]${NC} $*"; }

read_input() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${3:-}"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_name" '%s' "$default_val"
        return 0
    fi
    local _input_val=""
    if [ -t 0 ]; then
        read -rp "$prompt" _input_val
        printf -v "$var_name" '%s' "$_input_val"
    elif [ -e /dev/tty ]; then
        read -rp "$prompt" _input_val < /dev/tty
        printf -v "$var_name" '%s' "$_input_val"
    else
        printf -v "$var_name" '%s' "$default_val"
    fi
}

confirm_action() {
    local prompt="${1:-Are you sure you want to proceed?}"
    if [ "$AUTO_YES" -eq 1 ] || [ "$NON_INTERACTIVE" -eq 1 ]; then
        return 0
    fi
    local ans=""
    read_input "$prompt [y/N]: " ans "n"
    [[ "$ans" =~ ^[Yy]$ ]]
}

pause_screen() {
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        return 0
    fi
    echo ""
    local unused=""
    read_input "Press [Enter] to continue..." unused ""
}

print_banner() {
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ -t 1 ]; then
        clear
    fi
    echo -e "${CYAN}${BOLD}"
    echo "  ███╗   ███╗██╗██████╗ ██████╗  █████╗ "
    echo "  ████╗ ████║██║██╔══██╗██╔══██╗██╔══██╗"
    echo "  ██╔████╔██║██║██████╔╝██████╔╝███████║"
    echo "  ██║╚██╔╝██║██║██╔══██╗██╔══██╗██╔══██║"
    echo "  ██║ ╚═╝ ██║██║██║  ██║██║  ██║██║  ██║"
    echo "  ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "${BOLD}   --- Automated Mirror, DNS & Anti-Sanction Helper (v${MIRRA_VERSION}) ---${NC}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "   ${CYAN}[MODE: DRY-RUN — No system files will be modified]${NC}"
    fi
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_warn "Running in DRY-RUN mode without root privileges."
            return 0
        fi
        log_err "This operation requires root privileges. Please run with sudo."
        exit 1
    fi
}

detect_os() {
    OS_ID="unknown"
    OS_PRETTY_NAME="Unknown Linux"
    OS_CODENAME=""
    OS_VERSION_ID=""
    OS_ID_LIKE=""

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi

    if [ -z "$OS_CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
        OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
    fi

    if [ -z "$OS_CODENAME" ] && [ "$OS_ID" = "debian" ]; then
        case "$OS_VERSION_ID" in
            10*) OS_CODENAME="buster" ;;
            11*) OS_CODENAME="bullseye" ;;
            12*) OS_CODENAME="bookworm" ;;
            13*) OS_CODENAME="trixie" ;;
        esac
    fi

    if command -v dpkg >/dev/null 2>&1; then
        OS_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    else
        case "$(uname -m)" in
            x86_64)  OS_ARCH="amd64" ;;
            aarch64) OS_ARCH="arm64" ;;
            armv7l)  OS_ARCH="armhf" ;;
            *)       OS_ARCH="$(uname -m)" ;;
        esac
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop|kali)
            PKG_FAMILY="apt"
            ;;
        alpine)
            PKG_FAMILY="apk"
            ;;
        rhel|centos|almalinux|rocky|fedora|ol)
            PKG_FAMILY="dnf"
            ;;
        arch|manjaro|endeavouros)
            PKG_FAMILY="pacman"
            ;;
        *)
            if [[ "$OS_ID_LIKE" == *"debian"* || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
                PKG_FAMILY="apt"
            elif [[ "$OS_ID_LIKE" == *"rhel"* || "$OS_ID_LIKE" == *"fedora"* ]]; then
                PKG_FAMILY="dnf"
            elif [[ "$OS_ID_LIKE" == *"arch"* ]]; then
                PKG_FAMILY="pacman"
            else
                PKG_FAMILY="unknown"
            fi
            ;;
    esac
}

get_target_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
        TARGET_HOME=$(awk -F: -v u="$SUDO_USER" '$1 == u {print $6}' /etc/passwd 2>/dev/null)
        if [ -z "$TARGET_HOME" ]; then
            TARGET_HOME="/home/$SUDO_USER"
        fi
    else
        TARGET_USER="${USER:-root}"
        TARGET_HOME="${HOME:-/root}"
    fi
}

run_as_target_user() {
    get_target_user
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would run as ${TARGET_USER}: $*"
        return 0
    fi
    if [ "$EUID" -eq 0 ] && [ "$TARGET_USER" != "root" ] && command -v su >/dev/null 2>&1; then
        local cmd_str
        printf -v cmd_str '%q ' "$@"
        su -s /bin/bash "$TARGET_USER" -c "HOME=\"$TARGET_HOME\" $cmd_str"
    else
        "$@"
    fi
}

backup_file() {
    local target="$1"
    if [ ! -e "$target" ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would backup $target"
        return 0
    fi

    mkdir -p "$MIRRA_BACKUP_DIR"
    local safe_name
    safe_name=$(echo "$target" | sed 's#^/##; s#/#__#g')
    local baseline="${MIRRA_BACKUP_DIR}/${safe_name}.orig"
    local stamped
    stamped="${MIRRA_BACKUP_DIR}/${safe_name}.$(date +%Y%m%d_%H%M%S)"

    if [ ! -e "$baseline" ]; then
        cp -a "$target" "$baseline"
        echo "${target}|${baseline}" >> "${MIRRA_BACKUP_DIR}/manifest.log"
    fi
    cp -a "$target" "$stamped"
    log_ok "Backup saved for $target ($stamped)"
}

restore_from_manifest() {
    local filter="${1:-}"
    local manifest="${MIRRA_BACKUP_DIR}/manifest.log"
    if [ ! -f "$manifest" ]; then
        log_warn "No Mirra backup manifest found in ${MIRRA_BACKUP_DIR}."
        return 1
    fi
    local restored=0
    while IFS='|' read -r orig_path backup_path; do
        [ -z "$orig_path" ] && continue
        if [ -n "$filter" ] && [[ "$orig_path" != *"$filter"* ]]; then
            continue
        fi
        if [ -e "$backup_path" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would restore $orig_path from $backup_path"
            else
                mkdir -p "$(dirname "$orig_path")"
                cp -a "$backup_path" "$orig_path"
                log_ok "Restored $orig_path"
            fi
            restored=$((restored + 1))
        fi
    done < "$manifest"

    if [ "$restored" -eq 0 ]; then
        log_warn "No matching backups found to restore."
        return 1
    fi
    return 0
}

write_file_safe() {
    local target="$1"
    local content="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would write ${target}:"
        echo -e "${GRAY}----------------------------------------${NC}"
        printf '%s\n' "$content"
        echo -e "${GRAY}----------------------------------------${NC}"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    local tmp_file
    tmp_file=$(mktemp)
    printf '%s\n' "$content" > "$tmp_file"
    mv "$tmp_file" "$target"
    chmod 644 "$target"
}

json_get_array() {
    local json_file="$1"
    local key="$2"
    if [ ! -f "$json_file" ]; then
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k][]? // empty' "$json_file" 2>/dev/null
        return $?
    fi
    # Pure awk fallback for simple string arrays in mirrors.json
    awk -v target="\"$key\"" '
        BEGIN { in_arr = 0 }
        $0 ~ target "[[:space:]]*:[[:space:]]*\\[" { in_arr = 1; next }
        in_arr && /\]/ { in_arr = 0; exit }
        in_arr {
            line = $0
            gsub(/^[[:space:]]*"|"[[:space:]]*,?[[:space:]]*$/, "", line)
            if (length(line) > 0) print line
        }
    ' "$json_file" 2>/dev/null
}

json_get_scalar() {
    local json_file="$1"
    local key="$2"
    if [ ! -f "$json_file" ]; then
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$json_file" 2>/dev/null
        return $?
    fi
    awk -v target="\"$key\"" '
        $0 ~ target "[[:space:]]*:" {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/,[[:space:]]*$/, "", line)
            gsub(/^"|"$/, "", line)
            if (line == "null") line = ""
            print line
            exit
        }
    ' "$json_file" 2>/dev/null
}

json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

init_default_mirrors() {
    APT_UBUNTU_IRAN=(
        "http://mirror.arvancloud.ir/ubuntu/"
        "http://ir.archive.ubuntu.com/ubuntu/"
        "http://ubuntu.internet.ir/ubuntu/"
        "http://mirrors.piconet.ir/ubuntu/"
        "http://mirror.iut.ac.ir/ubuntu/"
        "http://mirrors.asis.ai/ubuntu/"
        "http://ubuntu.hostiran.ir/ubuntu/"
        "http://mirror.ut.ac.ir/ubuntu/"
        "http://mirror.sharif.ir/ubuntu/"
        "http://mirror.liara.ir/ubuntu/"
        "http://mirror-ubuntu.runflare.com/ubuntu/"
    )
    APT_UBUNTU_GLOBAL=(
        "http://archive.ubuntu.com/ubuntu/"
        "http://us.archive.ubuntu.com/ubuntu/"
        "http://uk.archive.ubuntu.com/ubuntu/"
        "http://de.archive.ubuntu.com/ubuntu/"
    )
    APT_UBUNTU_PORTS=(
        "http://ports.ubuntu.com/ubuntu-ports/"
        "http://mirror.arvancloud.ir/ubuntu-ports/"
    )
    APT_DEBIAN_IRAN=(
        "http://mirror.arvancloud.ir/debian/"
        "http://debian.asis.ai/debian/"
        "http://mirror.iut.ac.ir/debian/"
        "http://mirror.ut.ac.ir/debian/"
        "http://mirror.sharif.ir/debian/"
        "http://mirror.liara.ir/debian/"
    )
    APT_DEBIAN_GLOBAL=(
        "http://deb.debian.org/debian/"
        "http://ftp.us.debian.org/debian/"
        "http://ftp.de.debian.org/debian/"
    )
    ALPINE_IRAN=(
        "https://mirror.arvancloud.ir/alpine/"
        "https://mirror.liara.ir/alpine/"
    )
    ALPINE_GLOBAL=(
        "https://dl-cdn.alpinelinux.org/alpine/"
        "https://mirror.leaseweb.com/alpine/"
    )
    ARCH_IRAN=(
        "https://mirror.arvancloud.ir/archlinux/"
        "https://mirror.ut.ac.ir/archlinux/"
    )
    ARCH_GLOBAL=(
        "https://geo.mirror.pkgbuild.com/"
    )
    DOCKER_IRAN=(
        "https://docker.arvancloud.ir"
        "https://docker.mobinhost.com"
        "https://docker.kernel.ir"
        "https://docker.iranrepo.ir"
        "https://docker.iranserver.com"
        "https://docker.parspack.com"
        "https://dockerhub.ir"
        "https://docker.sotoon.ir"
        "https://docker.derak.cloud"
        "https://docker.liara.ir"
        "https://registry.podspace.ir"
        "https://docker.snapp.ir"
        "https://mirror-docker.runflare.com"
    )
    DOCKER_GLOBAL=(
        "https://registry-1.docker.io"
        "https://mirror.gcr.io"
        "https://public.ecr.aws"
    )
    PIP_IRAN=(
        "https://mirror-pypi.runflare.com/simple/"
        "https://pypi.iranrepo.ir/simple/"
        "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/"
    )
    PIP_GLOBAL=("https://pypi.org/simple/")
    NPM_IRAN=("https://registry.npmmirror.com/" "https://mirrors.cloud.tencent.com/npm/")
    NPM_GLOBAL=("https://registry.npmjs.org/")
    GO_IRAN=("https://goproxy.cn,direct" "https://goproxy.io,direct")
    GO_GLOBAL=("https://proxy.golang.org,direct")
    CARGO_IRAN=("https://rsproxy.cn/crates.io-index" "https://mirrors.ustc.edu.cn/crates.io-index/")
    COMPOSER_IRAN=("https://mirrors.aliyun.com/composer/")
    MAVEN_IRAN=("https://maven.aliyun.com/repository/public")
    NVM_IRAN=("https://npmmirror.com/mirrors/node/")
    RUSTUP_IRAN=("https://rsproxy.cn|https://rsproxy.cn/rustup")
    CONDA_IRAN=("https://mirrors.tuna.tsinghua.edu.cn/anaconda")
    RUBY_IRAN=("https://gems.ruby-china.com/" "https://mirrors.tuna.tsinghua.edu.cn/rubygems/")
    NUGET_IRAN=("https://nuget.cdn.azure.cn/v3/index.json")
    BREW_IRAN=("https://mirrors.tuna.tsinghua.edu.cn")
    DNF_IRAN=("https://mirror.arvancloud.ir" "https://mirrors.aliyun.com")
    GITHUB_PROXIES=("https://ghfast.top/" "https://mirror.ghproxy.com/")
    DNS_IRAN=(
        "Shecan|178.22.122.100|185.51.200.2"
        "403.online|10.202.10.202|10.202.10.102"
        "Begzar|185.55.226.26|185.55.225.25"
        "Radar|10.202.10.10|10.202.10.11"
        "Electro|78.157.42.100|78.157.42.101"
        "Shatel|85.15.1.14|85.15.1.15"
    )
    DNS_GLOBAL=(
        "Cloudflare|1.1.1.1|1.0.0.1"
        "Google|8.8.8.8|8.8.4.4"
        "Quad9|9.9.9.9|149.112.112.112"
    )
}

_populate_array_from_json() {
    local json_file="$1"
    local key="$2"
    local -n target_arr="$3"
    local tmp=()
    mapfile -t tmp < <(json_get_array "$json_file" "$key")
    if [ "${#tmp[@]}" -gt 0 ]; then
        target_arr=("${tmp[@]}")
    fi
}

load_mirrors_config() {
    init_default_mirrors

    local json_source=""
    local local_candidates=(
        "${SCRIPT_DIR:-}/mirrors.json"
        "${MIRRA_SHARE_DIR}/mirrors.json"
        "./mirrors.json"
    )

    if [ "$MIRRA_OFFLINE" -eq 0 ] && command -v curl >/dev/null 2>&1; then
        local remote_tmp="/tmp/mirra_mirrors_$$.json"
        if curl -fsSL --connect-timeout 2 --max-time 3 "$GITHUB_MIRRORS_URL" -o "$remote_tmp" 2>/dev/null; then
            if grep -q '"apt_ubuntu_iran"' "$remote_tmp" 2>/dev/null; then
                json_source="$remote_tmp"
            else
                rm -f "$remote_tmp"
            fi
        else
            rm -f "$remote_tmp"
        fi
    fi

    if [ -z "$json_source" ]; then
        local cand
        for cand in "${local_candidates[@]}"; do
            if [ -n "$cand" ] && [ -f "$cand" ]; then
                json_source="$cand"
                break
            fi
        done
    fi

    if [ -n "$json_source" ]; then
        _populate_array_from_json "$json_source" "apt_ubuntu_iran" APT_UBUNTU_IRAN
        _populate_array_from_json "$json_source" "apt_ubuntu_global" APT_UBUNTU_GLOBAL
        _populate_array_from_json "$json_source" "apt_ubuntu_ports" APT_UBUNTU_PORTS
        _populate_array_from_json "$json_source" "apt_debian_iran" APT_DEBIAN_IRAN
        _populate_array_from_json "$json_source" "apt_debian_global" APT_DEBIAN_GLOBAL
        _populate_array_from_json "$json_source" "alpine_iran" ALPINE_IRAN
        _populate_array_from_json "$json_source" "alpine_global" ALPINE_GLOBAL
        _populate_array_from_json "$json_source" "arch_iran" ARCH_IRAN
        _populate_array_from_json "$json_source" "arch_global" ARCH_GLOBAL
        _populate_array_from_json "$json_source" "docker_iran" DOCKER_IRAN
        _populate_array_from_json "$json_source" "docker_global" DOCKER_GLOBAL
        _populate_array_from_json "$json_source" "pip_iran" PIP_IRAN
        _populate_array_from_json "$json_source" "pip_global" PIP_GLOBAL
        _populate_array_from_json "$json_source" "npm_iran" NPM_IRAN
        _populate_array_from_json "$json_source" "npm_global" NPM_GLOBAL
        _populate_array_from_json "$json_source" "go_iran" GO_IRAN
        _populate_array_from_json "$json_source" "go_global" GO_GLOBAL
        _populate_array_from_json "$json_source" "cargo_iran" CARGO_IRAN
        _populate_array_from_json "$json_source" "composer_iran" COMPOSER_IRAN
        _populate_array_from_json "$json_source" "maven_iran" MAVEN_IRAN
        _populate_array_from_json "$json_source" "nvm_iran" NVM_IRAN
        _populate_array_from_json "$json_source" "rustup_iran" RUSTUP_IRAN
        _populate_array_from_json "$json_source" "conda_iran" CONDA_IRAN
        _populate_array_from_json "$json_source" "ruby_iran" RUBY_IRAN
        _populate_array_from_json "$json_source" "nuget_iran" NUGET_IRAN
        _populate_array_from_json "$json_source" "brew_iran" BREW_IRAN
        _populate_array_from_json "$json_source" "dnf_iran" DNF_IRAN
        _populate_array_from_json "$json_source" "github_proxies" GITHUB_PROXIES
        _populate_array_from_json "$json_source" "dns_iran" DNS_IRAN
        _populate_array_from_json "$json_source" "dns_global" DNS_GLOBAL
        if [[ "$json_source" == /tmp/mirra_mirrors_*.json ]]; then
            rm -f "$json_source"
        fi
    fi
}
