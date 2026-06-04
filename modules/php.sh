#!/usr/bin/env bash
# =============================================================================
# modules/php.sh — PHP Installation & Configuration Module
# wp-master-installer
# =============================================================================

[[ -n "${_PHP_SH_LOADED:-}" ]] && return 0
_PHP_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_FPM_SOCKET=""   # populated by php_get_socket()
PHP_INI_PATH=""     # populated after install

# ---------------------------------------------------------------------------
# Resolve "latest" to a specific version
# ---------------------------------------------------------------------------
php_resolve_version() {
    case "${PHP_VERSION,,}" in
        latest|stable) PHP_VERSION="8.3" ;;
        8.1|8.2|8.3)   : ;;
        *)
            log_warn "Unknown PHP version '${PHP_VERSION}'. Defaulting to 8.3."
            PHP_VERSION="8.3"
            ;;
    esac
    log_info "PHP version selected: ${PHP_VERSION}"
}

# ---------------------------------------------------------------------------
# Add Ondřej Surý PPA (supports 8.1 / 8.2 / 8.3 on all supported Ubuntu)
# ---------------------------------------------------------------------------
php_add_repo() {
    if [[ -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list ]] \
        || [[ -f /etc/apt/sources.list.d/ondrej-php.list ]]; then
        log_info "PHP PPA already configured."
        return 0
    fi

    log_step "Adding Ondřej PHP PPA..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php 2>&1 | tee -a "${LOG_FILE}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    log_success "PHP PPA added."
}

# ---------------------------------------------------------------------------
# Install PHP and required extensions
# ---------------------------------------------------------------------------
php_install() {
    log_section "PHP ${PHP_VERSION} Installation"

    php_resolve_version
    php_add_repo || return 1

    local ver="${PHP_VERSION}"
    local packages=(
        "php${ver}"
        "php${ver}-fpm"
        "php${ver}-cli"
        "php${ver}-common"
        "php${ver}-curl"
        "php${ver}-mysql"
        "php${ver}-xml"
        "php${ver}-gd"
        "php${ver}-mbstring"
        "php${ver}-intl"
        "php${ver}-bcmath"
        "php${ver}-zip"
        "php${ver}-imagick"
        "php${ver}-redis"
        "php${ver}-soap"
        "php${ver}-opcache"
        "php${ver}-readline"
    )

    log_step "Installing PHP ${ver} packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" || {
        log_error "PHP ${ver} installation failed."
        return 1
    }

    systemctl enable  "php${ver}-fpm" --quiet
    systemctl restart "php${ver}-fpm" || {
        log_error "PHP-FPM failed to start."
        return 1
    }

    # Resolve paths
    PHP_INI_PATH="/etc/php/${ver}/fpm/php.ini"
    PHP_FPM_SOCKET="unix:/run/php/php${ver}-fpm.sock"

    log_success "PHP ${ver} installed."
    return 0
}

# ---------------------------------------------------------------------------
# Return the PHP-FPM socket path (auto-detected)
# ---------------------------------------------------------------------------
php_get_socket() {
    local ver="${PHP_VERSION:-8.3}"

    # Check common socket paths
    local sockets=(
        "/run/php/php${ver}-fpm.sock"
        "/var/run/php/php${ver}-fpm.sock"
        "/run/php${ver}-fpm.sock"
    )

    for sock in "${sockets[@]}"; do
        if [[ -S "${sock}" ]]; then
            PHP_FPM_SOCKET="unix:${sock}"
            echo "unix:${sock}"
            return 0
        fi
    done

    # Fallback: parse pool config
    local pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
    if [[ -f "${pool_conf}" ]]; then
        local sock_from_conf
        sock_from_conf=$(grep -E '^listen\s*=' "${pool_conf}" | awk -F= '{print $2}' | tr -d ' ')
        if [[ -n "${sock_from_conf}" ]]; then
            PHP_FPM_SOCKET="unix:${sock_from_conf}"
            echo "unix:${sock_from_conf}"
            return 0
        fi
    fi

    # Last resort
    PHP_FPM_SOCKET="unix:/run/php/php${ver}-fpm.sock"
    echo "${PHP_FPM_SOCKET}"
}

# ---------------------------------------------------------------------------
# Configure PHP (php.ini + FPM pool) optimized for available RAM
# ---------------------------------------------------------------------------
php_configure() {
    log_section "PHP Configuration & Optimization"

    local ver="${PHP_VERSION}"
    local fpm_ini="/etc/php/${ver}/fpm/php.ini"
    local cli_ini="/etc/php/${ver}/cli/php.ini"
    local pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
    local opcache_conf="/etc/php/${ver}/fpm/conf.d/10-opcache.ini"

    rollback_backup "${fpm_ini}"
    rollback_backup "${pool_conf}"

    # ---- php.ini values based on RAM ----
    local memory_limit="256M"
    local max_children=5
    local start_servers=2
    local min_spare=1
    local max_spare=3

    if [[ "${SYS_RAM_MB:-512}" -ge 1024 ]]; then
        memory_limit="256M"; max_children=10; start_servers=3; min_spare=2; max_spare=5
    fi
    if [[ "${SYS_RAM_MB:-512}" -ge 2048 ]]; then
        memory_limit="512M"; max_children=20; start_servers=5; min_spare=5; max_spare=10
    fi
    if [[ "${SYS_RAM_MB:-512}" -ge 4096 ]]; then
        memory_limit="1024M"; max_children=40; start_servers=10; min_spare=10; max_spare=20
    fi
    if [[ "${SYS_RAM_MB:-512}" -ge 8192 ]]; then
        memory_limit="2048M"; max_children=80; start_servers=20; min_spare=15; max_spare=35
    fi

    log_step "Writing PHP-FPM php.ini settings..."
    _php_set_ini "${fpm_ini}" "memory_limit"          "${memory_limit}"
    _php_set_ini "${fpm_ini}" "upload_max_filesize"    "64M"
    _php_set_ini "${fpm_ini}" "post_max_size"          "64M"
    _php_set_ini "${fpm_ini}" "max_execution_time"     "300"
    _php_set_ini "${fpm_ini}" "max_input_time"         "300"
    _php_set_ini "${fpm_ini}" "max_input_vars"         "5000"
    _php_set_ini "${fpm_ini}" "date.timezone"          "UTC"
    _php_set_ini "${fpm_ini}" "expose_php"             "Off"
    _php_set_ini "${fpm_ini}" "display_errors"         "Off"
    _php_set_ini "${fpm_ini}" "log_errors"             "On"
    _php_set_ini "${fpm_ini}" "error_log"              "/var/log/php${ver}-fpm-errors.log"
    _php_set_ini "${fpm_ini}" "cgi.fix_pathinfo"       "0"
    _php_set_ini "${fpm_ini}" "file_uploads"           "On"

    # Mirror key settings to CLI
    _php_set_ini "${cli_ini}" "memory_limit"           "-1"
    _php_set_ini "${cli_ini}" "max_execution_time"     "0"
    _php_set_ini "${cli_ini}" "upload_max_filesize"    "64M"
    _php_set_ini "${cli_ini}" "post_max_size"          "64M"
    _php_set_ini "${cli_ini}" "date.timezone"          "UTC"

    log_step "Configuring OPcache..."
    cat > "${opcache_conf}" <<EOF
[opcache]
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.fast_shutdown=1
opcache.validate_timestamps=1
opcache.huge_code_pages=0
opcache.jit=off
EOF

    log_step "Configuring PHP-FPM pool www.conf..."
    rollback_backup "${pool_conf}"

    # Determine the socket path
    local sock_path="/run/php/php${ver}-fpm.sock"

    cat > "${pool_conf}" <<EOF
[www]
user  = www-data
group = www-data

listen = ${sock_path}
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

pm                   = dynamic
pm.max_children      = ${max_children}
pm.start_servers     = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests      = 500

; Logging
access.log  = /var/log/php${ver}-fpm-access.log
slowlog     = /var/log/php${ver}-fpm-slow.log
request_slowlog_timeout = 10s

; Environment
env[HOSTNAME]      = \$HOSTNAME
env[PATH]          = /usr/local/bin:/usr/bin:/bin
env[TMP]           = /tmp
env[TMPDIR]        = /tmp
env[TEMP]          = /tmp

; PHP settings override
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size]       = 64M
php_admin_value[memory_limit]        = ${memory_limit}
php_admin_flag[display_errors]       = off
php_admin_value[error_log]           = /var/log/php${ver}-fpm-errors.log
php_admin_flag[log_errors]           = on
php_value[session.save_handler]      = files
php_value[session.save_path]         = /var/lib/php/sessions
php_value[soap.wsdl_cache_dir]       = /tmp
EOF

    # Ensure session dir exists
    mkdir -p /var/lib/php/sessions
    chown www-data:www-data /var/lib/php/sessions
    chmod 733 /var/lib/php/sessions

    # Restart PHP-FPM
    systemctl restart "php${ver}-fpm" || {
        log_error "PHP-FPM restart failed after configuration."
        return 1
    }

    PHP_FPM_SOCKET="unix:${sock_path}"
    log_success "PHP ${ver} configured (memory_limit=${memory_limit}, pm.max_children=${max_children})."
    return 0
}

# ---------------------------------------------------------------------------
# Internal: set a php.ini value (replaces or appends)
# ---------------------------------------------------------------------------
_php_set_ini() {
    local ini_file="$1"
    local key="$2"
    local value="$3"

    [[ -f "${ini_file}" ]] || return 0

    if grep -qE "^;?[[:space:]]*${key}[[:space:]]*=" "${ini_file}"; then
        sed -i "s|^;*[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${ini_file}"
    else
        echo "${key} = ${value}" >> "${ini_file}"
    fi
}

# ---------------------------------------------------------------------------
# Verify PHP-FPM is running
# ---------------------------------------------------------------------------
php_verify() {
    local ver="${PHP_VERSION}"
    if systemctl is-active --quiet "php${ver}-fpm"; then
        log_success "PHP ${ver}-FPM is running."
        return 0
    else
        log_error "PHP ${ver}-FPM is NOT running."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Return PHP version string (for reports)
# ---------------------------------------------------------------------------
php_version_string() {
    php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown"
}
