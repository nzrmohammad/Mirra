#!/usr/bin/env bash
# Mirra - Profile Export & Import (Replicate Mirror Config Across Servers)
# shellcheck disable=SC2154

_detect_active_pkg_mirror() {
    case "$PKG_FAMILY" in
        apt)
            if [ -f "$APT_UBUNTU_DEB822" ]; then
                awk '/^URIs:/ {print $2; exit}' "$APT_UBUNTU_DEB822" 2>/dev/null || true
            elif [ -f "$APT_DEBIAN_DEB822" ]; then
                awk '/^URIs:/ {print $2; exit}' "$APT_DEBIAN_DEB822" 2>/dev/null || true
            elif [ -f "$APT_LEGACY_FILE" ]; then
                awk '/^deb / {print $2; exit}' "$APT_LEGACY_FILE" 2>/dev/null || true
            fi
            ;;
        apk)
            awk '/^https?:\/\// {sub(/\/[^/]+\/[^/]+$/, "", $0); print $0; exit}' "$ALPINE_REPOS_FILE" 2>/dev/null || true
            ;;
        pacman)
            awk -F'= ' '/^Server[[:space:]]*=/ {sub(/\/\$repo.*/, "", $2); print $2; exit}' "$ARCH_MIRRORLIST_FILE" 2>/dev/null || true
            ;;
    esac
}

_detect_active_docker_mirrors() {
    if [ ! -f "$DOCKER_DAEMON_PATH" ]; then
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r '.["registry-mirrors"][]? // empty' "$DOCKER_DAEMON_PATH" 2>/dev/null || true
    else
        awk '
            /"registry-mirrors"[[:space:]]*:/ { in_arr=1 }
            in_arr {
                while (match($0, /"https?:\/\/[^"]+"/)) {
                    print substr($0, RSTART+1, RLENGTH-2)
                    $0 = substr($0, RSTART+RLENGTH)
                }
                if ($0 ~ /\]/) exit
            }
        ' "$DOCKER_DAEMON_PATH" 2>/dev/null || true
    fi
}

export_profile() {
    local out_file="${1:-mirra-profile.json}"
    local pkg_mirror pip_url npm_reg go_proxy ipv6_disabled

    pkg_mirror=$(_detect_active_pkg_mirror)
    pip_url=$(awk -F'= ' '/^index-url/ {print $2; exit}' /etc/pip.conf 2>/dev/null | tr -d '[:space:]' || true)
    npm_reg=$(command -v npm >/dev/null 2>&1 && npm config get registry 2>/dev/null || true)
    go_proxy=$(command -v go >/dev/null 2>&1 && go env GOPROXY 2>/dev/null || true)
    if [ -f "$SYSCTL_IPV6_FILE" ]; then
        ipv6_disabled="true"
    else
        ipv6_disabled="false"
    fi

    local docker_mirrors=()
    mapfile -t docker_mirrors < <(_detect_active_docker_mirrors)

    local dns_vals=()
    if [ -f "$RESOLVED_DROPIN_FILE" ]; then
        read -ra dns_vals <<< "$(awk -F'=' '/^DNS=/ {print $2; exit}' "$RESOLVED_DROPIN_FILE" 2>/dev/null || true)"
    elif [ -f /etc/resolv.conf ]; then
        mapfile -t dns_vals < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n 2 || true)
    fi

    local docker_json="[]"
    if [ "${#docker_mirrors[@]}" -gt 0 ]; then
        docker_json=$(_build_json_string_array "${docker_mirrors[@]}")
    fi
    local dns_json="[]"
    if [ "${#dns_vals[@]}" -gt 0 ]; then
        dns_json=$(_build_json_string_array "${dns_vals[@]}")
    fi

    local json_content
    json_content=$(cat <<EOF
{
  "schema": "mirra-profile-v1",
  "os_id": "$(json_escape "$OS_ID")",
  "pkg_family": "$(json_escape "$PKG_FAMILY")",
  "pkg_mirror": "$(json_escape "$pkg_mirror")",
  "docker_mirrors": ${docker_json},
  "pip_index_url": "$(json_escape "$pip_url")",
  "npm_registry": "$(json_escape "$npm_reg")",
  "go_proxy": "$(json_escape "$go_proxy")",
  "dns_servers": ${dns_json},
  "ipv6_disabled": ${ipv6_disabled}
}
EOF
)

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would export profile to ${out_file}:"
        printf '%s\n' "$json_content"
        return 0
    fi
    write_file_safe "$out_file" "$json_content"
    log_ok "Exported Mirra profile to ${out_file}"
}

import_profile() {
    local in_file="${1:-}"
    if [ -z "$in_file" ] || [ ! -f "$in_file" ]; then
        log_err "Profile file not found: ${in_file}"
        return 1
    fi

    log_info "Importing Mirra profile from ${in_file}..."
    local pkg_mirror pip_url npm_reg go_proxy ipv6_disabled
    pkg_mirror=$(json_get_scalar "$in_file" "pkg_mirror")
    pip_url=$(json_get_scalar "$in_file" "pip_index_url")
    npm_reg=$(json_get_scalar "$in_file" "npm_registry")
    go_proxy=$(json_get_scalar "$in_file" "go_proxy")
    ipv6_disabled=$(json_get_scalar "$in_file" "ipv6_disabled")

    local docker_mirrors=()
    mapfile -t docker_mirrors < <(json_get_array "$in_file" "docker_mirrors")
    local dns_vals=()
    mapfile -t dns_vals < <(json_get_array "$in_file" "dns_servers")

    if [ -n "$pkg_mirror" ]; then
        case "$PKG_FAMILY" in
            apt) apply_apt_mirror "$pkg_mirror" ;;
            apk) apply_alpine_mirror "$pkg_mirror" ;;
            pacman) apply_arch_mirror "$pkg_mirror" ;;
        esac
    fi

    if [ "${#docker_mirrors[@]}" -gt 0 ]; then
        apply_docker_mirrors "${docker_mirrors[@]}"
    fi
    [ -n "$pip_url" ] && apply_pip_mirror "$pip_url"
    [ -n "$npm_reg" ] && apply_npm_family_mirror "$npm_reg"
    [ -n "$go_proxy" ] && apply_go_mirror "$go_proxy"

    if [ "${#dns_vals[@]}" -gt 0 ]; then
        apply_dns_servers "Imported" "${dns_vals[0]}" "${dns_vals[1]:-1.1.1.1}"
    fi

    if [ "$ipv6_disabled" = "true" ]; then
        apply_ipv6_state "disable"
    elif [ "$ipv6_disabled" = "false" ]; then
        apply_ipv6_state "enable"
    fi

    log_ok "Profile imported successfully from ${in_file}."
}
