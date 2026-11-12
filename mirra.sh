#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -uo pipefail

# ==============================================================================
# Mirra - Automated Mirror, DNS & Anti-Sanction Helper for Linux Servers
# Repository: https://github.com/Nzrmohammad/Mirra
# ==============================================================================

MIRRA_RAW_URL="https://raw.githubusercontent.com/Nzrmohammad/Mirra/main"
MIRRA_MODULES=("common.sh" "network.sh" "pkg.sh" "containers.sh" "devtools.sh" "dns_proxy.sh" "profile.sh" "automation.sh")
MIRRA_TMP_BOOTSTRAP=""

cleanup_bootstrap() {
    if [ -n "$MIRRA_TMP_BOOTSTRAP" ] && [ -d "$MIRRA_TMP_BOOTSTRAP" ]; then
        rm -rf "$MIRRA_TMP_BOOTSTRAP"
    fi
}
trap cleanup_bootstrap EXIT

resolve_script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo ""
        return
    fi
    while [ -L "$src" ]; do
        local dir
        dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
        src=$(readlink "$src")
        [[ "$src" != /* ]] && src="${dir}/${src}"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

load_modules() {
    SCRIPT_DIR=$(resolve_script_dir)
    local lib_dir=""

    if [ -n "$SCRIPT_DIR" ] && [ -d "${SCRIPT_DIR}/lib" ] && [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
        lib_dir="${SCRIPT_DIR}/lib"
    elif [ -d "/usr/local/share/mirra/lib" ] && [ -f "/usr/local/share/mirra/lib/common.sh" ]; then
        lib_dir="/usr/local/share/mirra/lib"
        SCRIPT_DIR="/usr/local/share/mirra"
    else
        # Piped via curl | bash: bootstrap modules to a temp dir
        if ! command -v curl >/dev/null 2>&1; then
            echo "Error: curl is required to bootstrap Mirra modules." >&2
            exit 1
        fi
        MIRRA_TMP_BOOTSTRAP=$(mktemp -d)
        mkdir -p "${MIRRA_TMP_BOOTSTRAP}/lib"
        local m
        for m in "${MIRRA_MODULES[@]}"; do
            if ! curl -fsSL --connect-timeout 5 --max-time 15 "${MIRRA_RAW_URL}/lib/${m}" -o "${MIRRA_TMP_BOOTSTRAP}/lib/${m}"; then
                echo "Error: Failed to fetch module ${m} from ${MIRRA_RAW_URL}" >&2
                exit 1
            fi
        done
        curl -fsSL --connect-timeout 3 --max-time 10 "${MIRRA_RAW_URL}/mirrors.json" -o "${MIRRA_TMP_BOOTSTRAP}/mirrors.json" 2>/dev/null || true
        lib_dir="${MIRRA_TMP_BOOTSTRAP}/lib"
        SCRIPT_DIR="${MIRRA_TMP_BOOTSTRAP}"
    fi

    for m in "${MIRRA_MODULES[@]}"; do
        # shellcheck source=/dev/null
        source "${lib_dir}/${m}"
    done
}

install_mirra_cli() {
    check_root
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would install mirra to ${MIRRA_BIN_PATH} and modules to ${MIRRA_SHARE_DIR}"
        return 0
    fi
    mkdir -p "${MIRRA_SHARE_DIR}/lib"
    local m
    if [ -n "$SCRIPT_DIR" ] && [ -d "${SCRIPT_DIR}/lib" ]; then
        for m in "${MIRRA_MODULES[@]}"; do
            cp -f "${SCRIPT_DIR}/lib/${m}" "${MIRRA_SHARE_DIR}/lib/${m}"
        done
        [ -f "${SCRIPT_DIR}/mirrors.json" ] && cp -f "${SCRIPT_DIR}/mirrors.json" "${MIRRA_SHARE_DIR}/mirrors.json"
    fi

    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        cp -f "${BASH_SOURCE[0]}" "${MIRRA_SHARE_DIR}/mirra.sh"
    else
        curl -fsSL "${MIRRA_RAW_URL}/mirra.sh" -o "${MIRRA_SHARE_DIR}/mirra.sh"
    fi
    chmod +x "${MIRRA_SHARE_DIR}/mirra.sh"
    ln -sf "${MIRRA_SHARE_DIR}/mirra.sh" "${MIRRA_BIN_PATH}"
    log_ok "Mirra installed! You can now run 'sudo mirra' from anywhere."
}

update_mirra_cli() {
    check_root
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would update mirra from ${MIRRA_RAW_URL}"
        return 0
    fi
    mkdir -p "${MIRRA_SHARE_DIR}/lib"
    curl -fsSL "${MIRRA_RAW_URL}/mirra.sh" -o "${MIRRA_SHARE_DIR}/mirra.sh" || { log_err "Failed to update mirra.sh"; return 1; }
    local m
    for m in "${MIRRA_MODULES[@]}"; do
        curl -fsSL "${MIRRA_RAW_URL}/lib/${m}" -o "${MIRRA_SHARE_DIR}/lib/${m}" || { log_err "Failed to update ${m}"; return 1; }
    done
    curl -fsSL "${MIRRA_RAW_URL}/mirrors.json" -o "${MIRRA_SHARE_DIR}/mirrors.json" || true
    chmod +x "${MIRRA_SHARE_DIR}/mirra.sh"
    ln -sf "${MIRRA_SHARE_DIR}/mirra.sh" "${MIRRA_BIN_PATH}"
    log_ok "Mirra updated to latest version from GitHub."
}

uninstall_mirra_cli() {
    check_root
    if ! confirm_action "Uninstall Mirra from ${MIRRA_BIN_PATH} and ${MIRRA_SHARE_DIR}?"; then
        log_warn "Uninstall canceled."
        return 0
    fi
    if [ "$NON_INTERACTIVE" -eq 0 ] && confirm_action "Restore all backed-up system configs before uninstalling?"; then
        AUTO_YES=1 restore_all_configs || true
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would disable watchdog and remove ${MIRRA_BIN_PATH}, ${MIRRA_SHARE_DIR}, ${MIRRA_ETC_DIR}"
        return 0
    fi
    disable_watchdog >/dev/null 2>&1 || true
    rm -f "$MIRRA_BIN_PATH"
    rm -rf "$MIRRA_SHARE_DIR" "$MIRRA_ETC_DIR"
    log_ok "Mirra uninstalled cleanly. Backups remain preserved in ${MIRRA_BACKUP_DIR}."
}

print_status() {
    local dver="" pver="" npm_ver="" npm_reg="" go_ver="" go_proxy=""
    local proxy_active=false custom_dns=false ipv6_disabled=false
    local cur_dns=""

    if command -v docker >/dev/null 2>&1; then
        dver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    fi
    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
        pver=$( (pip3 --version || pip --version) 2>/dev/null | awk '{print $2}' )
    fi
    if command -v npm >/dev/null 2>&1; then
        npm_ver=$(npm --version 2>/dev/null || true)
        npm_reg=$(npm config get registry 2>/dev/null || true)
    fi
    if command -v go >/dev/null 2>&1; then
        go_ver=$(go version 2>/dev/null | awk '{print $3}')
        go_proxy=$(go env GOPROXY 2>/dev/null || true)
    fi
    [ -f "$PROFILE_PROXY_FILE" ] && proxy_active=true
    [ -f "$RESOLVED_DROPIN_FILE" ] && custom_dns=true
    [ -f "$SYSCTL_IPV6_FILE" ] && ipv6_disabled=true
    cur_dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | xargs || true)

    if [ "${JSON_OUTPUT:-0}" -eq 1 ]; then
        cat <<EOF
{
  "version": "$(json_escape "$MIRRA_VERSION")",
  "os": "$(json_escape "$OS_PRETTY_NAME")",
  "os_id": "$(json_escape "$OS_ID")",
  "codename": "$(json_escape "${OS_CODENAME:-N/A}")",
  "arch": "$(json_escape "$OS_ARCH")",
  "pkg_family": "$(json_escape "$PKG_FAMILY")",
  "docker": { "installed": $([ -n "$dver" ] && echo true || echo false), "version": "$(json_escape "$dver")" },
  "pip": { "installed": $([ -n "$pver" ] && echo true || echo false), "version": "$(json_escape "$pver")" },
  "npm": { "installed": $([ -n "$npm_ver" ] && echo true || echo false), "version": "$(json_escape "$npm_ver")", "registry": "$(json_escape "$npm_reg")" },
  "go": { "installed": $([ -n "$go_ver" ] && echo true || echo false), "version": "$(json_escape "$go_ver")", "goproxy": "$(json_escape "$go_proxy")" },
  "proxy_active": ${proxy_active},
  "custom_dns_active": ${custom_dns},
  "system_dns": "$(json_escape "$cur_dns")",
  "ipv6_disabled": ${ipv6_disabled}
}
EOF
        return 0
    fi

    print_banner
    echo -e "${BLUE}System & Mirror Overview:${NC}"
    echo -e "  • OS:             ${BOLD}${OS_PRETTY_NAME}${NC} (codename: ${OS_CODENAME:-N/A}, arch: ${OS_ARCH}, pkg: ${PKG_FAMILY})"

    if [ -n "$dver" ]; then
        echo -e "  • Docker:         ${GREEN}Installed (${dver})${NC}"
    else
        echo -e "  • Docker:         ${GRAY}Not Installed${NC}"
    fi

    if [ -n "$pver" ]; then
        echo -e "  • Python Pip:     ${GREEN}Installed (${pver})${NC}"
    else
        echo -e "  • Python Pip:     ${GRAY}Not Installed${NC}"
    fi

    if [ -n "$npm_ver" ]; then
        echo -e "  • Node.js NPM:    ${GREEN}Installed (${npm_ver})${NC} -> ${npm_reg}"
    else
        echo -e "  • Node.js NPM:    ${GRAY}Not Installed${NC}"
    fi

    if [ -n "$go_ver" ]; then
        echo -e "  • Golang:         ${GREEN}Installed (${go_ver})${NC} -> ${go_proxy}"
    else
        echo -e "  • Golang:         ${GRAY}Not Installed${NC}"
    fi

    if [ "$proxy_active" = "true" ]; then
        echo -e "  • System Proxy:   ${YELLOW}Configured (${PROFILE_PROXY_FILE})${NC}"
    else
        echo -e "  • System Proxy:   ${GRAY}None${NC}"
    fi

    if [ "$custom_dns" = "true" ]; then
        echo -e "  • Custom DNS:     ${GREEN}Active (${RESOLVED_DROPIN_FILE})${NC}"
    else
        echo -e "  • System DNS:     ${cur_dns:-N/A}"
    fi

    if [ "$ipv6_disabled" = "true" ]; then
        echo -e "  • IPv6 State:     ${YELLOW}Disabled by Mirra (IPv4 preferred)${NC}"
    fi
    echo ""
}

execute_one_click() {
    local target_mode="$1"
    if [ "$target_mode" = "AUTO" ]; then
        log_info "Detecting server network region..."
        target_mode=$(detect_network_region)
        log_ok "Detected optimal profile: ${BOLD}${target_mode}${NC}"
    fi

    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        print_banner
        echo -e "${YELLOW}[ Confirmation: One-Click Auto Config - Mode: ${target_mode} ]${NC}\n"
        echo "  • Back up existing package manager, container, and dev tool configs"
        echo "  • Benchmark & configure fastest ${target_mode} OS package mirror (${PKG_FAMILY})"
        echo "  • Benchmark & configure ${target_mode} Docker mirrors (merging daemon.json)"
        echo "  • Configure ${target_mode} Pip, NPM/Yarn/pnpm, Go, Cargo & Composer mirrors"
        echo "  • Configure ${target_mode} Anti-Sanction / Global DNS"
        echo ""
        if ! confirm_action "Proceed with ${target_mode} Auto-Configuration?"; then
            log_warn "Operation canceled."
            pause_screen
            return
        fi
    fi

    echo ""
    log_info "Executing Auto-Configuration (${target_mode})..."
    configure_pkg_auto "$target_mode" || true
    configure_docker_auto "$target_mode" || true
    configure_devtools_auto "$target_mode" || true
    configure_dns_auto "$target_mode" || true

    echo ""
    log_ok "All system mirrors and DNS configured for ${target_mode} mode!"
    pause_screen
}

restore_all_configs() {
    check_root
    if ! confirm_action "Restore ALL original configs backed up by Mirra?"; then
        log_warn "Operation canceled."
        return 0
    fi
    restore_from_manifest "" || true
    clear_system_proxy || true
    restore_dns_config || true
    apply_devtools_env_profile "GLOBAL" || true
    [ -f "$SYSCTL_IPV6_FILE" ] && apply_ipv6_state "enable" || true
    [ -f "$SYSCTL_BBR_FILE" ] && apply_bbr_state "disable" || true
    [ -f "$TIMESYNCD_DROPIN_FILE" ] && [ "$DRY_RUN" -eq 0 ] && rm -f "$TIMESYNCD_DROPIN_FILE" || true
    if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        systemctl restart docker || true
    fi
    log_ok "Full restore completed."
}

menu_diagnostics() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 5: Speed Test & Network Diagnostics ]${NC}\n"
        echo "1) Benchmark Iranian OS mirrors (${OS_ID})"
        echo "2) Benchmark Global OS mirrors (${OS_ID})"
        echo "3) Benchmark Iranian Docker mirrors"
        echo "4) Benchmark Global Docker mirrors"
        echo "5) Benchmark Iranian Pip mirrors"
        echo "6) Benchmark all Iranian & Global DNS servers (read-only)"
        echo "7) Run multi-layer network & sanction diagnostics"
        echo -e "${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-7]: " choice "0"
        case "$choice" in
            1)
                if [ "$PKG_FAMILY" = "apt" ]; then
                    local arr; arr=$(_get_apt_mirror_list "IRAN")
                    benchmark_mirrors "$arr" "dists/${OS_CODENAME}/Release" "http" 0 || true
                elif [ "$PKG_FAMILY" = "apk" ]; then
                    benchmark_mirrors ALPINE_IRAN "" "http" 0 || true
                elif [ "$PKG_FAMILY" = "pacman" ]; then
                    benchmark_mirrors ARCH_IRAN "" "http" 0 || true
                elif [ "$PKG_FAMILY" = "dnf" ]; then
                    benchmark_mirrors DNF_IRAN "" "http" 0 || true
                fi
                pause_screen
                ;;
            2)
                if [ "$PKG_FAMILY" = "apt" ]; then
                    local arr; arr=$(_get_apt_mirror_list "GLOBAL")
                    benchmark_mirrors "$arr" "dists/${OS_CODENAME}/Release" "http" 0 || true
                elif [ "$PKG_FAMILY" = "apk" ]; then
                    benchmark_mirrors ALPINE_GLOBAL "" "http" 0 || true
                elif [ "$PKG_FAMILY" = "pacman" ]; then
                    benchmark_mirrors ARCH_GLOBAL "" "http" 0 || true
                fi
                pause_screen
                ;;
            3) benchmark_mirrors DOCKER_IRAN "/v2/" "docker" 0 || true; pause_screen ;;
            4) benchmark_mirrors DOCKER_GLOBAL "/v2/" "docker" 0 || true; pause_screen ;;
            5) benchmark_mirrors PIP_IRAN "" "http" 0 || true; pause_screen ;;
            6)
                benchmark_dns_list DNS_IRAN || true
                echo ""
                benchmark_dns_list DNS_GLOBAL || true
                pause_screen
                ;;
            7) robust_network_check; pause_screen ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}

one_click_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 6: One-Click Auto Config ]${NC}\n"
        echo -e "  ${CYAN}1)${NC} Smart Auto-Detect & Configure ${GREEN}(Recommended)${NC}"
        echo -e "  ${CYAN}2)${NC} Force ${GREEN}Iranian Mirrors${NC} (Iran-based servers)"
        echo -e "  ${CYAN}3)${NC} Force ${BLUE}Global / Official Mirrors${NC} (Overseas VPS)"
        echo -e "  ${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-3]: " choice "0"
        case "$choice" in
            1) execute_one_click "AUTO" ;;
            2) execute_one_click "IRAN" ;;
            3) execute_one_click "GLOBAL" ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        print_status
        echo -e "${BOLD}Please select an option:${NC}\n"
        echo -e "  ${CYAN}1)${NC} Configure OS Package Manager ${YELLOW}(${OS_ID} / ${PKG_FAMILY})${NC}"
        echo -e "  ${CYAN}2)${NC} Configure Container Engines ${YELLOW}(Docker / containerd / Podman)${NC}"
        echo -e "  ${CYAN}3)${NC} Configure Dev Tools ${YELLOW}(Pip/uv, Node, Go, Rust, Composer, GitHub)${NC}"
        echo -e "  ${CYAN}4)${NC} Anti-Sanction DNS & System Proxy ${YELLOW}(Shecan, 403, Begzar, Proxy)${NC}"
        echo -e "  ${CYAN}5)${NC} Speed Test & Network Diagnostics"
        echo -e "  ${CYAN}6)${NC} One-Click Auto Config ${YELLOW}(Auto-Detect Region & Apply All)${NC}"
        echo -e "  ${CYAN}7)${NC} Maintenance, Profile Export/Import & Rollback"
        echo -e "  ${BRED}0) Exit${NC}\n"

        local main_choice=""
        read_input "Enter choice [0-7]: " main_choice "0"
        case "$main_choice" in
            1) menu_system_os ;;
            2) menu_containers ;;
            3) menu_dev_tools ;;
            4) menu_dns_proxy ;;
            5) menu_diagnostics ;;
            6) one_click_menu ;;
            7)
                print_banner
                echo -e "${YELLOW}[ Section 7: Mirra Maintenance ]${NC}\n"
                echo "1) Install 'mirra' globally (/usr/local/bin/mirra)"
                echo "2) Update Mirra from GitHub"
                echo "3) Uninstall Mirra from system"
                echo "4) Export current mirror profile to JSON"
                echo "5) Import mirror profile from JSON"
                echo "6) Enable / Disable Daily Watchdog Timer & Telegram Alerts"
                echo "7) Patch Project Dockerfiles to use Mirror Registry"
                echo "8) Restore ALL backed-up system configurations"
                echo -e "${BRED}0) Back${NC}\n"
                local mc=""
                read_input "Select [0-8]: " mc "0"
                case "$mc" in
                    1) install_mirra_cli; pause_screen ;;
                    2) update_mirra_cli; pause_screen ;;
                    3) uninstall_mirra_cli; pause_screen ;;
                    4)
                        local ep=""
                        read_input "Export path [mirra-profile.json]: " ep "mirra-profile.json"
                        export_profile "${ep:-mirra-profile.json}"
                        pause_screen
                        ;;
                    5)
                        local ip_path=""
                        read_input "Import profile JSON path: " ip_path ""
                        [ -n "$ip_path" ] && import_profile "$ip_path"
                        pause_screen
                        ;;
                    6)
                        echo "1) Enable Watchdog  2) Disable Watchdog  3) Configure Telegram Alert  4) Run Check Now"
                        local wc=""
                        read_input "Select [1-4]: " wc "0"
                        case "$wc" in
                            1) enable_watchdog "AUTO" ;;
                            2) disable_watchdog ;;
                            3)
                                local tok="" cid="" api_b="" tg_p=""
                                read_input "Telegram Bot Token: " tok ""
                                read_input "Telegram Chat ID: " cid ""
                                read_input "Custom API Base / CF Worker URL [https://api.telegram.org]: " api_b "https://api.telegram.org"
                                read_input "Optional Proxy URL (e.g. socks5://127.0.0.1:40000) [none]: " tg_p ""
                                configure_telegram_notify "$tok" "$cid" "AUTO" "${api_b:-https://api.telegram.org}" "$tg_p"
                                ;;
                            4) run_watchdog_check ;;
                        esac
                        pause_screen
                        ;;
                    7)
                        local pdir=""
                        read_input "Project directory path [.]: " pdir "."
                        patch_project_dockerfiles "${pdir:-.}"
                        pause_screen
                        ;;
                    8) restore_all_configs; pause_screen ;;
                esac
                ;;
            0) echo -e "\n${YELLOW}Exiting Mirra. Goodbye!${NC}"; exit 0 ;;
            *) log_err "Invalid choice!"; sleep 1 ;;
        esac
    done
}

show_help() {
    cat <<EOF
Mirra v${MIRRA_VERSION} - Automated Mirror, DNS & Anti-Sanction Helper

Usage: mirra [OPTIONS]

Modes (non-interactive when any action flag is passed):
  --auto [iran|global|auto]   Auto-configure OS, Docker, DevTools & DNS (default: auto-detect)
  --pkg <iran|global>         Benchmark & apply OS package manager mirror
  --docker <iran|global>      Benchmark & apply Docker registry mirrors
  --devtools <iran|global>    Configure Pip/uv, NPM/Yarn/pnpm/Bun, Go, Cargo, Composer
  --dns <iran|global|dhcp>      Configure Anti-Sanction / Global DNS or revert to DHCP
  --dns-custom <IP1> [IP2]      Apply custom primary (and optional secondary) IPv4 DNS
  --dns-dhcp                    Revert DNS settings back to automatic DHCP / ISP DNS
  --flush-dns                   Flush local DNS resolver cache (resolvectl / nscd / nmcli)
  --dot <cf|quad9|google|adguard|nextdns|off>  Configure DNS-over-TLS via systemd-resolved
  --proxy <URL>                 Set Global HTTP/HTTPS/SOCKS5 proxy
  --docker-proxy <URL|clear>    Set/clear selective proxy ONLY for Docker
  --apt-proxy <URL|clear>       Set/clear selective proxy ONLY for APT
  --clear-proxy                 Remove all Mirra proxy configurations
  --ipv6 <disable|enable>       Disable IPv6 & force APT IPv4, or re-enable IPv6
  --mtu <VALUE|auto>            Auto-probe optimal Path MTU or set explicit MTU
  --bbr <enable|disable>        Enable or disable TCP BBR congestion control
  --sync-time                   Sync NTP clock (ir.pool.ntp.org) & update CA certs
  --export <FILE>               Export active mirror/DNS profile to JSON
  --import <FILE>               Apply mirror/DNS profile from JSON
  --patch-project <DIR>         Rewrite Docker Hub FROM lines in project Dockerfiles
  --enable-watchdog [REGION]    Install daily systemd timer to auto-heal dead mirrors
  --disable-watchdog            Disable and remove Mirra watchdog systemd timer
  --run-watchdog                Run a single mirror health & auto-rotate check now
  --notify-telegram <TOK> <ID>  Save Telegram Bot credentials for watchdog alerts
  --telegram-api <URL>          Custom Telegram API / Cloudflare Worker URL (optional)
  --telegram-proxy <URL>        Proxy URL for Telegram alerts (e.g., socks5://127.0.0.1:40000)
  --diagnostics                 Run multi-layer network, hijack & clock diagnostics
  --status                      Show current system & mirror status
  --restore-all                 Restore all original files backed up by Mirra
  --install                     Install 'mirra' command globally to /usr/local/bin/mirra
  --update                      Update Mirra from GitHub
  --uninstall                   Uninstall Mirra binary and shared modules

Modifiers:
  -y, --yes                   Skip confirmation prompts
  --dry-run                   Preview changes without modifying any files
  --json                      Output JSON for --status and --diagnostics
  --offline                   Use built-in/local mirrors.json without fetching GitHub
  -v, --version               Show version
  -h, --help                  Show this help message
EOF
}

parse_cli_and_run() {
    local action=""
    local action_arg="AUTO"
    local action_arg2=""
    local tg_api_arg="https://api.telegram.org"
    local tg_proxy_arg=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes)
                AUTO_YES=1
                NON_INTERACTIVE=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --offline)
                MIRRA_OFFLINE=1
                ;;
            --json)
                JSON_OUTPUT=1
                ;;
            --auto)
                action="auto"
                if [ "${2:-}" = "iran" ] || [ "${2:-}" = "IRAN" ]; then
                    action_arg="IRAN"; shift
                elif [ "${2:-}" = "global" ] || [ "${2:-}" = "GLOBAL" ]; then
                    action_arg="GLOBAL"; shift
                elif [ "${2:-}" = "auto" ] || [ "${2:-}" = "AUTO" ]; then
                    action_arg="AUTO"; shift
                fi
                NON_INTERACTIVE=1
                ;;
            --pkg)
                action="pkg"
                action_arg=$(echo "${2:-IRAN}" | tr '[:lower:]' '[:upper:]')
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --docker)
                action="docker"
                action_arg=$(echo "${2:-IRAN}" | tr '[:lower:]' '[:upper:]')
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --devtools)
                action="devtools"
                action_arg=$(echo "${2:-IRAN}" | tr '[:lower:]' '[:upper:]')
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --dns)
                action="dns"
                action_arg=$(echo "${2:-IRAN}" | tr '[:lower:]' '[:upper:]')
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --dns-custom)
                action="dns-custom"
                action_arg="${2:-}"
                shift || true
                if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                    action_arg2="${2}"
                    shift
                fi
                NON_INTERACTIVE=1
                ;;
            --dns-dhcp)
                action="dns-dhcp"
                NON_INTERACTIVE=1
                ;;
            --flush-dns)
                action="flush-dns"
                NON_INTERACTIVE=1
                ;;
            --proxy)
                action="proxy"
                action_arg="${2:-}"
                shift || true
                NON_INTERACTIVE=1
                ;;
            --clear-proxy)
                action="clear-proxy"
                NON_INTERACTIVE=1
                ;;
            --ipv6)
                action="ipv6"
                action_arg="${2:-disable}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --mtu)
                action="mtu"
                action_arg="${2:-auto}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --export)
                action="export"
                action_arg="${2:-mirra-profile.json}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --dot)
                action="dot"
                action_arg="${2:-cloudflare}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --docker-proxy)
                action="docker-proxy"
                action_arg="${2:-clear}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --apt-proxy)
                action="apt-proxy"
                action_arg="${2:-clear}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --bbr)
                action="bbr"
                action_arg="${2:-enable}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --sync-time)
                action="sync-time"
                NON_INTERACTIVE=1
                ;;
            --patch-project)
                action="patch-project"
                action_arg="${2:-.}"
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --enable-watchdog)
                action="enable-watchdog"
                action_arg=$(echo "${2:-AUTO}" | tr '[:lower:]' '[:upper:]')
                [ -n "${2:-}" ] && [[ "${2}" != -* ]] && shift
                NON_INTERACTIVE=1
                ;;
            --disable-watchdog)
                action="disable-watchdog"
                NON_INTERACTIVE=1
                ;;
            --run-watchdog)
                action="run-watchdog"
                NON_INTERACTIVE=1
                ;;
            --notify-telegram)
                action="notify-telegram"
                action_arg="${2:-}"
                action_arg2="${3:-}"
                shift 2 || true
                NON_INTERACTIVE=1
                ;;
            --telegram-api)
                tg_api_arg="${2:-https://api.telegram.org}"
                shift || true
                ;;
            --telegram-proxy)
                tg_proxy_arg="${2:-}"
                shift || true
                ;;
            --uninstall)
                action="uninstall"
                NON_INTERACTIVE=1
                ;;
            --import)
                action="import"
                action_arg="${2:-}"
                shift || true
                NON_INTERACTIVE=1
                ;;
            --diagnostics)
                action="diagnostics"
                NON_INTERACTIVE=1
                ;;
            --status)
                action="status"
                NON_INTERACTIVE=1
                ;;
            --restore-all)
                action="restore-all"
                NON_INTERACTIVE=1
                ;;
            --install)
                action="install"
                NON_INTERACTIVE=1
                ;;
            --update)
                action="update"
                NON_INTERACTIVE=1
                ;;
            -v|--version)
                echo "Mirra v${MIRRA_VERSION}"
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_err "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift || break
    done

    detect_os
    load_mirrors_config

    case "$action" in
        "")
            check_root
            main_menu
            ;;
        status)
            print_status
            ;;
        diagnostics)
            robust_network_check
            ;;
        auto)
            check_root
            execute_one_click "$action_arg"
            ;;
        pkg)
            check_root
            configure_pkg_auto "$action_arg"
            ;;
        docker)
            check_root
            configure_docker_auto "$action_arg"
            ;;
        devtools)
            check_root
            configure_devtools_auto "$action_arg"
            ;;
        dns)
            check_root
            if [ "$action_arg" = "DHCP" ]; then
                unset_dns_dhcp
            else
                configure_dns_auto "$action_arg"
            fi
            ;;
        dns-custom)
            check_root
            apply_custom_dns "$action_arg" "$action_arg2"
            ;;
        dns-dhcp)
            check_root
            unset_dns_dhcp
            ;;
        flush-dns)
            check_root
            flush_dns_cache
            ;;
        proxy)
            check_root
            apply_system_proxy "$action_arg"
            ;;
        clear-proxy)
            check_root
            clear_system_proxy
            ;;
        ipv6)
            check_root
            apply_ipv6_state "$action_arg"
            ;;
        mtu)
            check_root
            optimize_mtu "$action_arg"
            ;;
        export)
            export_profile "$action_arg"
            ;;
        dot)
            check_root
            apply_dns_dot "$action_arg"
            ;;
        docker-proxy)
            check_root
            apply_docker_proxy_only "$action_arg"
            ;;
        apt-proxy)
            check_root
            apply_apt_proxy_only "$action_arg"
            ;;
        bbr)
            check_root
            apply_bbr_state "$action_arg"
            ;;
        sync-time)
            check_root
            sync_server_time
            ;;
        patch-project)
            patch_project_dockerfiles "$action_arg"
            ;;
        enable-watchdog)
            check_root
            enable_watchdog "$action_arg"
            ;;
        disable-watchdog)
            check_root
            disable_watchdog
            ;;
        run-watchdog)
            check_root
            run_watchdog_check
            ;;
        notify-telegram)
            check_root
            configure_telegram_notify "$action_arg" "$action_arg2" "AUTO" "$tg_api_arg" "$tg_proxy_arg"
            ;;
        uninstall)
            uninstall_mirra_cli
            ;;
        import)
            check_root
            import_profile "$action_arg"
            ;;
        restore-all)
            restore_all_configs
            ;;
        install)
            install_mirra_cli
            ;;
        update)
            update_mirra_cli
            ;;
    esac
}

load_modules
parse_cli_and_run "$@"
