#!/usr/bin/env bash
# =============================================================================
# modules/mariadb.sh — MariaDB Installation & Configuration Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_MARIADB_SH_LOADED:-}" ]] && return 0
_MARIADB_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals (set by caller / wizard)
# ---------------------------------------------------------------------------
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wp_user}"
DB_PASS="${DB_PASS:-}"
MARIADB_CONF_DIR="/etc/mysql/mariadb.conf.d"

# Credentials are persisted here so re-runs use the same passwords
_DB_CREDS_FILE="/root/.wp-master-db-creds"

# ---------------------------------------------------------------------------
# Persist / reload generated credentials
# ---------------------------------------------------------------------------
_mariadb_save_creds() {
    cat > "${_DB_CREDS_FILE}" <<EOF
# wp-master-installer — generated MariaDB credentials
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF
    chmod 600 "${_DB_CREDS_FILE}"
    log_debug "Database credentials saved to ${_DB_CREDS_FILE}"
}

_mariadb_load_creds() {
    if [[ -f "${_DB_CREDS_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${_DB_CREDS_FILE}"
        export DB_NAME DB_USER DB_PASS
        log_debug "Database credentials loaded from ${_DB_CREDS_FILE}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Install latest stable MariaDB from the official MariaDB repo
# ---------------------------------------------------------------------------
mariadb_install() {
    log_section "MariaDB Installation (latest stable)"

    if dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
        log_info "MariaDB already installed. Skipping."
        return 0
    fi

    log_step "Adding official MariaDB repository..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apt-transport-https curl gnupg2 lsb-release 2>/dev/null

    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="mariadb-11.4" 2>&1 \
        | tee -a "${LOG_FILE}" || {
        log_warn "MariaDB repo script failed. Falling back to Ubuntu default MariaDB."
    }

    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server mariadb-client || {
        log_error "MariaDB installation failed."
        return 1
    }

    systemctl enable mariadb --quiet
    systemctl start  mariadb || { log_error "MariaDB failed to start."; return 1; }
    log_success "MariaDB installed and started."
    return 0
}

# ---------------------------------------------------------------------------
# Create WordPress database, user and grant privileges
# ---------------------------------------------------------------------------
mariadb_create_database() {
    log_section "MariaDB: Creating WordPress Database"

    # Reload persisted creds if available (handles resume runs)
    _mariadb_load_creds || true

    if [[ -z "${DB_PASS}" ]]; then
        DB_PASS="$(openssl rand -base64 24)"
        log_info "Generated database user password."
    fi

    log_step "Creating database '${DB_NAME}' and user '${DB_USER}'..."

    # DROP + CREATE ensures password always matches DB_PASS even on re-run
    mysql --user=root <<MYSQL_SETUP
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SETUP

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create database or user."
        return 1
    fi

    _mariadb_save_creds
    export DB_NAME DB_USER DB_PASS

    log_success "Database '${DB_NAME}' and user '${DB_USER}' created."
    return 0
}

# ---------------------------------------------------------------------------
# Optimise MariaDB based on available RAM
# ---------------------------------------------------------------------------
mariadb_optimize() {
    log_section "MariaDB Optimization"

    local custom_conf="${MARIADB_CONF_DIR}/99-wordpress-optimized.cnf"

    # Always read RAM directly — works even when os_detect was skipped
    local ram_mb
    ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo 0)
    [[ "${ram_mb}" -lt 128 ]] && ram_mb=512

    local buffer_pool_mb=$(( ram_mb / 2 ))
    local log_file_mb=64
    local max_connections=100

    if [[ "${ram_mb}" -ge 1024 ]]; then
        buffer_pool_mb=$(( ram_mb * 50 / 100 ))
        log_file_mb=128; max_connections=150
    fi
    if [[ "${ram_mb}" -ge 2048 ]]; then
        buffer_pool_mb=$(( ram_mb * 60 / 100 ))
        log_file_mb=256; max_connections=200
    fi
    if [[ "${ram_mb}" -ge 4096 ]]; then
        buffer_pool_mb=$(( ram_mb * 65 / 100 ))
        log_file_mb=512; max_connections=300
    fi
    if [[ "${ram_mb}" -ge 8192 ]]; then
        buffer_pool_mb=$(( ram_mb * 70 / 100 ))
        log_file_mb=1024; max_connections=500
    fi

    log_step "Writing MariaDB optimized config (${buffer_pool_mb}MB buffer pool, RAM: ${ram_mb}MB)..."

    mkdir -p "${MARIADB_CONF_DIR}"
    cat > "${custom_conf}" <<EOF
[mysqld]
# wp-master-installer — auto-generated on $(date)
# Server RAM: ${ram_mb} MB

innodb_buffer_pool_size         = ${buffer_pool_mb}M
innodb_log_file_size            = ${log_file_mb}M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = 1
innodb_read_io_threads          = 4
innodb_write_io_threads         = 4

max_connections                 = ${max_connections}
connect_timeout                 = 10
wait_timeout                    = 600
interactive_timeout             = 600

query_cache_size                = 0
query_cache_type                = 0

slow_query_log                  = 1
slow_query_log_file             = /var/log/mysql/slow-query.log
long_query_time                 = 2
log_error                       = /var/log/mysql/error.log

character_set_server            = utf8mb4
collation_server                = utf8mb4_unicode_ci
bind-address                    = 127.0.0.1

tmp_table_size                  = 64M
max_heap_table_size             = 64M
key_buffer_size                 = 32M

[client]
default-character-set           = utf8mb4

[mysql]
default-character-set           = utf8mb4
EOF

    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql 2>/dev/null || true

    systemctl restart mariadb || {
        log_warn "MariaDB restart failed after optimization. Check config."
        return 1
    }

    log_success "MariaDB optimized (buffer_pool=${buffer_pool_mb}MB, max_conn=${max_connections})."
    return 0
}

# ---------------------------------------------------------------------------
# Verify MariaDB service is running
# ---------------------------------------------------------------------------
mariadb_verify() {
    if systemctl is-active --quiet mariadb; then
        log_success "MariaDB is running."
        return 0
    else
        log_error "MariaDB is NOT running."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Return MariaDB version string (for reports)
# ---------------------------------------------------------------------------
mariadb_version_string() {
    mysql --user=root -e "SELECT VERSION();" 2>/dev/null \
        | tail -1 | tr -d '\n' || echo "unknown"
}
