#!/usr/bin/env bash
# Mirra - Container Engines (Docker, containerd, Podman) Mirror Configuration
# shellcheck disable=SC2034,SC2154

DOCKER_DAEMON_PATH="/etc/docker/daemon.json"
CONTAINERD_HOSTS_FILE="/etc/containerd/certs.d/docker.io/hosts.toml"
PODMAN_REGISTRIES_CONF="/etc/containers/registries.conf.d/99-mirra.conf"

_build_json_string_array() {
    local out="["
    local item
    local first=1
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            out+="\"${item}\""
            first=0
        else
            out+=", \"${item}\""
        fi
    done
    out+="]"
    echo "$out"
}

_generate_merged_daemon_json() {
    local mirrors_json_array="$1"
    if [ ! -f "$DOCKER_DAEMON_PATH" ] || [ ! -s "$DOCKER_DAEMON_PATH" ]; then
        cat <<EOF
{
  "registry-mirrors": ${mirrors_json_array}
}
EOF
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        local merged
        if merged=$(jq --argjson m "$mirrors_json_array" '.["registry-mirrors"] = $m' "$DOCKER_DAEMON_PATH" 2>/dev/null); then
            echo "$merged"
            return 0
        fi
    fi

    if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
        local merged
        if merged=$(python3 - "$DOCKER_DAEMON_PATH" "$mirrors_json_array" <<'PYEOF' 2>/dev/null
import json, sys
path, arr = sys.argv[1], json.loads(sys.argv[2])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    data = {}
data["registry-mirrors"] = arr
print(json.dumps(data, indent=2))
PYEOF
); then
            echo "$merged"
            return 0
        fi
    fi

    # Pure awk fallback: preserve existing keys when neither jq nor python3 is installed
    local cleaned
    cleaned=$(awk '
        BEGIN { skip = 0 }
        /"registry-mirrors"[[:space:]]*:/ {
            if ($0 ~ /\[/ && $0 ~ /\]/) { next }
            skip = 1
            next
        }
        skip {
            if ($0 ~ /\]/) { skip = 0 }
            next
        }
        { print }
    ' "$DOCKER_DAEMON_PATH" | sed -e '/^[[:space:]]*{[[:space:]]*$/d' -e '/^[[:space:]]*}[[:space:]]*$/d' -e '/^[[:space:]]*$/d')

    # Trim trailing comma on last remaining property, then normalize
    cleaned=$(printf '%s\n' "$cleaned" | sed -e '$ s/,[[:space:]]*$//')
    if [ -n "$cleaned" ]; then
        printf '{\n  "registry-mirrors": %s,\n%s\n}\n' "$mirrors_json_array" "$cleaned"
    else
        printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json_array"
    fi
}

apply_docker_mirrors() {
    local mirrors=("$@")
    if [ "${#mirrors[@]}" -eq 0 ]; then
        log_err "No Docker mirrors provided."
        return 1
    fi

    local mirrors_json_array
    mirrors_json_array=$(_build_json_string_array "${mirrors[@]}")

    backup_file "$DOCKER_DAEMON_PATH"
    local new_content
    new_content=$(_generate_merged_daemon_json "$mirrors_json_array")
    write_file_safe "$DOCKER_DAEMON_PATH" "$new_content"
    log_ok "Updated ${DOCKER_DAEMON_PATH}"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would restart docker service if installed."
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
        if systemctl restart docker; then
            log_ok "Docker service restarted successfully."
        else
            log_err "Docker service failed to restart! Check 'journalctl -u docker'."
            return 1
        fi
    elif command -v service >/dev/null 2>&1 && [ -e /etc/init.d/docker ]; then
        if service docker restart; then
            log_ok "Docker service restarted."
        else
            log_err "Docker restart failed."
        fi
    else
        log_info "Docker service not detected; configuration saved for future Docker installation."
    fi
}

apply_containerd_mirrors() {
    local mirrors=("$@")
    if [ "${#mirrors[@]}" -eq 0 ]; then
        return 1
    fi
    backup_file "$CONTAINERD_HOSTS_FILE"
    local content="server = \"https://registry-1.docker.io\"\n"
    local m
    for m in "${mirrors[@]}"; do
        content+="\n[host.\"${m%/}\"]\n  capabilities = [\"pull\", \"resolve\"]\n"
    done
    write_file_safe "$CONTAINERD_HOSTS_FILE" "$(printf '%b' "$content")"
    log_ok "Updated containerd mirror config at ${CONTAINERD_HOSTS_FILE}"

    if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet containerd 2>/dev/null; then
        if systemctl restart containerd; then
            log_ok "containerd restarted."
        else
            log_warn "Could not restart containerd."
        fi
    fi
}

apply_podman_mirrors() {
    local mirrors=("$@")
    if [ "${#mirrors[@]}" -eq 0 ]; then
        return 1
    fi
    backup_file "$PODMAN_REGISTRIES_CONF"
    local content="# Configured by Mirra\n[[registry]]\nlocation = \"docker.io\"\n"
    local m
    for m in "${mirrors[@]}"; do
        local host="${m#https://}"
        host="${host#http://}"
        host="${host%/}"
        content+="\n[[registry.mirror]]\nlocation = \"${host}\"\n"
    done
    write_file_safe "$PODMAN_REGISTRIES_CONF" "$(printf '%b' "$content")"
    log_ok "Updated Podman registry mirrors at ${PODMAN_REGISTRIES_CONF}"
}

configure_docker_auto() {
    local region="$1"
    if [ "$region" = "IRAN" ]; then
        if benchmark_mirrors DOCKER_IRAN "/v2/" "docker" 1; then
            # Use top 6 fastest healthy mirrors for cleaner fallback behavior
            local top_mirrors=("${SORTED_MIRRORS[@]:0:6}")
            apply_docker_mirrors "${top_mirrors[@]}"
        else
            log_err "No reachable Iranian Docker mirrors found."
            return 1
        fi
    else
        apply_docker_mirrors "${DOCKER_GLOBAL[0]}"
    fi
}

configure_docker_interactive() {
    local region="$1"
    local arr_name="DOCKER_GLOBAL"
    [ "$region" = "IRAN" ] && arr_name="DOCKER_IRAN"

    if ! benchmark_mirrors "$arr_name" "/v2/" "docker" 0; then
        log_err "All selected Docker mirrors are currently unreachable."
        pause_screen
        return
    fi

    echo -e "\n${BOLD}Select a Docker Registry mirror (Sorted by lowest latency):${NC}"
    local i
    for i in "${!SORTED_MIRRORS[@]}"; do
        echo -e "  ${CYAN}$((i + 1)))${NC} ${SORTED_MIRRORS[$i]} ${GREEN}(${SORTED_LATENCIES[$i]} ms)${NC}"
    done
    if [ "$region" = "IRAN" ]; then
        echo -e "  ${CYAN}A)${NC} Apply ALL reachable Iranian mirrors (Recommended)"
        echo -e "  ${CYAN}T)${NC} Apply TOP 5 fastest Iranian mirrors"
    fi
    echo -e "  ${BRED}0) Cancel${NC}\n"

    local m_choice=""
    read_input "Enter selection: " m_choice "0"
    if [ "$m_choice" = "0" ]; then
        log_warn "Operation canceled."
    elif [[ "$m_choice" =~ ^[0-9]+$ ]] && [ "$m_choice" -ge 1 ] && [ "$m_choice" -le "${#SORTED_MIRRORS[@]}" ]; then
        apply_docker_mirrors "${SORTED_MIRRORS[$((m_choice - 1))]}"
    elif [[ "$m_choice" =~ ^[Aa]$ ]] && [ "$region" = "IRAN" ]; then
        apply_docker_mirrors "${SORTED_MIRRORS[@]}"
    elif [[ "$m_choice" =~ ^[Tt]$ ]] && [ "$region" = "IRAN" ]; then
        apply_docker_mirrors "${SORTED_MIRRORS[@]:0:5}"
    else
        log_err "Invalid selection."
    fi
    pause_screen
}

menu_containers() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 2: Container Engines (Docker / containerd / Podman) ]${NC}\n"
        echo "1) Benchmark & apply Docker mirror (Iran Mirrors)"
        echo "2) Benchmark & apply Docker mirror (Global / Official)"
        echo "3) Configure containerd mirrors (/etc/containerd/certs.d)"
        echo "4) Configure Podman mirrors (/etc/containers/registries.conf.d)"
        echo "5) View current /etc/docker/daemon.json"
        echo "6) Restore original container config from backup"
        echo "7) Restart Docker service"
        echo -e "${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-7]: " choice "0"

        case "$choice" in
            1) configure_docker_interactive "IRAN" ;;
            2) configure_docker_interactive "GLOBAL" ;;
            3)
                if benchmark_mirrors DOCKER_IRAN "/v2/" "docker" 0; then
                    apply_containerd_mirrors "${SORTED_MIRRORS[@]:0:5}"
                fi
                pause_screen
                ;;
            4)
                if benchmark_mirrors DOCKER_IRAN "/v2/" "docker" 0; then
                    apply_podman_mirrors "${SORTED_MIRRORS[@]:0:5}"
                fi
                pause_screen
                ;;
            5)
                echo -e "\n${BLUE}--- ${DOCKER_DAEMON_PATH} ---${NC}"
                cat "$DOCKER_DAEMON_PATH" 2>/dev/null || log_warn "File does not exist."
                pause_screen
                ;;
            6)
                restore_from_manifest "docker" || true
                restore_from_manifest "containerd" || true
                restore_from_manifest "containers" || true
                if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
                    systemctl restart docker && log_ok "Docker restarted."
                fi
                pause_screen
                ;;
            7)
                if [ "$DRY_RUN" -eq 1 ]; then
                    log_dry "Would restart docker"
                else
                    if systemctl restart docker; then
                        log_ok "Docker restarted."
                    else
                        log_err "Docker restart failed."
                    fi
                fi
                pause_screen
                ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}
