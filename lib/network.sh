#!/usr/bin/env bash
# Mirra - Parallel Benchmarking, HTTP Verification, Throughput & Network Diagnostics
# shellcheck disable=SC2034,SC2154

# Output arrays populated by benchmark_mirrors
SORTED_MIRRORS=()
SORTED_LATENCIES=()
SORTED_CODES=()

# Test a single URL; prints "<latency_ms>|<http_code>" or "9999|<http_code>"
test_endpoint() {
    local url="$1"
    local mode="${2:-http}" # http | docker

    local raw
    raw=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}" \
        --connect-timeout 2 --max-time 3 -L "$url" 2>/dev/null || echo "000|0")

    local code="${raw%%|*}"
    local time_s="${raw#*|}"

    if [ -z "$code" ] || [ "$code" = "000" ]; then
        echo "9999|000"
        return 1
    fi

    local valid=0
    case "$mode" in
        docker)
            if [[ "$code" =~ ^(200|301|302|307|308|401)$ ]]; then
                valid=1
            fi
            ;;
        *)
            if [[ "$code" =~ ^(200|206|301|302|307|308)$ ]]; then
                valid=1
            fi
            ;;
    esac

    if [ "$valid" -eq 0 ]; then
        echo "9999|${code}"
        return 1
    fi

    local ms
    ms=$(awk -v t="$time_s" 'BEGIN { val = int((t * 1000) + 0.5); if (val < 1) val = 1; print val }' 2>/dev/null || echo "9999")
    echo "${ms}|${code}"
    return 0
}

# Check APT Release Date freshness (returns human age like "2h ago" or "14d ago")
check_apt_freshness() {
    local base_url="$1"
    local codename="$2"
    if [ -z "$codename" ]; then
        echo ""
        return 0
    fi
    local release_url="${base_url%/}/dists/${codename}/Release"
    local date_hdr
    date_hdr=$(curl -fsSI --connect-timeout 2 --max-time 3 "$release_url" 2>/dev/null \
        | awk -F': ' 'tolower($1)=="last-modified" || tolower($1)=="date" {print $2; exit}' | tr -d '\r')
    if [ -z "$date_hdr" ]; then
        echo ""
        return 0
    fi
    local rel_ts now_ts diff_h
    rel_ts=$(date -d "$date_hdr" +%s 2>/dev/null || echo "")
    now_ts=$(date +%s)
    if [ -n "$rel_ts" ] && [ "$rel_ts" -gt 0 ]; then
        diff_h=$(( (now_ts - rel_ts) / 3600 ))
        if [ "$diff_h" -lt 24 ]; then
            echo "synced ${diff_h}h ago"
        else
            echo "synced $((diff_h / 24))d ago"
        fi
    fi
}

# Measure actual download speed on a URL (bytes/sec -> formatted string)
measure_throughput() {
    local url="$1"
    local speed_bps
    speed_bps=$(curl -r 0-1048575 -o /dev/null -s -w "%{speed_download}" \
        --connect-timeout 2 --max-time 5 -L "$url" 2>/dev/null || echo "0")
    awk -v s="$speed_bps" 'BEGIN {
        if (s <= 0) { print "N/A"; exit }
        if (s >= 1048576) printf "%.2f MB/s", s / 1048576
        else printf "%.0f KB/s", s / 1024
    }'
}

# Parallel benchmark of an array of mirrors
# Usage: benchmark_mirrors ARRAY_NAME [suffix] [mode: http|docker] [quiet: 0|1]
benchmark_mirrors() {
    local -n input_list="$1"
    local suffix="${2:-}"
    local mode="${3:-http}"
    local quiet="${4:-0}"

    SORTED_MIRRORS=()
    SORTED_LATENCIES=()
    SORTED_CODES=()

    if [ "${#input_list[@]}" -eq 0 ]; then
        return 1
    fi

    if [ "$quiet" -eq 0 ]; then
        log_warn "Benchmarking ${#input_list[@]} endpoints in parallel (max 3s timeout)..."
        echo ""
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=()
    local idx=0

    for mirror in "${input_list[@]}"; do
        local test_url="${mirror}${suffix}"
        (
            local res
            res=$(test_endpoint "$test_url" "$mode" || true)
            echo "${res}|${mirror}" > "${tmp_dir}/${idx}.res"
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
        if [ -f "${tmp_dir}/${i}.res" ]; then
            local line
            line=$(cat "${tmp_dir}/${i}.res")
            local lat="${line%%|*}"
            local rest="${line#*|}"
            local code="${rest%%|*}"
            local url="${rest#*|}"

            if [ "$lat" -lt 9999 ] 2>/dev/null; then
                ok_lines+=("${lat}|${code}|${url}")
                if [ "$quiet" -eq 0 ]; then
                    echo -e "  • ${url} ... ${GREEN}${lat} ms${NC} ${GRAY}(HTTP ${code})${NC}"
                fi
            else
                if [ "$quiet" -eq 0 ]; then
                    if [ "$code" = "000" ]; then
                        echo -e "  • ${url} ... ${RED}Timed Out / Unreachable${NC}"
                    else
                        echo -e "  • ${url} ... ${RED}Failed (HTTP ${code})${NC}"
                    fi
                fi
            fi
        fi
    done

    rm -rf "$tmp_dir"

    if [ "${#ok_lines[@]}" -eq 0 ]; then
        return 1
    fi

    local sorted_entries=()
    mapfile -t sorted_entries < <(printf '%s\n' "${ok_lines[@]}" | sort -t'|' -k1,1n)

    local entry
    for entry in "${sorted_entries[@]}"; do
        local lat="${entry%%|*}"
        local rest="${entry#*|}"
        local code="${rest%%|*}"
        local url="${rest#*|}"
        SORTED_LATENCIES+=("$lat")
        SORTED_CODES+=("$code")
        SORTED_MIRRORS+=("$url")
    done

    return 0
}

# Auto-detect whether server is inside Iran / restricted network or Global
detect_network_region() {
    local country=""
    if command -v curl >/dev/null 2>&1; then
        country=$(curl -fsS --connect-timeout 2 --max-time 2 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
        if [ -z "$country" ]; then
            country=$(curl -fsS --connect-timeout 2 --max-time 2 https://api.country.is 2>/dev/null \
                | sed -n 's/.*"country":"\([^"]*\)".*/\1/p' || true)
        fi
    fi

    if [ "$country" = "IR" ]; then
        echo "IRAN"
        return 0
    elif [ -n "$country" ]; then
        echo "GLOBAL"
        return 0
    fi

    # Fallback heuristic: check if Docker Hub or Google is blocked while an Iranian mirror responds
    local global_code ir_code
    global_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 https://registry-1.docker.io/v2/ 2>/dev/null || echo "000")
    ir_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 2 https://docker.arvancloud.ir/v2/ 2>/dev/null || echo "000")

    if [[ ! "$global_code" =~ ^(200|401)$ ]] && [[ "$ir_code" =~ ^(200|401)$ ]]; then
        echo "IRAN"
    else
        echo "GLOBAL"
    fi
}

robust_network_check() {
    local dns_ok=false icmp_ok=false dns_hijacked=false
    local g_code d_code p_code gh_code region clock_skew_sec="0"

    if getent hosts google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1; then
        dns_ok=true
    fi
    # DNS Hijack check: invalid TLD must NOT resolve to an IP
    if getent hosts "mirra-nxdomain-check-$(date +%s).invalid" >/dev/null 2>&1; then
        dns_hijacked=true
    fi
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        icmp_ok=true
    fi
    g_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 https://www.google.com 2>/dev/null || echo "000")
    d_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 https://registry-1.docker.io/v2/ 2>/dev/null || echo "000")
    p_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 https://pypi.org/simple/ 2>/dev/null || echo "000")
    gh_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 https://github.com 2>/dev/null || echo "000")

    # Clock skew check against remote HTTP Date header
    local remote_date remote_ts local_ts
    remote_date=$(curl -fsSI --connect-timeout 2 --max-time 3 http://mirror.arvancloud.ir/ 2>/dev/null \
        | awk -F': ' 'tolower($1)=="date" {print $2; exit}' | tr -d '\r' || true)
    if [ -n "$remote_date" ]; then
        remote_ts=$(date -d "$remote_date" +%s 2>/dev/null || echo 0)
        local_ts=$(date +%s)
        if [ "$remote_ts" -gt 0 ] 2>/dev/null; then
            clock_skew_sec=$(( local_ts - remote_ts ))
            [ "$clock_skew_sec" -lt 0 ] && clock_skew_sec=$(( -clock_skew_sec ))
        fi
    fi

    region=$(detect_network_region)

    if [ "${JSON_OUTPUT:-0}" -eq 1 ]; then
        local g_ok=false d_ok=false p_ok=false gh_ok=false
        [[ "$g_code" =~ ^(200|301|302)$ ]] && g_ok=true
        [[ "$d_code" =~ ^(200|401)$ ]] && d_ok=true
        [[ "$p_code" =~ ^(200|301|302)$ ]] && p_ok=true
        [[ "$gh_code" =~ ^(200|301|302)$ ]] && gh_ok=true
        cat <<EOF
{
  "dns_ok": ${dns_ok},
  "dns_hijacked": ${dns_hijacked},
  "icmp_ok": ${icmp_ok},
  "clock_skew_sec": ${clock_skew_sec},
  "global_https": { "ok": ${g_ok}, "http_code": "${g_code}" },
  "docker_hub": { "ok": ${d_ok}, "http_code": "${d_code}" },
  "pypi": { "ok": ${p_ok}, "http_code": "${p_code}" },
  "github": { "ok": ${gh_ok}, "http_code": "${gh_code}" },
  "detected_region": "${region}"
}
EOF
        return 0
    fi

    echo -e "\n${YELLOW}[+] Running Multi-Layer Network & Sanction Diagnostics...${NC}\n"

    echo -n "  1. DNS Resolution (google.com) ............... "
    [ "$dns_ok" = "true" ] && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAILED]${NC}"

    echo -n "  2. DNS Hijack Check (NXDOMAIN) ............... "
    [ "$dns_hijacked" = "false" ] && echo -e "${GREEN}[CLEAN]${NC}" || echo -e "${RED}[HIJACKED!]${NC}"

    echo -n "  3. ICMP Reachability (1.1.1.1) ............... "
    [ "$icmp_ok" = "true" ] && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAILED]${NC}"

    echo -n "  4. Server Clock Skew ......................... "
    if [ "$clock_skew_sec" -le 60 ] 2>/dev/null; then
        echo -e "${GREEN}[OK] (${clock_skew_sec}s diff)${NC}"
    else
        echo -e "${RED}[SKEWED!] (${clock_skew_sec}s diff — run NTP Time Sync!)${NC}"
    fi

    echo -n "  5. Global HTTPS (google.com) ................. "
    if [[ "$g_code" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}[OK] (HTTP ${g_code})${NC}"
    else
        echo -e "${YELLOW}[RESTRICTED] (HTTP ${g_code})${NC}"
    fi

    echo -n "  6. Docker Hub Direct (registry-1.docker.io) .. "
    if [[ "$d_code" =~ ^(200|401)$ ]]; then
        echo -e "${GREEN}[OK] (HTTP ${d_code})${NC}"
    else
        echo -e "${RED}[BLOCKED/SANCTIONED] (HTTP ${d_code})${NC}"
    fi

    echo -n "  7. PyPI Direct (pypi.org) .................... "
    if [[ "$p_code" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}[OK] (HTTP ${p_code})${NC}"
    else
        echo -e "${YELLOW}[SLOW/RESTRICTED] (HTTP ${p_code})${NC}"
    fi

    echo -n "  8. GitHub Direct (github.com) ................ "
    if [[ "$gh_code" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}[OK] (HTTP ${gh_code})${NC}"
    else
        echo -e "${YELLOW}[RESTRICTED] (HTTP ${gh_code})${NC}"
    fi

    echo -e "\n  ${BLUE}Detected Optimal Profile:${NC} ${BOLD}${region}${NC}"
}
