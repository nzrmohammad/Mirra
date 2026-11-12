#!/usr/bin/env bash
# Mirra - OS Package Manager Mirror Configuration (Ubuntu, Debian, Alpine, RHEL/DNF, Arch)
# shellcheck disable=SC2034,SC2154

APT_LEGACY_FILE="/etc/apt/sources.list"
APT_UBUNTU_DEB822="/etc/apt/sources.list.d/ubuntu.sources"
APT_DEBIAN_DEB822="/etc/apt/sources.list.d/debian.sources"
ALPINE_REPOS_FILE="/etc/apk/repositories"
ARCH_MIRRORLIST_FILE="/etc/pacman.d/mirrorlist"

_get_apt_mirror_list() {
    local region="$1"
    if [ "$OS_ID" = "debian" ]; then
        if [ "$region" = "IRAN" ]; then
            echo "APT_DEBIAN_IRAN"
        else
            echo "APT_DEBIAN_GLOBAL"
        fi
    else
        if [ "$OS_ARCH" = "arm64" ] || [ "$OS_ARCH" = "armhf" ]; then
            if [ "$region" = "GLOBAL" ]; then
                echo "APT_UBUNTU_PORTS"
                return
            fi
        fi
        if [ "$region" = "IRAN" ]; then
            echo "APT_UBUNTU_IRAN"
        else
            echo "APT_UBUNTU_GLOBAL"
        fi
    fi
}

apply_apt_mirror() {
    local selected_mirror="$1"
    selected_mirror="${selected_mirror%/}/"
    local codename="${OS_CODENAME:-}"

    if [ -z "$codename" ]; then
        log_err "Could not detect OS codename from /etc/os-release or lsb_release. Aborting APT write."
        return 1
    fi

    if [ "$OS_ID" = "debian" ]; then
        local components="main contrib non-free"
        if [[ "$codename" =~ ^(bookworm|trixie|sid)$ ]]; then
            components="main contrib non-free non-free-firmware"
        fi
        local sec_uri="http://security.debian.org/debian-security"
        if [[ "$selected_mirror" == *"arvancloud"* ]]; then
            sec_uri="http://mirror.arvancloud.ir/debian-security"
        fi

        if [ -f "$APT_DEBIAN_DEB822" ]; then
            backup_file "$APT_DEBIAN_DEB822"
            local content
            content=$(cat <<EOF
# Configured by Mirra
Types: deb
URIs: ${selected_mirror}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${sec_uri}
Suites: ${codename}-security
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
)
            write_file_safe "$APT_DEBIAN_DEB822" "$content"
            log_ok "Applied Debian DEB822 mirror (${selected_mirror}) to ${APT_DEBIAN_DEB822}"
        else
            backup_file "$APT_LEGACY_FILE"
            local content
            content=$(cat <<EOF
# Configured by Mirra
deb ${selected_mirror} ${codename} ${components}
deb ${selected_mirror} ${codename}-updates ${components}
deb ${selected_mirror} ${codename}-backports ${components}
deb ${sec_uri} ${codename}-security ${components}
EOF
)
            write_file_safe "$APT_LEGACY_FILE" "$content"
            log_ok "Applied Debian APT mirror (${selected_mirror}) to ${APT_LEGACY_FILE}"
        fi
    else
        # Ubuntu & derivatives
        if [ -f "$APT_UBUNTU_DEB822" ]; then
            backup_file "$APT_UBUNTU_DEB822"
            local content
            content=$(cat <<EOF
# Configured by Mirra
Types: deb
URIs: ${selected_mirror}
Suites: ${codename} ${codename}-updates ${codename}-backports ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
)
            write_file_safe "$APT_UBUNTU_DEB822" "$content"
            log_ok "Applied Ubuntu DEB822 mirror (${selected_mirror}) to ${APT_UBUNTU_DEB822}"
        else
            backup_file "$APT_LEGACY_FILE"
            local content
            content=$(cat <<EOF
# Configured by Mirra
deb ${selected_mirror} ${codename} main restricted universe multiverse
deb ${selected_mirror} ${codename}-updates main restricted universe multiverse
deb ${selected_mirror} ${codename}-backports main restricted universe multiverse
deb ${selected_mirror} ${codename}-security main restricted universe multiverse
EOF
)
            write_file_safe "$APT_LEGACY_FILE" "$content"
            log_ok "Applied Ubuntu APT mirror (${selected_mirror}) to ${APT_LEGACY_FILE}"
        fi
    fi
}

apply_alpine_mirror() {
    local selected_mirror="$1"
    selected_mirror="${selected_mirror%/}"
    local alpine_branch="latest-stable"
    if [ -r /etc/alpine-release ]; then
        local ver
        ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)
        if [ -n "$ver" ]; then
            alpine_branch="v${ver}"
        fi
    fi
    backup_file "$ALPINE_REPOS_FILE"
    local content
    content=$(cat <<EOF
# Configured by Mirra
${selected_mirror}/${alpine_branch}/main
${selected_mirror}/${alpine_branch}/community
EOF
)
    write_file_safe "$ALPINE_REPOS_FILE" "$content"
    log_ok "Applied Alpine APK mirror (${selected_mirror}/${alpine_branch})"
}

apply_arch_mirror() {
    local selected_mirror="$1"
    selected_mirror="${selected_mirror%/}"
    backup_file "$ARCH_MIRRORLIST_FILE"
    local content
    content=$(cat <<EOF
# Configured by Mirra
Server = ${selected_mirror}/\$repo/os/\$arch
EOF
)
    write_file_safe "$ARCH_MIRRORLIST_FILE" "$content"
    log_ok "Applied Arch pacman mirror (${selected_mirror})"
}

apply_dnf_mirror() {
    local region="$1"
    local mirror_base=""
    if [ "$region" = "IRAN" ]; then
        if benchmark_mirrors DNF_IRAN "" "http" 1; then
            mirror_base="${SORTED_MIRRORS[0]%/}"
        else
            mirror_base="${DNF_IRAN[0]%/}"
        fi
    fi

    if [ ! -d /etc/yum.repos.d ]; then
        log_warn "/etc/yum.repos.d not found."
        return 1
    fi

    local repo_file
    for repo_file in /etc/yum.repos.d/*.repo; do
        [ -f "$repo_file" ] || continue
        backup_file "$repo_file"
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would update mirror URLs in $repo_file for mode $region (${mirror_base:-official})"
            continue
        fi
        if [ "$region" = "IRAN" ]; then
            sed -i \
                -e 's|^mirrorlist=|#mirrorlist=|g' \
                -e 's|^metalink=|#metalink=|g' \
                -e 's|^#baseurl=http://mirror.centos.org|baseurl='"${mirror_base}"'/centos|g' \
                -e 's|^#baseurl=https\?://mirrors.rockylinux.org/mirrorlist|baseurl='"${mirror_base}"'/rocky|g' \
                -e 's|^#baseurl=https\?://dl.rockylinux.org/\$contentdir|baseurl='"${mirror_base}"'/rocky|g' \
                -e 's|^#baseurl=https\?://repo.almalinux.org|baseurl='"${mirror_base}"'/almalinux|g' \
                -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl='"${mirror_base}"'/fedora|g' \
                -e 's|http://dl.fedoraproject.org/pub/epel|'"${mirror_base}"'/epel|g' \
                -e 's|https://download.fedoraproject.org/pub/epel|'"${mirror_base}"'/epel|g' \
                "$repo_file"
        else
            sed -i \
                -e 's|^#mirrorlist=|mirrorlist=|g' \
                -e 's|^#metalink=|metalink=|g' \
                "$repo_file"
        fi
    done
    log_ok "Updated DNF/YUM repo definitions for ${region} (${mirror_base:-official})."
}

# Smart broken APT source cleaner: inspects real apt-get update failures and disables ONLY failing files
fix_apt_broken_sources() {
    if [ "$PKG_FAMILY" != "apt" ]; then
        log_warn "This tool is only applicable to Debian/Ubuntu (APT) systems."
        return 1
    fi

    echo -e "${YELLOW}[ Tool: Smart Broken APT Source Detector ]${NC}\n"
    echo "  • Runs 'apt-get update' and inspects which repository URLs fail (404 / GPG / unreachable)."
    echo "  • Safely backs up and disables ONLY the failing third-party files in /etc/apt/sources.list.d/."
    echo ""
    if ! confirm_action "Scan for broken third-party APT sources?"; then
        log_warn "Operation canceled."
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would inspect 'apt-get update' output and disable failing .list/.sources files."
        return 0
    fi

    log_info "Running apt-get update check..."
    local apt_err_log
    apt_err_log=$(apt-get update 2>&1 || true)

    local failed_hosts=()
    mapfile -t failed_hosts < <(echo "$apt_err_log" \
        | grep -E '^(Err:|E:|W:)' \
        | grep -oE 'https?://[^/[:space:]]+' \
        | sort -u || true)

    if [ "${#failed_hosts[@]}" -eq 0 ]; then
        log_ok "No broken third-party APT repository URLs detected!"
        return 0
    fi

    log_warn "Detected failing repository hosts:"
    local h
    for h in "${failed_hosts[@]}"; do
        echo "  - $h"
    done

    local disabled=0
    local file
    for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$file" ] || continue
        # Never disable the main distro DEB822 file
        if [ "$file" = "$APT_UBUNTU_DEB822" ] || [ "$file" = "$APT_DEBIAN_DEB822" ]; then
            continue
        fi
        local matched=0
        for h in "${failed_hosts[@]}"; do
            if grep -qF "$h" "$file" 2>/dev/null; then
                matched=1
                break
            fi
        done
        if [ "$matched" -eq 1 ]; then
            backup_file "$file"
            mv "$file" "${file}.disabled_mirra"
            log_ok "Disabled failing third-party source: $file"
            disabled=$((disabled + 1))
        fi
    done

    if [ "$disabled" -gt 0 ]; then
        log_info "Refreshing apt index..."
        apt-get clean && apt-get update
    else
        log_warn "Failures were not matched to removable third-party files in /etc/apt/sources.list.d/."
    fi
}

# Switch sanctioned third-party APT repos (Docker CE, Kubernetes, NodeSource, PostgreSQL) to accessible mirrors
fix_third_party_apt_mirrors() {
    local apt_d_dir="${1:-/etc/apt/sources.list.d}"
    if [ "$PKG_FAMILY" != "apt" ]; then
        return 0
    fi
    if [ ! -d "$apt_d_dir" ]; then
        return 0
    fi

    local f
    local found=0
    for f in "$apt_d_dir"/*.list "$apt_d_dir"/*.sources; do
        [ -f "$f" ] || continue
        local changed=0
        if grep -q "download.docker.com" "$f" 2>/dev/null; then
            backup_file "$f"
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would replace download.docker.com with mirror.arvancloud.ir/docker-ce in $f"
            else
                sed -i 's|https\?://download.docker.com|https://mirror.arvancloud.ir/docker-ce|g' "$f"
                log_ok "Updated Docker CE APT repo in $f"
            fi
            changed=1
        fi
        if grep -q "pkgs.k8s.io" "$f" 2>/dev/null; then
            [ "$changed" -eq 0 ] && backup_file "$f"
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would replace pkgs.k8s.io in $f"
            else
                sed -i 's|https\?://pkgs.k8s.io/core:/stable:/|https://mirrors.aliyun.com/kubernetes-new/core/stable/|g' "$f"
                log_ok "Updated Kubernetes APT repo in $f"
            fi
            changed=1
        fi
        if grep -q "deb.nodesource.com" "$f" 2>/dev/null; then
            [ "$changed" -eq 0 ] && backup_file "$f"
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would replace deb.nodesource.com in $f"
            else
                sed -i 's|https\?://deb.nodesource.com|https://mirrors.tuna.tsinghua.edu.cn/nodesource/deb|g' "$f"
                log_ok "Updated NodeSource APT repo in $f"
            fi
            changed=1
        fi
        if grep -q "apt.postgresql.org" "$f" 2>/dev/null; then
            [ "$changed" -eq 0 ] && backup_file "$f"
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would replace apt.postgresql.org in $f"
            else
                sed -i 's|https\?://apt.postgresql.org/pub/repos/apt|https://mirrors.tuna.tsinghua.edu.cn/postgresql/repos/apt|g' "$f"
                log_ok "Updated PostgreSQL APT repo in $f"
            fi
            changed=1
        fi
        [ "$changed" -eq 1 ] && found=1
    done
    if [ "$found" -eq 0 ]; then
        log_info "No sanctioned third-party APT entries (Docker/K8s/NodeSource/Postgres) found."
    fi
}

configure_pkg_auto() {
    local region="$1"
    case "$PKG_FAMILY" in
        apt)
            local arr_name
            arr_name=$(_get_apt_mirror_list "$region")
            local suffix=""
            if [ -n "$OS_CODENAME" ]; then
                suffix="dists/${OS_CODENAME}/Release"
            fi
            if benchmark_mirrors "$arr_name" "$suffix" "http" 1; then
                apply_apt_mirror "${SORTED_MIRRORS[0]}"
            else
                log_err "No reachable ${region} APT mirrors found."
                return 1
            fi
            ;;
        apk)
            local arr_name="ALPINE_GLOBAL"
            [ "$region" = "IRAN" ] && arr_name="ALPINE_IRAN"
            if benchmark_mirrors "$arr_name" "" "http" 1; then
                apply_alpine_mirror "${SORTED_MIRRORS[0]}"
            else
                log_err "No reachable ${region} Alpine mirrors found."
                return 1
            fi
            ;;
        dnf)
            apply_dnf_mirror "$region"
            ;;
        pacman)
            local arr_name="ARCH_GLOBAL"
            [ "$region" = "IRAN" ] && arr_name="ARCH_IRAN"
            if benchmark_mirrors "$arr_name" "" "http" 1; then
                apply_arch_mirror "${SORTED_MIRRORS[0]}"
            else
                log_err "No reachable ${region} Arch mirrors found."
                return 1
            fi
            ;;
        *)
            log_warn "Unsupported package family ($PKG_FAMILY) for OS ${OS_ID}."
            return 1
            ;;
    esac
}

configure_pkg_interactive() {
    local region="$1"
    case "$PKG_FAMILY" in
        apt)
            local arr_name
            arr_name=$(_get_apt_mirror_list "$region")
            local suffix=""
            [ -n "$OS_CODENAME" ] && suffix="dists/${OS_CODENAME}/Release"
            if ! benchmark_mirrors "$arr_name" "$suffix" "http" 0; then
                log_err "All selected APT mirrors are unreachable."
                pause_screen
                return
            fi

            echo -e "\n${BOLD}Select an APT mirror (Sorted by lowest latency):${NC}"
            local max_check=3
            local i
            for i in "${!SORTED_MIRRORS[@]}"; do
                local extra=""
                if [ "$i" -lt "$max_check" ]; then
                    local fresh=""
                    local spd=""
                    fresh=$(check_apt_freshness "${SORTED_MIRRORS[$i]}" "$OS_CODENAME")
                    if [ -n "$suffix" ]; then
                        spd=$(measure_throughput "${SORTED_MIRRORS[$i]%/}/${suffix}")
                    fi
                    local info_parts=()
                    [ -n "$spd" ] && [ "$spd" != "N/A" ] && info_parts+=("$spd")
                    [ -n "$fresh" ] && info_parts+=("$fresh")
                    if [ "${#info_parts[@]}" -gt 0 ]; then
                        local joined=""
                        printf -v joined '%s, ' "${info_parts[@]}"
                        extra=" ${GRAY}[${joined%, }]${NC}"
                    fi
                fi
                echo -e "  ${CYAN}$((i + 1)))${NC} ${SORTED_MIRRORS[$i]} ${GREEN}(${SORTED_LATENCIES[$i]} ms)${NC}${extra}"
            done
            echo -e "  ${BRED}0) Cancel${NC}\n"

            local m_choice=""
            read_input "Enter selection [0-${#SORTED_MIRRORS[@]}]: " m_choice "0"
            if [ "$m_choice" = "0" ]; then
                log_warn "Operation canceled."
            elif [[ "$m_choice" =~ ^[0-9]+$ ]] && [ "$m_choice" -ge 1 ] && [ "$m_choice" -le "${#SORTED_MIRRORS[@]}" ]; then
                apply_apt_mirror "${SORTED_MIRRORS[$((m_choice - 1))]}"
            else
                log_err "Invalid selection."
            fi
            pause_screen
            ;;
        apk)
            local arr_name="ALPINE_GLOBAL"
            [ "$region" = "IRAN" ] && arr_name="ALPINE_IRAN"
            if ! benchmark_mirrors "$arr_name" "" "http" 0; then
                log_err "All selected Alpine mirrors are unreachable."
                pause_screen
                return
            fi
            echo -e "\n${BOLD}Select an Alpine APK mirror:${NC}"
            local i
            for i in "${!SORTED_MIRRORS[@]}"; do
                echo -e "  ${CYAN}$((i + 1)))${NC} ${SORTED_MIRRORS[$i]} ${GREEN}(${SORTED_LATENCIES[$i]} ms)${NC}"
            done
            echo -e "  ${BRED}0) Cancel${NC}\n"
            local m_choice=""
            read_input "Enter selection [0-${#SORTED_MIRRORS[@]}]: " m_choice "0"
            if [[ "$m_choice" =~ ^[0-9]+$ ]] && [ "$m_choice" -ge 1 ] && [ "$m_choice" -le "${#SORTED_MIRRORS[@]}" ]; then
                apply_alpine_mirror "${SORTED_MIRRORS[$((m_choice - 1))]}"
            fi
            pause_screen
            ;;
        dnf)
            apply_dnf_mirror "$region"
            pause_screen
            ;;
        pacman)
            local arr_name="ARCH_GLOBAL"
            [ "$region" = "IRAN" ] && arr_name="ARCH_IRAN"
            if ! benchmark_mirrors "$arr_name" "" "http" 0; then
                log_err "All selected Arch mirrors are unreachable."
                pause_screen
                return
            fi
            echo -e "\n${BOLD}Select an Arch mirror:${NC}"
            local i
            for i in "${!SORTED_MIRRORS[@]}"; do
                echo -e "  ${CYAN}$((i + 1)))${NC} ${SORTED_MIRRORS[$i]} ${GREEN}(${SORTED_LATENCIES[$i]} ms)${NC}"
            done
            echo -e "  ${BRED}0) Cancel${NC}\n"
            local m_choice=""
            read_input "Enter selection [0-${#SORTED_MIRRORS[@]}]: " m_choice "0"
            if [[ "$m_choice" =~ ^[0-9]+$ ]] && [ "$m_choice" -ge 1 ] && [ "$m_choice" -le "${#SORTED_MIRRORS[@]}" ]; then
                apply_arch_mirror "${SORTED_MIRRORS[$((m_choice - 1))]}"
            fi
            pause_screen
            ;;
        *)
            log_err "Package family '$PKG_FAMILY' is not supported yet."
            pause_screen
            ;;
    esac
}

menu_system_os() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 1: OS Package Manager (${OS_ID} / ${PKG_FAMILY}) ]${NC}\n"
        echo "1) Benchmark & apply Iranian OS mirror"
        echo "2) Benchmark & apply Global / Official OS mirror"
        echo "3) View current package manager sources"
        echo "4) Restore original package manager sources from backup"
        echo "5) Refresh package index (apt/apk/dnf/pacman update)"
        echo "6) Smart fix broken third-party APT sources"
        echo "7) Switch third-party APT repos (Docker, K8s, NodeSource, Postgres)"
        echo -e "${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-7]: " choice "0"

        case "$choice" in
            1) configure_pkg_interactive "IRAN" ;;
            2) configure_pkg_interactive "GLOBAL" ;;
            3)
                echo -e "\n${BLUE}--- Current Package Sources ---${NC}"
                case "$PKG_FAMILY" in
                    apt)
                        if [ -f "$APT_UBUNTU_DEB822" ]; then
                            cat "$APT_UBUNTU_DEB822"
                        elif [ -f "$APT_DEBIAN_DEB822" ]; then
                            cat "$APT_DEBIAN_DEB822"
                        else
                            cat "$APT_LEGACY_FILE" 2>/dev/null || log_warn "Not found."
                        fi
                        ;;
                    apk) cat "$ALPINE_REPOS_FILE" 2>/dev/null || log_warn "Not found." ;;
                    pacman) cat "$ARCH_MIRRORLIST_FILE" 2>/dev/null || log_warn "Not found." ;;
                    dnf) head -n 30 /etc/yum.repos.d/*.repo 2>/dev/null || log_warn "Not found." ;;
                esac
                pause_screen
                ;;
            4)
                case "$PKG_FAMILY" in
                    apt) restore_from_manifest "apt" ;;
                    apk) restore_from_manifest "apk" ;;
                    pacman) restore_from_manifest "pacman" ;;
                    dnf) restore_from_manifest "yum.repos.d" ;;
                esac
                pause_screen
                ;;
            5)
                if [ "$DRY_RUN" -eq 1 ]; then
                    log_dry "Would run package index refresh for ${PKG_FAMILY}"
                else
                    case "$PKG_FAMILY" in
                        apt) apt-get clean && apt-get update ;;
                        apk) apk update ;;
                        dnf) dnf makecache ;;
                        pacman) pacman -Sy ;;
                    esac
                fi
                pause_screen
                ;;
            6) fix_apt_broken_sources; pause_screen ;;
            7) fix_third_party_apt_mirrors; pause_screen ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}
