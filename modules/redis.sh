#!/usr/bin/env bash
# =============================================================================
# modules/redis.sh — Redis Installation & WordPress Integration Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_REDIS_SH_LOADED:-}" ]] && return 0
_REDIS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
REDIS_HOST="127.0.0.1"
REDIS_PORT=6379
REDIS_MAXMEMORY_POLICY="allkeys-lru"
REDIS_CONF="/etc/redis/redis.conf"
REDIS_ENABLED=false

# ---------------------------------------------------------------------------
# Install Redis server
# ---------------------------------------------------------------------------
redis_install() {
    log_section "Redis Installation"

    if dpkg -l redis-server 2>/dev/null | grep -q '^ii'; then
        log_info "Redis already installed. Skipping."
    else
        log_step "Installing Redis server..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server || {
            log_error "Redis installation failed."
            return 1
        }
    fi

    # Install PHP Redis extension (already handled in php.sh but ensure it)
    local ver="${PHP_VERSION:-8.3}"
    if ! php -r 'echo extension_loaded("redis") ? "yes" : "no";' 2>/dev/null | grep -q yes; then
        log_step "Installing PHP Redis extension..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "php${ver}-redis" 2>/dev/null || \
            pecl install redis 2>/dev/null || \
            log_warn "PHP Redis extension install may have failed."
    fi

    systemctl enable redis-server --quiet
    systemctl start  redis-server || {
        log_error "Redis failed to start."
        return 1
    }

    log_success "Redis installed and started."
    return 0
}

# ---------------------------------------------------------------------------
# Configure Redis (bind to localhost, set memory limit)
# ---------------------------------------------------------------------------
redis_configure() {
    log_section "Redis Configuration"

    rollback_backup "${REDIS_CONF}"

    # Calculate max memory: 10% of system RAM (min 64MB)
    local redis_memory_mb=$(( SYS_RAM_MB * 10 / 100 ))
    [[ "${redis_memory_mb}" -lt 64 ]] && redis_memory_mb=64
    [[ "${redis_memory_mb}" -gt 512 ]] && redis_memory_mb=512

    log_step "Configuring Redis (${redis_memory_mb}MB max memory)..."

    # Apply settings via redis-cli or direct config manipulation
    _redis_set_conf "bind"                   "127.0.0.1 -::1"
    _redis_set_conf "port"                   "${REDIS_PORT}"
    _redis_set_conf "maxmemory"              "${redis_memory_mb}mb"
    _redis_set_conf "maxmemory-policy"       "${REDIS_MAXMEMORY_POLICY}"
    _redis_set_conf "save"                   ""  # disable RDB persistence for cache
    _redis_set_conf "appendonly"             "no"
    _redis_set_conf "timeout"                "300"
    _redis_set_conf "tcp-keepalive"          "300"
    _redis_set_conf "loglevel"               "notice"
    _redis_set_conf "databases"              "16"

    # Disable dangerous commands
    _redis_set_conf "rename-command FLUSHALL" '""'
    _redis_set_conf "rename-command FLUSHDB"  '""'
    _redis_set_conf "rename-command DEBUG"    '""'
    _redis_set_conf "rename-command CONFIG"   '""'

    systemctl restart redis-server || {
        log_error "Redis restart failed."
        return 1
    }

    log_success "Redis configured."
    return 0
}

# ---------------------------------------------------------------------------
# Internal: set a Redis config directive
# ---------------------------------------------------------------------------
_redis_set_conf() {
    local directive="$1"
    local value="$2"

    [[ -f "${REDIS_CONF}" ]] || return 0

    if grep -qE "^#?[[:space:]]*${directive//./\\.}" "${REDIS_CONF}"; then
        sed -i "s|^#*[[:space:]]*${directive}.*|${directive} ${value}|" "${REDIS_CONF}"
    else
        echo "${directive} ${value}" >> "${REDIS_CONF}"
    fi
}

# ---------------------------------------------------------------------------
# Install Redis Object Cache plugin for WordPress
# ---------------------------------------------------------------------------
redis_configure_wordpress() {
    log_section "WordPress Redis Object Cache Setup"

    [[ -f "${WP_DIR}/wp-config.php" ]] || {
        log_warn "wp-config.php not found. Skipping Redis WordPress integration."
        return 0
    }

    log_step "Installing Redis Object Cache plugin..."
    sudo -u www-data "${WP_CLI_BIN}" \
        --path="${WP_DIR}" \
        --allow-root \
        plugin install redis-cache --activate --quiet \
        2>&1 | tee -a "${LOG_FILE}" || {
        log_warn "Failed to install Redis Object Cache plugin. Continuing without it."
        return 0
    }

    log_step "Adding Redis configuration to wp-config.php..."

    # Add Redis constants to wp-config.php (before "require_once" line)
    local wp_config="${WP_DIR}/wp-config.php"
    rollback_backup "${wp_config}"

    if ! grep -q 'WP_REDIS_HOST' "${wp_config}"; then
        sed -i "/\/\* That's all/i \\
/* Redis Object Cache */\\
define( 'WP_REDIS_HOST',     '${REDIS_HOST}' );\\
define( 'WP_REDIS_PORT',     ${REDIS_PORT} );\\
define( 'WP_REDIS_DATABASE', 0 );\\
define( 'WP_REDIS_TIMEOUT',  1 );\\
define( 'WP_REDIS_READ_TIMEOUT', 1 );\\
define( 'WP_CACHE',          true );\\
" "${wp_config}"
    fi

    log_step "Enabling Redis Object Cache..."
    sudo -u www-data "${WP_CLI_BIN}" \
        --path="${WP_DIR}" \
        --allow-root \
        redis enable \
        2>&1 | tee -a "${LOG_FILE}" || \
    sudo -u www-data "${WP_CLI_BIN}" \
        --path="${WP_DIR}" \
        --allow-root \
        plugin activate redis-cache \
        2>/dev/null || true

    log_success "Redis Object Cache configured for WordPress."
    REDIS_ENABLED=true
    return 0
}

# ---------------------------------------------------------------------------
# Verify Redis is running
# ---------------------------------------------------------------------------
redis_verify() {
    log_step "Verifying Redis service..."

    if ! systemctl is-active --quiet redis-server; then
        log_error "Redis service is NOT running."
        return 1
    fi

    # Ping Redis
    local pong
    pong=$(redis-cli ping 2>/dev/null)
    if [[ "${pong}" == "PONG" ]]; then
        log_success "Redis is running and responding."
        return 0
    else
        log_error "Redis ping failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Return Redis status string (for reports)
# ---------------------------------------------------------------------------
redis_status_string() {
    if systemctl is-active --quiet redis-server 2>/dev/null; then
        local version
        version="$(redis-server --version 2>/dev/null | awk '{print $3}' | cut -d= -f2)"
        echo "Active (v${version})"
    else
        echo "Inactive"
    fi
}
