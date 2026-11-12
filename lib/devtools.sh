#!/usr/bin/env bash
# Mirra - Development Ecosystems Mirror Configuration
# shellcheck disable=SC2034,SC2154
# Supports: Python (pip, uv, poetry, conda), Node (npm, yarn, pnpm, bun, nvm),
#           Go, Rust (cargo, rustup), PHP (composer), Java (maven, gradle), GitHub proxy

PROFILE_DEVTOOLS_FILE="/etc/profile.d/mirra-devtools.sh"

apply_devtools_env_profile() {
    local region="$1"
    local pip_url="${2:-${PIP_IRAN[0]}}"
    if [ "$region" = "IRAN" ]; then
        local rust_dist rust_root brew_base
        IFS='|' read -r rust_dist rust_root <<< "${RUSTUP_IRAN[0]}"
        brew_base="${BREW_IRAN[0]%/}"
        local content
        content=$(cat <<EOF
# Configured by Mirra
export PIP_INDEX_URL="${pip_url}"
export UV_DEFAULT_INDEX="${pip_url}"
export NVM_NODEJS_ORG_MIRROR="${NVM_IRAN[0]}"
export RUSTUP_DIST_SERVER="${rust_dist}"
export RUSTUP_UPDATE_ROOT="${rust_root}"
export HOMEBREW_API_DOMAIN="${brew_base}/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="${brew_base}/homebrew-bottles"
export HOMEBREW_BREW_GIT_REMOTE="${brew_base}/git/homebrew/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="${brew_base}/git/homebrew/homebrew-core.git"
EOF
)
        write_file_safe "$PROFILE_DEVTOOLS_FILE" "$content"
        log_ok "Updated ${PROFILE_DEVTOOLS_FILE} (PIP/UV, NVM, Rustup, Homebrew mirrors)."
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove ${PROFILE_DEVTOOLS_FILE}"
        else
            rm -f "$PROFILE_DEVTOOLS_FILE"
            log_ok "Removed ${PROFILE_DEVTOOLS_FILE} (restored official NVM/Rustup env)."
        fi
    fi
}

apply_pip_mirror() {
    local url="$1"
    local host
    host=$(echo "$url" | awk -F/ '{print $3}')
    local pip_content
    pip_content=$(cat <<EOF
# Configured by Mirra
[global]
index-url = ${url}
trusted-host = ${host}
timeout = 30
EOF
)
    # Apply system-wide so both root and regular users benefit
    backup_file "/etc/pip.conf"
    write_file_safe "/etc/pip.conf" "$pip_content"

    get_target_user
    if [ "$TARGET_USER" != "root" ]; then
        local user_pip="${TARGET_HOME}/.pip/pip.conf"
        backup_file "$user_pip"
        write_file_safe "$user_pip" "$pip_content"
        if [ "$DRY_RUN" -eq 0 ]; then
            chown -R "${TARGET_USER}:" "${TARGET_HOME}/.pip" 2>/dev/null || true
        fi
    fi

    # Also configure uv if installed
    if command -v uv >/dev/null 2>&1 || [ -d "${TARGET_HOME}/.config/uv" ]; then
        local uv_conf="/etc/uv/uv.toml"
        backup_file "$uv_conf"
        write_file_safe "$uv_conf" "$(printf '[[index]]\nurl = "%s"\ndefault = true' "$url")"
        log_ok "Also configured uv index (${url})."
    fi

    log_ok "Applied Python Pip mirror (${url}) system-wide and for ${TARGET_USER}."
}

configure_pip_auto() {
    local region="$1"
    if [ "$region" = "IRAN" ]; then
        if benchmark_mirrors PIP_IRAN "" "http" 1; then
            apply_pip_mirror "${SORTED_MIRRORS[0]}"
        else
            apply_pip_mirror "${PIP_IRAN[0]}"
        fi
    else
        apply_pip_mirror "${PIP_GLOBAL[0]}"
    fi
}

apply_npm_family_mirror() {
    local url="$1"
    get_target_user
    local applied=0

    if command -v npm >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would set npm registry to ${url} for ${TARGET_USER}"
        else
            npm config set registry "$url" >/dev/null 2>&1 || true
            run_as_target_user npm config set registry "$url" >/dev/null 2>&1 || true
        fi
        log_ok "NPM registry set to ${url}"
        applied=1
    fi

    if command -v yarn >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would set yarn registry to ${url}"
        else
            run_as_target_user yarn config set registry "$url" >/dev/null 2>&1 || true
        fi
        log_ok "Yarn registry set to ${url}"
        applied=1
    fi

    if command -v pnpm >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would set pnpm registry to ${url}"
        else
            run_as_target_user pnpm config set registry "$url" >/dev/null 2>&1 || true
        fi
        log_ok "pnpm registry set to ${url}"
        applied=1
    fi

    if command -v bun >/dev/null 2>&1; then
        local bunfig="${TARGET_HOME}/.bunfig.toml"
        backup_file "$bunfig"
        write_file_safe "$bunfig" "$(printf '[install]\nregistry = "%s"' "$url")"
        log_ok "Bun registry set to ${url}"
        applied=1
    fi

    if [ "$applied" -eq 0 ]; then
        log_warn "No Node.js package manager (npm/yarn/pnpm/bun) detected."
    fi
}

apply_go_mirror() {
    local goproxy="$1"
    if ! command -v go >/dev/null 2>&1; then
        log_warn "Go is not installed."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would set GOPROXY=${goproxy} for ${TARGET_USER}"
        return 0
    fi
    go env -w "GOPROXY=${goproxy}" >/dev/null 2>&1 || true
    run_as_target_user go env -w "GOPROXY=${goproxy}" >/dev/null 2>&1 || true
    log_ok "Golang GOPROXY set to ${goproxy}"
}

apply_cargo_mirror() {
    local region="$1"
    get_target_user
    local cargo_cfg="${TARGET_HOME}/.cargo/config.toml"
    backup_file "$cargo_cfg"
    if [ "$region" = "IRAN" ]; then
        local content
        content=$(cat <<'EOF'
# Configured by Mirra
[source.crates-io]
replace-with = 'rsproxy-sparse'

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[net]
git-fetch-with-cli = true
EOF
)
        write_file_safe "$cargo_cfg" "$content"
        [ "$DRY_RUN" -eq 0 ] && [ "$TARGET_USER" != "root" ] && chown -R "${TARGET_USER}:" "${TARGET_HOME}/.cargo" 2>/dev/null || true
        apply_devtools_env_profile "IRAN"
        log_ok "Cargo crates.io & Rustup mirrors configured (${cargo_cfg})."
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would restore default crates.io in ${cargo_cfg}"
        else
            rm -f "$cargo_cfg"
            log_ok "Restored default Cargo crates.io registry."
        fi
    fi
}

apply_conda_mirror() {
    local region="$1"
    get_target_user
    local conda_rc="${TARGET_HOME}/.condarc"
    backup_file "$conda_rc"
    if [ "$region" = "IRAN" ]; then
        local base="${CONDA_IRAN[0]%/}"
        local content
        content=$(cat <<EOF
# Configured by Mirra
channels:
  - defaults
show_channel_urls: true
default_channels:
  - ${base}/pkgs/main
  - ${base}/pkgs/r
  - ${base}/pkgs/msys2
custom_channels:
  conda-forge: ${base}/cloud
  pytorch: ${base}/cloud
EOF
)
        write_file_safe "$conda_rc" "$content"
        [ "$DRY_RUN" -eq 0 ] && [ "$TARGET_USER" != "root" ] && chown "${TARGET_USER}:" "$conda_rc" 2>/dev/null || true
        log_ok "Conda/Mamba mirror configured at ${conda_rc}"
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove Mirra Conda mirror from ${conda_rc}"
        else
            rm -f "$conda_rc"
            log_ok "Restored default Conda channels."
        fi
    fi
}

apply_java_mirror() {
    local region="$1"
    get_target_user
    local m2_xml="${TARGET_HOME}/.m2/settings.xml"
    local gradle_init="${TARGET_HOME}/.gradle/init.d/mirra.gradle"
    backup_file "$m2_xml"
    backup_file "$gradle_init"

    if [ "$region" = "IRAN" ]; then
        local m2_content
        m2_content=$(cat <<EOF
<!-- Configured by Mirra -->
<settings>
  <mirrors>
    <mirror>
      <id>mirra-aliyun</id>
      <mirrorOf>central</mirrorOf>
      <name>Mirra Public Maven Mirror</name>
      <url>${MAVEN_IRAN[0]}</url>
    </mirror>
  </mirrors>
</settings>
EOF
)
        local gradle_content
        gradle_content=$(cat <<EOF
// Configured by Mirra
allprojects {
    repositories {
        maven { url '${MAVEN_IRAN[0]}' }
        mavenCentral()
    }
}
EOF
)
        write_file_safe "$m2_xml" "$m2_content"
        write_file_safe "$gradle_init" "$gradle_content"
        if [ "$DRY_RUN" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
            chown -R "${TARGET_USER}:" "${TARGET_HOME}/.m2" "${TARGET_HOME}/.gradle" 2>/dev/null || true
        fi
        log_ok "Maven (${m2_xml}) and Gradle (${gradle_init}) mirrors configured."
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove Mirra Maven/Gradle mirror configs"
        else
            rm -f "$m2_xml" "$gradle_init"
            log_ok "Restored default Maven & Gradle repositories."
        fi
    fi
}

apply_composer_mirror() {
    local region="$1"
    if ! command -v composer >/dev/null 2>&1; then
        log_warn "PHP Composer is not installed."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would update Composer global packagist mirror (${region})"
        return 0
    fi
    if [ "$region" = "IRAN" ]; then
        run_as_target_user composer config -g repo.packagist composer "${COMPOSER_IRAN[0]}" >/dev/null 2>&1 || true
        log_ok "Composer Packagist mirror set to ${COMPOSER_IRAN[0]}"
    else
        run_as_target_user composer config -g --unset repos.packagist >/dev/null 2>&1 || true
        log_ok "Composer restored to official Packagist."
    fi
}

apply_ruby_mirror() {
    local region="$1"
    if ! command -v gem >/dev/null 2>&1; then
        log_warn "Ruby (gem) is not installed."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Would update RubyGems/Bundler mirror (${region})"
        return 0
    fi
    if [ "$region" = "IRAN" ]; then
        run_as_target_user gem sources --add "${RUBY_IRAN[0]}" --remove https://rubygems.org/ >/dev/null 2>&1 || true
        if command -v bundle >/dev/null 2>&1; then
            run_as_target_user bundle config mirror.https://rubygems.org "${RUBY_IRAN[0]}" >/dev/null 2>&1 || true
        fi
        log_ok "RubyGems/Bundler mirror set to ${RUBY_IRAN[0]}"
    else
        run_as_target_user gem sources --add https://rubygems.org/ --remove "${RUBY_IRAN[0]}" >/dev/null 2>&1 || true
        if command -v bundle >/dev/null 2>&1; then
            run_as_target_user bundle config --delete mirror.https://rubygems.org >/dev/null 2>&1 || true
        fi
        log_ok "RubyGems restored to official rubygems.org."
    fi
}

apply_nuget_mirror() {
    local region="$1"
    get_target_user
    local nuget_cfg="${TARGET_HOME}/.nuget/NuGet/NuGet.Config"
    backup_file "$nuget_cfg"
    if [ "$region" = "IRAN" ]; then
        local content
        content=$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Configured by Mirra -->
<configuration>
  <packageSources>
    <clear />
    <add key="MirraNuGet" value="${NUGET_IRAN[0]}" protocolVersion="3" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
EOF
)
        write_file_safe "$nuget_cfg" "$content"
        [ "$DRY_RUN" -eq 0 ] && [ "$TARGET_USER" != "root" ] && chown -R "${TARGET_USER}:" "${TARGET_HOME}/.nuget" 2>/dev/null || true
        log_ok ".NET NuGet mirror configured at ${nuget_cfg}"
    else
        local content
        content=$(cat <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
EOF
)
        write_file_safe "$nuget_cfg" "$content"
        log_ok ".NET NuGet restored to official nuget.org."
    fi
}

apply_github_proxy() {
    local action="$1" # enable | disable
    if ! command -v git >/dev/null 2>&1; then
        log_warn "Git is not installed."
        return 0
    fi
    local proxy="${GITHUB_PROXIES[0]}"
    if [ "$action" = "enable" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would configure git url.${proxy}https://github.com/.insteadOf https://github.com/"
        else
            run_as_target_user git config --global "url.${proxy}https://github.com/.insteadOf" "https://github.com/"
            log_ok "GitHub proxy acceleration enabled via ${proxy}"
        fi
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_dry "Would remove GitHub proxy insteadOf rule from git config"
        else
            run_as_target_user git config --global --remove-section "url.${proxy}https://github.com/" 2>/dev/null || true
            log_ok "GitHub proxy disabled (direct github.com)."
        fi
    fi
}

configure_devtools_auto() {
    local region="$1"
    configure_pip_auto "$region"
    if [ "$region" = "IRAN" ]; then
        apply_npm_family_mirror "${NPM_IRAN[0]}"
        apply_go_mirror "${GO_IRAN[0]}"
        apply_devtools_env_profile "IRAN" "${PIP_IRAN[0]}"
        command -v cargo >/dev/null 2>&1 && apply_cargo_mirror "IRAN" || true
        command -v composer >/dev/null 2>&1 && apply_composer_mirror "IRAN" || true
        (command -v conda >/dev/null 2>&1 || command -v mamba >/dev/null 2>&1) && apply_conda_mirror "IRAN" || true
        (command -v mvn >/dev/null 2>&1 || command -v gradle >/dev/null 2>&1) && apply_java_mirror "IRAN" || true
        command -v gem >/dev/null 2>&1 && apply_ruby_mirror "IRAN" || true
        command -v dotnet >/dev/null 2>&1 && apply_nuget_mirror "IRAN" || true
    else
        apply_npm_family_mirror "${NPM_GLOBAL[0]}"
        apply_go_mirror "${GO_GLOBAL[0]}"
        apply_devtools_env_profile "GLOBAL"
        command -v cargo >/dev/null 2>&1 && apply_cargo_mirror "GLOBAL" || true
        command -v composer >/dev/null 2>&1 && apply_composer_mirror "GLOBAL" || true
        (command -v conda >/dev/null 2>&1 || command -v mamba >/dev/null 2>&1) && apply_conda_mirror "GLOBAL" || true
        (command -v mvn >/dev/null 2>&1 || command -v gradle >/dev/null 2>&1) && apply_java_mirror "GLOBAL" || true
        command -v gem >/dev/null 2>&1 && apply_ruby_mirror "GLOBAL" || true
        command -v dotnet >/dev/null 2>&1 && apply_nuget_mirror "GLOBAL" || true
    fi
}

menu_pip() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Submenu: Python (Pip / uv) ]${NC}\n"
        echo "1) Benchmark & apply fastest Pip/uv mirror (Iran/Fast)"
        echo "2) Restore Official PyPI (https://pypi.org/simple/)"
        echo "3) View current /etc/pip.conf"
        echo -e "${BRED}0) Back${NC}\n"

        local choice=""
        read_input "Select option [0-3]: " choice "0"
        case "$choice" in
            1)
                if benchmark_mirrors PIP_IRAN "" "http" 0; then
                    echo -e "\n${BOLD}Select a Pip mirror:${NC}"
                    local i
                    for i in "${!SORTED_MIRRORS[@]}"; do
                        echo -e "  ${CYAN}$((i + 1)))${NC} ${SORTED_MIRRORS[$i]} ${GREEN}(${SORTED_LATENCIES[$i]} ms)${NC}"
                    done
                    echo -e "  ${BRED}0) Cancel${NC}\n"
                    local m=""
                    read_input "Select [0-${#SORTED_MIRRORS[@]}]: " m "0"
                    if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge 1 ] && [ "$m" -le "${#SORTED_MIRRORS[@]}" ]; then
                        apply_pip_mirror "${SORTED_MIRRORS[$((m - 1))]}"
                    fi
                else
                    log_err "No reachable Pip mirrors found."
                fi
                pause_screen
                ;;
            2) apply_pip_mirror "${PIP_GLOBAL[0]}"; pause_screen ;;
            3) cat /etc/pip.conf 2>/dev/null || log_warn "/etc/pip.conf not found."; pause_screen ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}

menu_npm() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Submenu: Node.js (npm / yarn / pnpm / bun) ]${NC}\n"
        echo "1) Apply Fast Mirror (${NPM_IRAN[0]})"
        echo "2) Restore Official Registry (${NPM_GLOBAL[0]})"
        echo "3) View current NPM registry"
        echo -e "${BRED}0) Back${NC}\n"

        local choice=""
        read_input "Select option [0-3]: " choice "0"
        case "$choice" in
            1) apply_npm_family_mirror "${NPM_IRAN[0]}"; pause_screen ;;
            2) apply_npm_family_mirror "${NPM_GLOBAL[0]}"; pause_screen ;;
            3)
                if command -v npm >/dev/null 2>&1; then
                    echo "Root npm registry: $(npm config get registry)"
                    get_target_user
                    [ "$TARGET_USER" != "root" ] && echo "User ($TARGET_USER) npm registry: $(run_as_target_user npm config get registry)"
                else
                    log_warn "npm is not installed."
                fi
                pause_screen
                ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}

menu_go() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Submenu: Golang GOPROXY ]${NC}\n"
        echo "1) Apply Fast GOPROXY (${GO_IRAN[0]})"
        echo "2) Restore Official GOPROXY (${GO_GLOBAL[0]})"
        echo "3) View current GOPROXY"
        echo -e "${BRED}0) Back${NC}\n"

        local choice=""
        read_input "Select option [0-3]: " choice "0"
        case "$choice" in
            1) apply_go_mirror "${GO_IRAN[0]}"; pause_screen ;;
            2) apply_go_mirror "${GO_GLOBAL[0]}"; pause_screen ;;
            3)
                if command -v go >/dev/null 2>&1; then
                    run_as_target_user go env GOPROXY
                else
                    log_warn "Go is not installed."
                fi
                pause_screen
                ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}

menu_dev_tools() {
    while true; do
        print_banner
        echo -e "${YELLOW}[ Section 3: Development Ecosystems ]${NC}\n"
        echo "1) Python (Pip / uv / Poetry env)"
        echo "2) Node.js (npm / yarn / pnpm / bun)"
        echo "3) Golang (GOPROXY)"
        echo "4) Rust (Cargo crates.io & Rustup mirror)"
        echo "5) PHP (Composer Packagist mirror)"
        echo "6) Conda / Mamba channels (.condarc)"
        echo "7) Java (Maven & Gradle mirrors)"
        echo "8) NVM, Rustup & Linuxbrew Env (/etc/profile.d/mirra-devtools.sh)"
        echo "9) Ruby (RubyGems / Bundler)"
        echo "10) .NET (NuGet.Config)"
        echo "11) Git / GitHub Clone Proxy (Enable / Disable)"
        echo -e "${BRED}0) Back to Main Menu${NC}\n"

        local choice=""
        read_input "Select option [0-11]: " choice "0"
        case "$choice" in
            1) menu_pip ;;
            2) menu_npm ;;
            3) menu_go ;;
            4)
                echo "1) Enable Rust Cargo/Rustup mirror  2) Restore official"
                local rc=""
                read_input "Select [1-2]: " rc "0"
                [ "$rc" = "1" ] && apply_cargo_mirror "IRAN"
                [ "$rc" = "2" ] && apply_cargo_mirror "GLOBAL"
                pause_screen
                ;;
            5)
                echo "1) Enable Composer mirror  2) Restore official"
                local cc=""
                read_input "Select [1-2]: " cc "0"
                [ "$cc" = "1" ] && apply_composer_mirror "IRAN"
                [ "$cc" = "2" ] && apply_composer_mirror "GLOBAL"
                pause_screen
                ;;
            6)
                echo "1) Enable Conda/Mamba mirror  2) Restore official"
                local kc=""
                read_input "Select [1-2]: " kc "0"
                [ "$kc" = "1" ] && apply_conda_mirror "IRAN"
                [ "$kc" = "2" ] && apply_conda_mirror "GLOBAL"
                pause_screen
                ;;
            7)
                echo "1) Enable Maven & Gradle mirrors  2) Restore official"
                local jc=""
                read_input "Select [1-2]: " jc "0"
                [ "$jc" = "1" ] && apply_java_mirror "IRAN"
                [ "$jc" = "2" ] && apply_java_mirror "GLOBAL"
                pause_screen
                ;;
            8)
                echo "1) Enable NVM/Rustup/Pip env profile  2) Remove env profile"
                local ec=""
                read_input "Select [1-2]: " ec "0"
                [ "$ec" = "1" ] && apply_devtools_env_profile "IRAN"
                [ "$ec" = "2" ] && apply_devtools_env_profile "GLOBAL"
                pause_screen
                ;;
            9)
                echo "1) Enable RubyGems/Bundler mirror  2) Restore official"
                local rbc=""
                read_input "Select [1-2]: " rbc "0"
                [ "$rbc" = "1" ] && apply_ruby_mirror "IRAN"
                [ "$rbc" = "2" ] && apply_ruby_mirror "GLOBAL"
                pause_screen
                ;;
            10)
                echo "1) Enable .NET NuGet mirror  2) Restore official"
                local nc=""
                read_input "Select [1-2]: " nc "0"
                [ "$nc" = "1" ] && apply_nuget_mirror "IRAN"
                [ "$nc" = "2" ] && apply_nuget_mirror "GLOBAL"
                pause_screen
                ;;
            11)
                echo "1) Enable GitHub proxy  2) Disable GitHub proxy"
                local gc=""
                read_input "Select [1-2]: " gc "0"
                [ "$gc" = "1" ] && apply_github_proxy "enable"
                [ "$gc" = "2" ] && apply_github_proxy "disable"
                pause_screen
                ;;
            0) return ;;
            *) log_err "Invalid option!"; sleep 1 ;;
        esac
    done
}
