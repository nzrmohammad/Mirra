#!/usr/bin/env bash
# Mirra - Watchdog Automation, Telegram Alerts & Project Dockerfile Patcher
# shellcheck disable=SC2034,SC2154

MIRRA_ETC_DIR="/etc/mirra"
WATCHDOG_CONF="${MIRRA_ETC_DIR}/watchdog.conf"
WATCHDOG_SERVICE="/etc/systemd/system/mirra-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/mirra-watchdog.timer"

send_telegram_alert() {
    local msg="$1"
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"
    local api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"
    local tg_proxy="${TELEGRAM_PROXY:-}"
    api_base="${api_base%/}"

    if [ -z "$token" ] || [ -z "$chat_id" ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would send Telegram alert via ${api_base}${tg_proxy:+ (proxy: ${tg_proxy})} to chat ${chat_id}: ${msg}"
        return 0
    fi

    local curl_args=(-fsS --connect-timeout 3 --max-time 8)
    [ -n "$tg_proxy" ] && curl_args+=(--proxy "$tg_proxy")

    curl "${curl_args[@]}" \
        -X POST "${api_base}/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${msg}" >/dev/null 2>&1 || log_warn "Failed to dispatch Telegram notification."
}

configure_telegram_notify() {
    local token="$1"
    local chat_id="$2"
    local region="${3:-AUTO}"
    local api_base="${4:-https://api.telegram.org}"
    local tg_proxy="${5:-}"

    if [ -z "$token" ] || [ -z "$chat_id" ]; then
        log_err "Both Telegram Bot Token and Chat ID are required."
        return 1
    fi
    api_base="${api_base%/}"
    [ -z "$api_base" ] && api_base="https://api.telegram.org"

    local content
    content=$(cat <<EOF
# Mirra Watchdog Configuration
WATCHDOG_REGION="${region}"
TELEGRAM_BOT_TOKEN="${token}"
TELEGRAM_CHAT_ID="${chat_id}"
TELEGRAM_API_BASE="${api_base}"
TELEGRAM_PROXY="${tg_proxy}"
EOF
)
    write_file_safe "$WATCHDOG_CONF" "$content"
    [ "$DRY_RUN" -eq 0 ] && chmod 600 "$WATCHDOG_CONF"
    log_ok "Saved Telegram notification config to ${WATCHDOG_CONF}"
}

run_watchdog_check() {
    local region="${1:-}"
    if [ -f "$WATCHDOG_CONF" ]; then
        # shellcheck source=/dev/null
        . "$WATCHDOG_CONF"
        [ -z "$region" ] && region="${WATCHDOG_REGION:-AUTO}"
    fi
    [ -z "$region" ] || [ "$region" = "AUTO" ] && region=$(detect_network_region)

    log_info "Running Mirra Watchdog check (profile: ${region})..."
    local changes=()

    # 1. Check active OS mirror
    local active_pkg
    active_pkg=$(_detect_active_pkg_mirror)
    if [ -n "$active_pkg" ]; then
        local suffix=""
        [ "$PKG_FAMILY" = "apt" ] && [ -n "$OS_CODENAME" ] && suffix="dists/${OS_CODENAME}/Release"
        local res
        res=$(test_endpoint "${active_pkg%/}/${suffix}" "http" || true)
        local lat="${res%%|*}"
        if [ "$lat" = "9999" ]; then
            log_warn "Active OS mirror (${active_pkg}) failed health check. Switching..."
            if configure_pkg_auto "$region"; then
                changes+=("OS mirror rotated (was ${active_pkg})")
            fi
        else
            log_ok "Active OS mirror (${active_pkg}) is healthy (${lat} ms)."
        fi
    fi

    # 2. Check active Docker mirrors
    local docker_mirrors=()
    mapfile -t docker_mirrors < <(_detect_active_docker_mirrors)
    if [ "${#docker_mirrors[@]}" -gt 0 ]; then
        local res
        res=$(test_endpoint "${docker_mirrors[0]%/}/v2/" "docker" || true)
        local lat="${res%%|*}"
        if [ "$lat" = "9999" ]; then
            log_warn "Primary Docker mirror (${docker_mirrors[0]}) is unreachable. Rotating..."
            if configure_docker_auto "$region"; then
                changes+=("Docker mirrors rotated (was ${docker_mirrors[0]})")
            fi
        else
            log_ok "Primary Docker mirror (${docker_mirrors[0]}) is healthy (${lat} ms)."
        fi
    fi

    if [ "${#changes[@]}" -gt 0 ]; then
        local host_label
        host_label=$(hostname 2>/dev/null || echo "linux-server")
        local summary
        summary=$(printf '%s; ' "${changes[@]}")
        send_telegram_alert "Mirra Watchdog [${host_label}]: ${summary}"
    fi
}

enable_watchdog() {
    local region="${1:-AUTO}"
    if [ ! -f "$WATCHDOG_CONF" ]; then
        write_file_safe "$WATCHDOG_CONF" "WATCHDOG_REGION=\"${region}\""
    fi

    local bin_exec="${MIRRA_BIN_PATH}"
    [ ! -x "$bin_exec" ] && [ -n "${SCRIPT_DIR:-}" ] && bin_exec="${SCRIPT_DIR}/mirra.sh"

    local svc_content
    svc_content=$(cat <<EOF
[Unit]
Description=Mirra Automated Mirror Health Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${bin_exec} --run-watchdog
EOF
)
    local timer_content
    timer_content=$(cat <<'EOF'
[Unit]
Description=Run Mirra Mirror Watchdog Daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
)
    write_file_safe "$WATCHDOG_SERVICE" "$svc_content"
    write_file_safe "$WATCHDOG_TIMER" "$timer_content"

    if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl daemon-reload 2>/dev/null && systemctl enable --now mirra-watchdog.timer 2>/dev/null; then
            log_ok "Mirra Watchdog timer enabled (daily)."
        else
            log_warn "Mirra Watchdog unit files written, but systemd could not enable the timer."
        fi
    else
        log_ok "Mirra Watchdog unit files prepared."
    fi
}

disable_watchdog() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would disable and remove ${WATCHDOG_SERVICE} and ${WATCHDOG_TIMER}"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now mirra-watchdog.timer 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
    log_ok "Mirra Watchdog timer disabled and removed."
}

# Rewrite unqualified Docker Hub FROM images in Dockerfiles inside a project directory
patch_project_dockerfiles() {
    local project_dir="${1:-.}"
    local mirror_url="${2:-}"

    if [ ! -d "$project_dir" ]; then
        log_err "Project directory not found: ${project_dir}"
        return 1
    fi

    if [ -z "$mirror_url" ]; then
        if benchmark_mirrors DOCKER_IRAN "/v2/" "docker" 1; then
            mirror_url="${SORTED_MIRRORS[0]}"
        else
            mirror_url="${DOCKER_IRAN[0]}"
        fi
    fi

    local mirror_host="${mirror_url#https://}"
    mirror_host="${mirror_host#http://}"
    mirror_host="${mirror_host%/}"

    local files=()
    mapfile -t files < <(find "$project_dir" -maxdepth 4 \
        \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' \) -prune -o \
        -type f -name 'Dockerfile*' -print 2>/dev/null || true)

    if [ "${#files[@]}" -eq 0 ]; then
        log_warn "No Dockerfile* found inside ${project_dir}"
        return 0
    fi

    local patched_count=0
    local f
    for f in "${files[@]}"; do
        local updated
        updated=$(awk -v reg="$mirror_host" '
            /^[[:space:]]*FROM[[:space:]]+/ {
                n = split($0, parts, /[[:space:]]+/)
                img_idx = 0
                for (i = 2; i <= n; i++) {
                    if (parts[i] ~ /^--/) continue
                    img_idx = i
                    break
                }
                if (img_idx > 0) {
                    img = parts[img_idx]
                    # Skip scratch, build args ($VAR), or already-qualified hosts (contains dot or localhost)
                    if (img != "scratch" && img !~ /^\$/ && img !~ /^([^/]*\.[^/]*|localhost)\//) {
                        parts[img_idx] = reg "/" img
                        line = parts[1]
                        for (j = 2; j <= n; j++) line = line " " parts[j]
                        print line
                        next
                    }
                }
            }
            { print }
        ' "$f")

        if [ "$updated" != "$(cat "$f")" ]; then
            backup_file "$f"
            write_file_safe "$f" "$updated"
            log_ok "Patched Dockerfile (${mirror_host}): ${f}"
            patched_count=$((patched_count + 1))
        fi
    done

    if [ "$patched_count" -eq 0 ]; then
        log_info "No unqualified Docker Hub FROM lines needed patching in ${project_dir}."
    fi
}
