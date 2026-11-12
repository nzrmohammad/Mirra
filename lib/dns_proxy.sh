#!/usr/bin/env bash
# Mirra - Anti-Sanction DNS & System Proxy Manager
# shellcheck disable=SC2034,SC2154

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/99-mirra-dns.conf"
APT_PROXY_FILE="/etc/apt/apt.conf.d/99mirra-proxy"
DOCKER_PROXY_DIR="/etc/systemd/system/docker.service.d"
DOCKER_PROXY_FILE="${DOCKER_PROXY_DIR}/99mirra-proxy.conf"
PROFILE_PROXY_FILE="/etc/profile.d/mirra-proxy.sh"
SYSCTL_IPV6_FILE="/etc/sysctl.d/99-mirra-ipv6.conf"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-mirra-bbr.conf"
TIMESYNCD_DROPIN_FILE="/etc/systemd/timesyncd.conf.d/99-mirra-ntp.conf"
APT_IPV4_FILE="/etc/apt/apt.conf.d/99mirra-ipv4"

_test_single_dns() {
    local name="$1"
    local dns1="$2"
    local dns2="$3"
    local test_domain="registry-1.docker.io"
    local resolved_ip=""
    local t_start t_end ms

    t_start=$(date +%s%3N 2>/dev/null || echo 0)

    if command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short +time=2 +tries=1 @"$dns1" "$test_domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -n1 || true)
    elif command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup -timeout=2 "$test_domain" "$dns1" 2>/dev/null \
            | awk '/^Address:/ && $2 !~ /#/ && $2 !~ /'"$dns1"'/ {print $2; exit}' || true)
    elif command -v python3 >/dev/null 2>&1; then
        # Raw UDP check via timeout / tcp fallback if no dig/nslookup
        timeout 2 bash -c "</dev/tcp/${dns1}/53" 2>/dev/null && resolved_ip="reachable" || resolved_ip=""
    else
        timeout 2 bash -c "</dev/tcp/${dns1}/53" 2>/dev/null && resolved_ip="reachable" || resolved_ip=""
    fi

    t_end=$(date +%s%3N 2>/dev/null || echo 0)
    ms=$((t_end - t_start))
    [ "$ms" -lt 1 ] && ms=1

    if [ -z "$resolved_ip" ]; then
        echo "9999|UNREACHABLE|${name}|${dns1}|${dns2}"
        return 1
    fi

    local status="RESOLVED"
    if [[ "$resolved_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && command -v curl >/dev/null 2>&1; then
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 \
            --resolve "${test_domain}:443:${resolved_ip}" "https://${test_domain}/v2/" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|401)$ ]]; then
            status="BYPASS_OK (${resolved_ip})"
        else
            status="RESOLVED (${resolved_ip}, HTTP ${code})"
        fi
    fi

    echo "${ms}|${status}|${name}|${dns1}|${dns2}"
    return 0
}

benchmark_dns_list() {
    local -n dns_arr="$1"
    DNS_SORTED=()
    log_warn "Testing ${#dns_arr[@]} DNS servers against Docker Hub resolution..."
    echo ""

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=()
    local idx=0
    local entry name dns1 dns2
    for entry in "${dns_arr[@]}"; do
        IFS='|' read -r name dns1 dns2 <<< "$entry"
        (
            _test_single_dns "$name" "$dns1" "$dns2" > "${tmp_dir}/${idx}.res" || true
        ) &
        pids+=($!)
        idx=$((idx + 1))
    done

    local p
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null || true
    done

    local ok_lines=()
    local i
    for ((i = 0; i < idx; i++)); do
        [ -f "${tmp_dir}/${i}.res" ] || continue
        local line
        line=$(cat "${tmp_dir}/${i}.res")
        local ms="${line%%|*}"
        local rest="${line#*|}"
        local status="${rest%%|*}"
        rest="${rest#*|}"
        local name="${rest%%|*}"
        rest="${rest#*|}"
        local d1="${rest%%|*}"
        local d2="${rest#*|}"

        if [ "$ms" -lt 9999 ] 2>/dev/null; then
            echo -e "  • ${BOLD}${name}${NC} (${d1}${d2:+, ${d2}}) ... ${GREEN}${ms} ms${NC} ${GRAY}[${status}]${NC}"
            ok_lines+=("$line")
        else
            echo -e "  • ${BOLD}${name}${NC} (${d1}${d2:+, ${d2}}) ... ${RED}Unreachable${NC}"
        fi
    done

    rm -rf "$tmp_dir"
    if [ "${#ok_lines[@]}" -eq 0 ]; then
        return 1
    fi
    mapfile -t DNS_SORTED < <(printf '%s\n' "${ok_lines[@]}" | sort -t'|' -k1,1n)
    return 0
}

_is_valid_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local o1 o2 o3 o4 oct
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for oct in "$o1" "$o2" "$o3" "$o4"; do
        if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

_write_resolv_conf() {
    local name="$1"
    local dns1="$2"
    local dns2="${3:-}"
    local dns_pair="$dns1"
    [ -n "$dns2" ] && dns_pair="${dns1} ${dns2}"

    backup_file "/etc/resolv.conf"
    local content
    content="# Configured by Mirra (${name})"$'\n'"nameserver ${dns1}"
    [ -n "$dns2" ] && content+=$'\n'"nameserver ${dns2}"
    if [ "$DRY_RUN" -eq 0 ] && [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    write_file_safe "/etc/resolv.conf" "$content"
    log_ok "Applied DNS (${name}: ${dns_pair}) to /etc/resolv.conf."
}

_detect_active_nm_connection() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
        return 0
    fi
    nmcli -t -f NAME,TYPE connection show --active 2>/dev/null \
        | awk -F: '$2 != "loopback" && $2 != "bridge" {print $1; exit}' || true
}

apply_dns_servers() {
    local name="$1"
    local dns1="$2"
    local dns2="${3:-}"
    local target_conn="${4:-}"
    local dns_pair="$dns1"
    [ -n "$dns2" ] && dns_pair="${dns1} ${dns2}"

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        backup_file "$RESOLVED_DROPIN_FILE"
        local content
        content=$(cat <<EOF
# Configured by Mirra (${name})
[Resolve]
DNS=${dns_pair}
FallbackDNS=1.1.1.1 8.8.8.8
EOF
)
        write_file_safe "$RESOLVED_DROPIN_FILE" "$content"
        if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ]; then
            if systemctl restart systemd-resolved 2>/dev/null; then
                log_ok "Applied DNS (${name}: ${dns_pair}) via systemd-resolved."
            else
                log_warn "Wrote ${RESOLVED_DROPIN_FILE}, but could not restart systemd-resolved."
            fi
        elif [ "$DRY_RUN" -eq 0 ]; then
            log_ok "DNS drop-in saved to ${RESOLVED_DROPIN_FILE}."
        else
            log_dry "Would restart systemd-resolved"
        fi
    elif command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local conn="${target_conn:-$(_detect_active_nm_connection)}"
        if [ -z "$conn" ]; then
            log_warn "No active NetworkManager connection found; falling back to /etc/resolv.conf."
        else
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would run: nmcli connection modify \"${conn}\" ipv4.dns \"${dns_pair}\" ipv4.ignore-auto-dns yes && nmcli connection up \"${conn}\""
                return 0
            fi
            if nmcli connection modify "$conn" ipv4.dns "$dns_pair" ipv4.ignore-auto-dns yes 2>/dev/null \
                && nmcli connection up "$conn" >/dev/null 2>&1; then
                log_ok "Applied DNS (${name}: ${dns_pair}) on NetworkManager connection '${conn}'."
                return 0
            fi
            log_warn "nmcli apply failed on '${conn}'; falling back to /etc/resolv.conf."
        fi
        _write_resolv_conf "$name" "$dns1" "$dns2"
    else
        _write_resolv_conf "$name" "$dns1" "$dns2"
    fi
}

apply_custom_dns() {
    local dns1="${1:-}"
    local dns2="${2:-}"
    local conn="${3:-}"
    if [ -z "$dns1" ] || ! _is_valid_ipv4 "$dns1"; then
        log_err "Invalid primary IPv4 DNS address: '${dns1}'"
        return 1
    fi
    if [ -n "$dns2" ] && ! _is_valid_ipv4 "$dns2"; then
        log_err "Invalid secondary IPv4 DNS address: '${dns2}'"
        return 1
    fi
    apply_dns_servers "Custom" "$dns1" "$dns2" "$conn"
}

restore_dns_config() {
    if [ -f "$RESOLVED_DROPIN_FILE" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${RESOLVED_DROPIN_FILE} and restart systemd-resolved"
        else
            rm -f "$RESOLVED_DROPIN_FILE"
            systemctl restart systemd-resolved 2>/dev/null || true
            log_ok "Removed Mirra systemd-resolved drop-in."
        fi
    fi
    restore_from_manifest "resolv.conf" || true
}

unset_dns_dhcp() {
    local target_conn="${1:-}"
    local did_work=0

    if [ -f "$RESOLVED_DROPIN_FILE" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${RESOLVED_DROPIN_FILE} to revert systemd-resolved to DHCP"
        else
            rm -f "$RESOLVED_DROPIN_FILE"
            systemctl restart systemd-resolved 2>/dev/null || true
            log_ok "Removed Mirra systemd-resolved drop-in (reverted to DHCP/ISP DNS)."
        fi
        did_work=1
    fi

    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local conn="${target_conn:-$(_detect_active_nm_connection)}"
        if [ -n "$conn" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_dry "Would run: nmcli connection modify \"${conn}\" ipv4.dns \"\" ipv4.ignore-auto-dns no && nmcli connection up \"${conn}\""
            else
                if nmcli connection modify "$conn" ipv4.dns "" ipv4.ignore-auto-dns no 2>/dev/null; then
                    nmcli connection up "$conn" >/dev/null 2>&1 || true
                    log_ok "Reverted NetworkManager connection '${conn}' to automatic DHCP DNS."
                fi
            fi
            did_work=1
        fi
    fi

    if [ "$did_work" -eq 0 ]; then
        restore_from_manifest "resolv.conf" || log_info "No Mirra DNS overrides active; DHCP/system defaults remain intact."
    fi
}

flush_dns_cache() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would flush local DNS resolver caches (resolvectl / systemd-resolve / nscd / nmcli)"
        return 0
    fi
    local flushed=0
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches 2>/dev/null && flushed=1 || true
    elif command -v systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches 2>/dev/null && flushed=1 || true
    fi
    if command -v nscd >/dev/null 2>&1; then
        nscd -i hosts 2>/dev/null && flushed=1 || true
    fi
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        nmcli general reload 2>/dev/null && flushed=1 || true
    fi
    if [ "$flushed" -eq 1 ]; then
        log_ok "System DNS cache flushed cleanly."
    else
        log_info "No local DNS caching daemon detected (nothing cached locally to flush)."
    fi
}

show_dns_overview() {
    echo -e "\n${BLUE}--- Active Interfaces ---${NC}"
    if command -v nmcli >/dev/null 2>&1; then
        nmcli -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null || true
    elif command -v ip >/dev/null 2>&1; then
        ip -brief addr 2>/dev/null || true
    fi
    if command -v resolvectl >/dev/null 2>&1; then
        echo -e "\n${BLUE}--- resolvectl dns ---${NC}"
        resolvectl dns 2>/dev/null || true
    fi
    echo -e "\n${BLUE}--- /etc/resolv.conf ---${NC}"
    cat /etc/resolv.conf 2>/dev/null || true
    if [ -f "$RESOLVED_DROPIN_FILE" ]; then
        echo -e "\n${BLUE}--- ${RESOLVED_DROPIN_FILE} ---${NC}"
        cat "$RESOLVED_DROPIN_FILE"
    fi
}

configure_dns_auto() {
    local region="$1"
    local arr_name="DNS_GLOBAL"
    [ "$region" = "IRAN" ] && arr_name="DNS_IRAN"

    local -n ref="$arr_name"
    local first="${ref[0]}"
    IFS='|' read -r name d1 d2 <<< "$first"
    apply_dns_servers "$name" "$d1" "$d2"
}

apply_system_proxy() {
    local proxy_url="$1"
    if [ -z "$proxy_url" ]; then
        log_err "Proxy URL cannot be empty."
        return 1
    fi

    # 1. Shell environment (/etc/profile.d/mirra-proxy.sh)
    local profile_content
    profile_content=$(cat <<EOF
# Configured by Mirra
export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export all_proxy="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export ALL_PROXY="${proxy_url}"
export no_proxy="localhost,127.0.0.1,::1,.local"
export NO_PROXY="localhost,127.0.0.1,::1,.local"
EOF
)
    write_file_safe "$PROFILE_PROXY_FILE" "$profile_content"

    # 2. APT proxy
    if [ "$PKG_FAMILY" = "apt" ]; then
        local apt_proxy
        apt_proxy=$(cat <<EOF
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
EOF
)
        write_file_safe "$APT_PROXY_FILE" "$apt_proxy"
    fi

    # 3. Docker daemon systemd proxy
    if command -v docker >/dev/null 2>&1; then
        local docker_proxy
        docker_proxy=$(cat <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
)
        write_file_safe "$DOCKER_PROXY_FILE" "$docker_proxy"
        if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
            if systemctl daemon-reload 2>/dev/null && systemctl restart docker 2>/dev/null; then
                log_ok "Docker daemon restarted with proxy."
            else
                log_warn "Docker restart failed after proxy update."
            fi
        fi
    fi

    # 4. Git proxy
    if command -v git >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
        run_as_target_user git config --global http.proxy "$proxy_url" || true
        run_as_target_user git config --global https.proxy "$proxy_url" || true
    fi

    log_ok "System, APT, Docker & Git proxy configured to ${proxy_url}"
    log_info "Run 'source ${PROFILE_PROXY_FILE}' or open a new shell to activate env vars."
}

clear_system_proxy() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would remove Mirra proxy configs (${PROFILE_PROXY_FILE}, ${APT_PROXY_FILE}, ${DOCKER_PROXY_FILE})"
        return 0
    fi
    rm -f "$PROFILE_PROXY_FILE" "$APT_PROXY_FILE" "$DOCKER_PROXY_FILE"
    if command -v systemctl >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
        systemctl daemon-reload && systemctl restart docker 2>/dev/null || true
    fi
    if command -v git >/dev/null 2>&1; then
        run_as_target_user git config --global --unset http.proxy 2>/dev/null || true
        run_as_target_user git config --global --unset https.proxy 2>/dev/null || true
    fi
    log_ok "All Mirra proxy configurations removed."
}

apply_ipv6_state() {
    local action="$1" # disable | enable
    if [ "$action" = "disable" ]; then
        local sysctl_content
        sysctl_content=$(cat <<'EOF'
# Configured by Mirra
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
)
        write_file_safe "$SYSCTL_IPV6_FILE" "$sysctl_content"
        if [ "$PKG_FAMILY" = "apt" ]; then
            write_file_safe "$APT_IPV4_FILE" 'Acquire::ForceIPv4 "true";'
        fi
        if [ "$DRY_RUN" -eq 0 ] && command -v sysctl >/dev/null 2>&1; then
            sysctl -p "$SYSCTL_IPV6_FILE" >/dev/null 2>&1 || true
        fi
        log_ok "IPv6 disabled & APT ForceIPv4 enabled."
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${SYSCTL_IPV6_FILE} and ${APT_IPV4_FILE} and re-enable IPv6"
            return 0
        fi
        rm -f "$SYSCTL_IPV6_FILE" "$APT_IPV4_FILE"
        if command -v sysctl >/dev/null 2>&1; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        fi
        log_ok "IPv6 re-enabled & APT ForceIPv4 removed."
    fi
}

optimize_mtu() {
    local requested="${1:-auto}"
    local iface=""
    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    fi
    if [ -z "$iface" ]; then
        log_err "Could not detect default network interface."
        return 1
    fi

    local target_mtu="$requested"
    if [ "$requested" = "auto" ]; then
        log_info "Probing optimal Path MTU on ${iface} (target: 1.1.1.1)..."
        target_mtu=1500
        local payload
        for payload in 1472 1452 1420 1392 1360 1280; do
            if ping -M "do" -s "$payload" -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
                target_mtu=$((payload + 28))
                break
            fi
        done
        log_ok "Optimal detected Path MTU for ${iface}: ${target_mtu}"
    fi

    if ! [[ "$target_mtu" =~ ^[0-9]+$ ]] || [ "$target_mtu" -lt 576 ] || [ "$target_mtu" -gt 9000 ]; then
        log_err "Invalid MTU value: ${target_mtu}"
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would run: ip link set dev ${iface} mtu ${target_mtu}"
        return 0
    fi

    if ip link set dev "$iface" mtu "$target_mtu" 2>/dev/null; then
        log_ok "Applied MTU ${target_mtu} to interface ${iface}."
    else
        log_err "Failed to set MTU ${target_mtu} on ${iface}."
        return 1
    fi
}

apply_dns_dot() {
    local provider="${1:-cloudflare}"
    provider=$(echo "$provider" | tr '[:upper:]' '[:lower:]')
    if [ "$provider" = "off" ] || [ "$provider" = "disable" ]; then
        restore_dns_config
        return 0
    fi

    local dns_line="" label=""
    case "$provider" in
        cloudflare|cf)
            label="Cloudflare DoT"
            dns_line="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
            ;;
        quad9)
            label="Quad9 DoT"
            dns_line="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net"
            ;;
        google)
            label="Google DoT"
            dns_line="8.8.8.8#dns.google 8.8.4.4#dns.google"
            ;;
        adguard)
            label="AdGuard DoT"
            dns_line="94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com"
            ;;
        nextdns)
            label="NextDNS DoT"
            dns_line="45.90.28.0#dns.nextdns.io 45.90.30.0#dns.nextdns.io"
            ;;
        *)
            log_err "Unsupported DoT provider: ${provider}. Use cloudflare, quad9, google, adguard, nextdns, or off."
            return 1
            ;;
    esac

    backup_file "$RESOLVED_DROPIN_FILE"
    local content
    content=$(cat <<EOF
# Configured by Mirra (${label})
[Resolve]
DNS=${dns_line}
DNSOverTLS=yes
EOF
)
    write_file_safe "$RESOLVED_DROPIN_FILE" "$content"
    if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if systemctl restart systemd-resolved 2>/dev/null; then
            log_ok "DNS-over-TLS (${label}) active via systemd-resolved."
        else
            log_warn "DNS-over-TLS (${label}) config written to ${RESOLVED_DROPIN_FILE}, but systemd-resolved restart failed."
        fi
    else
        log_ok "DNS-over-TLS (${label}) config written to ${RESOLVED_DROPIN_FILE}."
        if ! command -v systemctl >/dev/null 2>&1; then
            log_info "Note: DNS-over-TLS requires systemd-resolved (or a DoH client like dnscrypt-proxy)."
        fi
    fi
}

show_doh_guide() {
    echo -e "\n${YELLOW}[ DNS-over-HTTPS (DoH) & DoT Quick Reference ]${NC}\n"
    echo -e "  ${BOLD}Cloudflare:${NC}  DoH: https://cloudflare-dns.com/dns-query   | DoT: one.one.one.one"
    echo -e "  ${BOLD}Google:${NC}      DoH: https://dns.google/dns-query           | DoT: dns.google"
    echo -e "  ${BOLD}Quad9:${NC}       DoH: https://dns.quad9.net/dns-query        | DoT: dns.quad9.net"
    echo -e "  ${BOLD}AdGuard:${NC}     DoH: https://dns.adguard-dns.com/dns-query  | DoT: dns.adguard-dns.com"
    echo -e "  ${BOLD}NextDNS:${NC}     DoH: https://dns.nextdns.io                 | DoT: dns.nextdns.io"
    echo -e "\n  ${CYAN}Browser Setup:${NC} Chrome/Edge/Firefox -> Settings -> Security -> Use Secure DNS -> Paste DoH URL above."
    echo -e "  ${CYAN}Linux DoH Client:${NC} Install 'cloudflared proxy-dns' or 'dnscrypt-proxy' and point /etc/resolv.conf to 127.0.0.1."
}

apply_apt_proxy_only() {
    local proxy_url="$1"
    if [ "$proxy_url" = "clear" ] || [ "$proxy_url" = "off" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${APT_PROXY_FILE}"
        else
            rm -f "$APT_PROXY_FILE"
            log_ok "APT-only proxy cleared."
        fi
        return 0
    fi
    local apt_proxy
    apt_proxy=$(cat <<EOF
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
EOF
)
    write_file_safe "$APT_PROXY_FILE" "$apt_proxy"
    log_ok "Selective APT proxy set to ${proxy_url} (${APT_PROXY_FILE})."
}

apply_docker_proxy_only() {
    local proxy_url="$1"
    if [ "$proxy_url" = "clear" ] || [ "$proxy_url" = "off" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${DOCKER_PROXY_FILE} and reload Docker"
        else
            rm -f "$DOCKER_PROXY_FILE"
            if command -v systemctl >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
                systemctl daemon-reload && systemctl restart docker 2>/dev/null || true
            fi
            log_ok "Selective Docker proxy cleared."
        fi
        return 0
    fi
    local docker_proxy
    docker_proxy=$(cat <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
)
    write_file_safe "$DOCKER_PROXY_FILE" "$docker_proxy"
    if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
        if systemctl daemon-reload 2>/dev/null && systemctl restart docker 2>/dev/null; then
            log_ok "Selective Docker proxy active (${proxy_url})."
        else
            log_warn "Docker restart failed after selective proxy update."
        fi
    else
        log_ok "Selective Docker proxy config written to ${DOCKER_PROXY_FILE}."
    fi
}

apply_bbr_state() {
    local action="${1:-enable}"
    if [ "$action" = "enable" ]; then
        local content
        content=$(cat <<'EOF'
# Configured by Mirra
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
)
        write_file_safe "$SYSCTL_BBR_FILE" "$content"
        if [ "$DRY_RUN" -eq 0 ]; then
            command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null || true
            if command -v sysctl >/dev/null 2>&1 && sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1; then
                log_ok "TCP BBR congestion control enabled!"
            else
                log_warn "Written ${SYSCTL_BBR_FILE}, but kernel sysctl apply reported an error (container/old kernel?)."
            fi
        fi
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${SYSCTL_BBR_FILE}"
            return 0
        fi
        rm -f "$SYSCTL_BBR_FILE"
        command -v sysctl >/dev/null 2>&1 && sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
        log_ok "TCP BBR disabled (reverted to cubic)."
    fi
}

sync_server_time() {
    local content
    content=$(cat <<'EOF'
# Configured by Mirra
[Time]
NTP=ir.pool.ntp.org 0.pool.ntp.org
FallbackNTP=time.cloudflare.com pool.ntp.org
EOF
)
    write_file_safe "$TIMESYNCD_DROPIN_FILE" "$content"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would restart systemd-timesyncd and refresh ca-certificates"
        return 0
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi
    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null 2>&1 || true
    fi
    log_ok "NTP time sync (ir.pool.ntp.org) and CA certificates refreshed."
}

menu_dns_proxy() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 4: DNS, DoT/DoH, NetworkManager, Proxy, BBR, IPv6 & MTU ]${NC}\n"
        echo "1) Benchmark & apply Iranian Anti-Sanction DNS (Shecan, 403, Begzar, Radar, Shelter...)"
        echo "2) Benchmark & apply Global DNS (Cloudflare, Google, Quad9, OpenDNS, AdGuard, NextDNS...)"
        echo "3) Set Custom DNS (Manual IPv4 + optional NetworkManager connection)"
        echo "4) Enable DNS-over-TLS (DoT) & View DoH Guide"
        echo "5) View Active Interfaces/DNS, Restore, Revert to DHCP or Flush DNS Cache"
        echo "6) Set Global Proxy (Shell, APT, Docker, Git)"
        echo "7) Set Selective Proxy ONLY for Docker or APT (e.g. WARP socks5://127.0.0.1:40000)"
        echo "8) Clear all Proxy configurations"
        echo "9) IPv6 Toggle (Disable IPv6 / Force APT IPv4 or Re-enable)"
        echo "10) Path MTU Optimizer (Auto-detect & apply optimal MTU)"
        echo "11) Enable / Disable TCP BBR Congestion Control"
        echo "12) Sync Server Clock (NTP) & Refresh CA Certificates"
        echo -e "${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-12]: " choice "0"
        case "$choice" in
            1|2)
                local arr_name="DNS_IRAN"
                [ "$choice" = "2" ] && arr_name="DNS_GLOBAL"
                if benchmark_dns_list "$arr_name"; then
                    echo -e "\n${BOLD}Select a DNS provider:${NC}"
                    local i
                    for i in "${!DNS_SORTED[@]}"; do
                        IFS='|' read -r ms status name d1 d2 <<< "${DNS_SORTED[$i]}"
                        echo -e "  ${CYAN}$((i + 1)))${NC} ${BOLD}${name}${NC} (${d1}${d2:+, ${d2}}) ${GREEN}(${ms} ms)${NC} [${status}]"
                    done
                    echo -e "  ${BRED}0) Cancel${NC}\n"
                    local dc=""
                    read_input "Select [0-${#DNS_SORTED[@]}]: " dc "0"
                    if [[ "$dc" =~ ^[0-9]+$ ]] && [ "$dc" -ge 1 ] && [ "$dc" -le "${#DNS_SORTED[@]}" ]; then
                        IFS='|' read -r _ _ name d1 d2 <<< "${DNS_SORTED[$((dc - 1))]}"
                        apply_dns_servers "$name" "$d1" "$d2"
                    fi
                else
                    log_err "No DNS servers responded."
                fi
                pause_screen
                ;;
            3)
                local c1="" c2="" c_nm=""
                read_input "Primary IPv4 DNS (e.g. 178.22.122.100): " c1 ""
                read_input "Secondary IPv4 DNS [optional]: " c2 ""
                if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
                    local def_conn
                    def_conn=$(_detect_active_nm_connection)
                    read_input "NetworkManager connection [${def_conn:-auto}]: " c_nm "$def_conn"
                fi
                apply_custom_dns "$c1" "$c2" "$c_nm" || true
                pause_screen
                ;;
            4)
                echo "1) Cloudflare DoT  2) Quad9 DoT  3) Google DoT  4) AdGuard DoT  5) NextDNS DoT  6) Disable DoT  7) Show DoH Guide"
                local dtc=""
                read_input "Select [1-7]: " dtc "0"
                case "$dtc" in
                    1) apply_dns_dot "cloudflare" ;;
                    2) apply_dns_dot "quad9" ;;
                    3) apply_dns_dot "google" ;;
                    4) apply_dns_dot "adguard" ;;
                    5) apply_dns_dot "nextdns" ;;
                    6) apply_dns_dot "off" ;;
                    7) show_doh_guide ;;
                esac
                pause_screen
                ;;
            5)
                echo "1) View Active Interfaces & DNS  2) Restore DNS backup  3) Revert to DHCP DNS  4) Flush DNS Cache"
                local vc=""
                read_input "Select [1-4]: " vc "1"
                case "$vc" in
                    1) show_dns_overview ;;
                    2) restore_dns_config ;;
                    3) unset_dns_dhcp ;;
                    4) flush_dns_cache ;;
                esac
                pause_screen
                ;;
            6)
                local purl=""
                read_input "Enter proxy URL (e.g., http://127.0.0.1:7890 or socks5://127.0.0.1:1080): " purl ""
                [ -n "$purl" ] && apply_system_proxy "$purl"
                pause_screen
                ;;
            7)
                echo "1) Docker-only proxy  2) APT-only proxy  3) Clear Docker proxy  4) Clear APT proxy"
                local spc=""
                read_input "Select [1-4]: " spc "0"
                case "$spc" in
                    1) local dp=""; read_input "Docker proxy URL [socks5://127.0.0.1:40000]: " dp "socks5://127.0.0.1:40000"; apply_docker_proxy_only "${dp:-socks5://127.0.0.1:40000}" ;;
                    2) local ap=""; read_input "APT proxy URL [http://127.0.0.1:7890]: " ap "http://127.0.0.1:7890"; apply_apt_proxy_only "${ap:-http://127.0.0.1:7890}" ;;
                    3) apply_docker_proxy_only "clear" ;;
                    4) apply_apt_proxy_only "clear" ;;
                esac
                pause_screen
                ;;
            8) clear_system_proxy; pause_screen ;;
            9)
                echo "1) Disable IPv6 & Force APT IPv4  2) Re-enable IPv6"
                local vc=""
                read_input "Select [1-2]: " vc "0"
                [ "$vc" = "1" ] && apply_ipv6_state "disable"
                [ "$vc" = "2" ] && apply_ipv6_state "enable"
                pause_screen
                ;;
            10)
                local mtu_in=""
                read_input "Enter MTU or 'auto' to probe [auto]: " mtu_in "auto"
                optimize_mtu "${mtu_in:-auto}"
                pause_screen
                ;;
            11)
                echo "1) Enable TCP BBR  2) Disable TCP BBR"
                local bc=""
                read_input "Select [1-2]: " bc "0"
                [ "$bc" = "1" ] && apply_bbr_state "enable"
                [ "$bc" = "2" ] && apply_bbr_state "disable"
                pause_screen
                ;;
            12) sync_server_time; pause_screen ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}
