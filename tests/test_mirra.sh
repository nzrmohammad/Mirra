#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $msg"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $msg (expected: '$expected', got: '$actual')" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [PASS] $msg"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $msg (missing: '$needle')" >&2
        FAIL=$((FAIL + 1))
    fi
}

echo "=== 1. Bash Syntax Checks ==="
for f in "$ROOT_DIR/mirra.sh" "$ROOT_DIR"/lib/*.sh; do
    if bash -n "$f"; then
        echo "  [PASS] bash -n $f"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] bash -n $f" >&2
        FAIL=$((FAIL + 1))
    fi
done

echo "=== 2. CLI --version & --help ==="
ver_out=$(bash "$ROOT_DIR/mirra.sh" --version)
assert_contains "$ver_out" "Mirra v" "--version outputs Mirra version"

help_out=$(bash "$ROOT_DIR/mirra.sh" --help)
assert_contains "$help_out" "--auto" "--help includes --auto"
assert_contains "$help_out" "--dry-run" "--help includes --dry-run"
assert_contains "$help_out" "--restore-all" "--help includes --restore-all"

echo "=== 3. Load Modules & Test mirrors.json Parsing ==="
SCRIPT_DIR="$ROOT_DIR"
MIRRA_OFFLINE=1
DRY_RUN=1
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/network.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/pkg.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/containers.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/devtools.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/dns_proxy.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/profile.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/automation.sh"

load_mirrors_config
assert_contains "${APT_UBUNTU_IRAN[0]}" "http://" "APT_UBUNTU_IRAN loaded"
assert_contains "${APT_DEBIAN_IRAN[0]}" "debian" "APT_DEBIAN_IRAN loaded"
assert_contains "${DOCKER_IRAN[0]}" "https://" "DOCKER_IRAN loaded"
assert_contains "${DNS_IRAN[0]}" "Shecan|" "DNS_IRAN loaded"

echo "=== 4. Test Ubuntu & Debian APT Generation (Temp Files) ==="
TMP_SANDBOX=$(mktemp -d)
trap 'rm -rf "$TMP_SANDBOX"' EXIT

# Stub privileged system commands so sandboxed unit tests never alter host services or fail as non-root
systemctl() { return 0; }
timedatectl() { return 0; }
sysctl() { return 0; }
modprobe() { return 0; }
update-ca-certificates() { return 0; }

DRY_RUN=0
MIRRA_BACKUP_DIR="${TMP_SANDBOX}/backups"
APT_LEGACY_FILE="${TMP_SANDBOX}/sources.list"
APT_UBUNTU_DEB822="${TMP_SANDBOX}/ubuntu.sources"
APT_DEBIAN_DEB822="${TMP_SANDBOX}/debian.sources"

# Test Ubuntu DEB822
touch "$APT_UBUNTU_DEB822"
OS_ID="ubuntu"
OS_CODENAME="noble"
apply_apt_mirror "http://mirror.arvancloud.ir/ubuntu/" >/dev/null
ubuntu_out=$(cat "$APT_UBUNTU_DEB822")
assert_contains "$ubuntu_out" "URIs: http://mirror.arvancloud.ir/ubuntu/" "Ubuntu DEB822 URI written"
assert_contains "$ubuntu_out" "Suites: noble noble-updates" "Ubuntu DEB822 Suites written"

# Test Debian DEB822
touch "$APT_DEBIAN_DEB822"
OS_ID="debian"
OS_CODENAME="bookworm"
apply_apt_mirror "http://mirror.arvancloud.ir/debian/" >/dev/null
debian_out=$(cat "$APT_DEBIAN_DEB822")
assert_contains "$debian_out" "non-free-firmware" "Debian Bookworm includes non-free-firmware"
assert_contains "$debian_out" "debian-archive-keyring.gpg" "Debian uses debian-archive-keyring.gpg"

echo "=== 5. Test Docker daemon.json Merge Preservation ==="
DOCKER_DAEMON_PATH="${TMP_SANDBOX}/daemon.json"
cat <<'EOF' > "$DOCKER_DAEMON_PATH"
{
  "log-driver": "json-file",
  "registry-mirrors": ["https://old.example.com"],
  "data-root": "/mnt/docker"
}
EOF
merged_json=$(_generate_merged_daemon_json '["https://docker.arvancloud.ir"]')
assert_contains "$merged_json" "https://docker.arvancloud.ir" "Merged JSON adds new registry-mirrors"
assert_contains "$merged_json" "log-driver" "Merged JSON preserves log-driver"
assert_contains "$merged_json" "/mnt/docker" "Merged JSON preserves data-root"
if [[ "$merged_json" == *"old.example.com"* ]]; then
    echo "  [FAIL] Old registry-mirrors was not replaced" >&2
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] Old registry-mirrors replaced cleanly"
    PASS=$((PASS + 1))
fi

echo "=== 6. Test Backup & Restore Manifest ==="
TEST_TARGET="${TMP_SANDBOX}/sample.conf"
echo "original-content" > "$TEST_TARGET"
backup_file "$TEST_TARGET" >/dev/null
echo "modified-content" > "$TEST_TARGET"
restore_from_manifest "sample.conf" >/dev/null
restored_val=$(cat "$TEST_TARGET")
assert_eq "original-content" "$restored_val" "Manifest restore recovers original content"

echo "=== 7. Test Alpine, Arch, containerd, Podman, DevTools & Third-Party APT ==="
ALPINE_REPOS_FILE="${TMP_SANDBOX}/apk_repositories"
apply_alpine_mirror "https://mirror.arvancloud.ir/alpine/" >/dev/null
assert_contains "$(cat "$ALPINE_REPOS_FILE")" "mirror.arvancloud.ir/alpine" "Alpine APK mirror written"

ARCH_MIRRORLIST_FILE="${TMP_SANDBOX}/mirrorlist"
apply_arch_mirror "https://mirror.arvancloud.ir/archlinux/" >/dev/null
assert_contains "$(cat "$ARCH_MIRRORLIST_FILE")" "Server = https://mirror.arvancloud.ir/archlinux" "Arch mirrorlist written"

CONTAINERD_HOSTS_FILE="${TMP_SANDBOX}/hosts.toml"
apply_containerd_mirrors "https://docker.arvancloud.ir" "https://docker.liara.ir" >/dev/null
assert_contains "$(cat "$CONTAINERD_HOSTS_FILE")" 'host."https://docker.arvancloud.ir"' "containerd hosts.toml written"

PODMAN_REGISTRIES_CONF="${TMP_SANDBOX}/99-mirra.conf"
apply_podman_mirrors "https://docker.arvancloud.ir" >/dev/null
assert_contains "$(cat "$PODMAN_REGISTRIES_CONF")" 'location = "docker.arvancloud.ir"' "Podman registries conf written"

TARGET_HOME="${TMP_SANDBOX}/home"
TARGET_USER="root"
mkdir -p "$TARGET_HOME"
HOME="$TARGET_HOME"
SUDO_USER=""
PROFILE_DEVTOOLS_FILE="${TMP_SANDBOX}/mirra-devtools.sh"

apply_cargo_mirror "IRAN" >/dev/null
assert_contains "$(cat "${TARGET_HOME}/.cargo/config.toml")" "rsproxy-sparse" "Cargo config.toml written"
assert_contains "$(cat "$PROFILE_DEVTOOLS_FILE")" "NVM_NODEJS_ORG_MIRROR" "DevTools env sets NVM mirror"
assert_contains "$(cat "$PROFILE_DEVTOOLS_FILE")" "RUSTUP_DIST_SERVER" "DevTools env sets Rustup server"

apply_conda_mirror "IRAN" >/dev/null
assert_contains "$(cat "${TARGET_HOME}/.condarc")" "conda-forge" "Conda .condarc written"

apply_java_mirror "IRAN" >/dev/null
assert_contains "$(cat "${TARGET_HOME}/.m2/settings.xml")" "mirra-aliyun" "Maven settings.xml written"
assert_contains "$(cat "${TARGET_HOME}/.gradle/init.d/mirra.gradle")" "maven.aliyun.com" "Gradle init.d written"

mkdir -p "${TMP_SANDBOX}/apt.d"
echo "deb https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" > "${TMP_SANDBOX}/apt.d/kubernetes.list"
PKG_FAMILY="apt"
fix_third_party_apt_mirrors "${TMP_SANDBOX}/apt.d" >/dev/null
assert_contains "$(cat "${TMP_SANDBOX}/apt.d/kubernetes.list")" "mirrors.aliyun.com/kubernetes-new" "Third-party K8s APT repo replaced"

echo "=== 8. Test Non-Interactive Dry-Run CLI & JSON Status ==="
dry_out=$(bash "$ROOT_DIR/mirra.sh" --devtools iran --dry-run --yes --offline 2>&1)
assert_contains "$dry_out" "[DRY-RUN]" "CLI --devtools --dry-run executes cleanly"

status_json=$(bash "$ROOT_DIR/mirra.sh" --status --json --offline)
assert_contains "$status_json" '"version"' "Status --json includes version"
assert_contains "$status_json" '"ipv6_disabled"' "Status --json includes ipv6_disabled"

echo "=== 9. Test NuGet, Homebrew Env, IPv6 & Profile Export/Import ==="
apply_nuget_mirror "IRAN" >/dev/null
assert_contains "$(cat "${TARGET_HOME}/.nuget/NuGet/NuGet.Config")" "MirraNuGet" "NuGet.Config written"
assert_contains "$(cat "$PROFILE_DEVTOOLS_FILE")" "HOMEBREW_BOTTLE_DOMAIN" "DevTools env sets Homebrew mirror"

SYSCTL_IPV6_FILE="${TMP_SANDBOX}/99-mirra-ipv6.conf"
APT_IPV4_FILE="${TMP_SANDBOX}/99mirra-ipv4"
PKG_FAMILY="apt"
apply_ipv6_state "disable" >/dev/null
assert_contains "$(cat "$SYSCTL_IPV6_FILE")" "disable_ipv6 = 1" "IPv6 sysctl drop-in written"
assert_contains "$(cat "$APT_IPV4_FILE")" "ForceIPv4" "APT ForceIPv4 written"

PROFILE_OUT="${TMP_SANDBOX}/exported.json"
DRY_RUN=0
export_profile "$PROFILE_OUT" >/dev/null
assert_contains "$(cat "$PROFILE_OUT")" '"schema": "mirra-profile-v1"' "Exported profile JSON created"

DRY_RUN=1
import_out=$(import_profile "$PROFILE_OUT" 2>&1)
assert_contains "$import_out" "Profile imported successfully" "Profile import executes cleanly"

echo "=== 10. Test DoT, Selective Proxy, BBR, NTP, Watchdog & Dockerfile Patcher ==="
DRY_RUN=0
RESOLVED_DROPIN_FILE="${TMP_SANDBOX}/99-mirra-dns.conf"
apply_dns_dot "cloudflare" >/dev/null
assert_contains "$(cat "$RESOLVED_DROPIN_FILE")" "DNSOverTLS=yes" "DoT config enables DNSOverTLS"

DOCKER_PROXY_FILE="${TMP_SANDBOX}/99mirra-docker-proxy.conf"
APT_PROXY_FILE="${TMP_SANDBOX}/99mirra-apt-proxy"
apply_docker_proxy_only "socks5://127.0.0.1:40000" >/dev/null
apply_apt_proxy_only "http://127.0.0.1:7890" >/dev/null
assert_contains "$(cat "$DOCKER_PROXY_FILE")" "socks5://127.0.0.1:40000" "Selective Docker proxy written"
assert_contains "$(cat "$APT_PROXY_FILE")" "http://127.0.0.1:7890" "Selective APT proxy written"

SYSCTL_BBR_FILE="${TMP_SANDBOX}/99-mirra-bbr.conf"
apply_bbr_state "enable" >/dev/null
assert_contains "$(cat "$SYSCTL_BBR_FILE")" "tcp_congestion_control = bbr" "TCP BBR sysctl config written"

TIMESYNCD_DROPIN_FILE="${TMP_SANDBOX}/99-mirra-ntp.conf"
sync_server_time >/dev/null
assert_contains "$(cat "$TIMESYNCD_DROPIN_FILE")" "ir.pool.ntp.org" "NTP timesyncd config written"

WATCHDOG_CONF="${TMP_SANDBOX}/watchdog.conf"
WATCHDOG_SERVICE="${TMP_SANDBOX}/mirra-watchdog.service"
WATCHDOG_TIMER="${TMP_SANDBOX}/mirra-watchdog.timer"
configure_telegram_notify "123:TESTTOKEN" "99999" "IRAN" "https://tg-worker.example.workers.dev" "socks5://127.0.0.1:40000" >/dev/null
assert_contains "$(cat "$WATCHDOG_CONF")" "TELEGRAM_BOT_TOKEN" "Watchdog Telegram config saved"
assert_contains "$(cat "$WATCHDOG_CONF")" "https://tg-worker.example.workers.dev" "Watchdog custom Telegram API base saved"
assert_contains "$(cat "$WATCHDOG_CONF")" "socks5://127.0.0.1:40000" "Watchdog Telegram proxy saved"
# shellcheck source=/dev/null
. "$WATCHDOG_CONF"
DRY_RUN=1
tg_dry=$(send_telegram_alert "test alert" 2>&1)
assert_contains "$tg_dry" "https://tg-worker.example.workers.dev" "Telegram dry-run uses custom API base"
assert_contains "$tg_dry" "socks5://127.0.0.1:40000" "Telegram dry-run uses proxy"
DRY_RUN=0
enable_watchdog "IRAN" >/dev/null
assert_contains "$(cat "$WATCHDOG_TIMER")" "OnCalendar=daily" "Watchdog systemd timer generated"

PROJ_DIR="${TMP_SANDBOX}/proj"
mkdir -p "$PROJ_DIR"
cat <<'EOF' > "${PROJ_DIR}/Dockerfile"
FROM python:3.12-slim AS base
FROM --platform=linux/amd64 node:20-alpine
FROM ghcr.io/org/custom:latest
FROM scratch
EOF
patch_project_dockerfiles "$PROJ_DIR" "https://docker.arvancloud.ir" >/dev/null
patched_df=$(cat "${PROJ_DIR}/Dockerfile")
assert_contains "$patched_df" "FROM docker.arvancloud.ir/python:3.12-slim AS base" "Unqualified FROM rewritten"
assert_contains "$patched_df" "FROM --platform=linux/amd64 docker.arvancloud.ir/node:20-alpine" "Platform FROM rewritten"
assert_contains "$patched_df" "FROM ghcr.io/org/custom:latest" "Qualified ghcr.io FROM preserved"
assert_contains "$patched_df" "FROM scratch" "scratch FROM preserved"

uninst_out=$(bash "$ROOT_DIR/mirra.sh" --uninstall --dry-run --yes --offline 2>&1)
assert_contains "$uninst_out" "[DRY-RUN]" "CLI --uninstall --dry-run executes cleanly"

echo ""
echo "Test Summary: ${PASS} passed, ${FAIL} failed."
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
