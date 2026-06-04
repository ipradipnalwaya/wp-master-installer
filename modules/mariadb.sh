#!/usr/bin/env bash
# =============================================================================
# modules/mariadb.sh — MariaDB Installation & Configuration Module
# wp-master-installer
# =============================================================================

[[ -n "${_MARIADB_SH_LOADED:-}" ]] && return 0
_MARIADB_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals (set by caller / wizard)
# ---------------------------------------------------------------------------
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wp_user}"
DB_PASS="${DB_PASS:-}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"  # generated if empty
MARIADB_CONF_DIR="/etc/mysql/mariadb.conf.d"

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

    # Fetch the MariaDB repo setup script for the current Ubuntu release
    local codename
    codename="$(lsb_release -sc)"

    # Use the MariaDB repo setup script (auto-selects latest stable)
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
# Secure MariaDB installation (non-interactive equivalent of mysql_secure_installation)
# ---------------------------------------------------------------------------
mariadb_secure() {
    log_section "MariaDB Security Hardening"

    # Generate root password if not provided
    if [[ -z "${DB_ROOT_PASS}" ]]; then
        DB_ROOT_PASS="$(openssl rand -base64 32)"
        log_info "Generated MariaDB root password."
    fi

    log_step "Setting root password and removing insecure defaults..."

    mysql --user=root 2>/dev/null <<MYSQL_SECURE || true
-- Set root password (unix_socket + password)
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASS}') OR unix_socket;
FLUSH PRIVILEGES;

-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Remove remote root login
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
MYSQL_SECURE

    # Write a temporary .my.cnf for root so subsequent calls work
    cat > /root/.my.cnf <<EOF
[client]
user=root
password=${DB_ROOT_PASS}
EOF
    chmod 600 /root/.my.cnf

    log_success "MariaDB secured."
    return 0
}

# ---------------------------------------------------------------------------
# Create WordPress database, user and grant privileges
# ---------------------------------------------------------------------------
mariadb_create_database() {
    log_section "MariaDB: Creating WordPress Database"

    if [[ -z "${DB_PASS}" ]]; then
        DB_PASS="$(openssl rand -base64 24)"
        log_info "Generated database user password."
    fi

    log_step "Creating database '${DB_NAME}' and user '${DB_USER}'..."

    # Use DROP USER IF EXISTS + CREATE to ensure the password is always correct,
    # even if a previous partial run left the user with a different password.
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

    log_success "Database '${DB_NAME}' and user '${DB_USER}' created."
    return 0
}

# ---------------------------------------------------------------------------
# Verify database access
# ---------------------------------------------------------------------------
mariadb_verify_access() {
    log_step "Verifying database access..."

    # Try TCP first (explicit protocol avoids socket auth conflicts),
    # then fall back to socket/default if TCP is not listening.
    local connect_ok=0

    if mysql \
            --user="${DB_USER}" \
            --password="${DB_PASS}" \
            --host=127.0.0.1 \
            --protocol=TCP \
            "${DB_NAME}" \
            -e "SELECT 1;" &>/dev/null; then
        connect_ok=1
    elif mysql \
            --user="${DB_USER}" \
            --password="${DB_PASS}" \
            --host=localhost \
            "${DB_NAME}" \
            -e "SELECT 1;" &>/dev/null; then
        connect_ok=1
    fi

    if [[ "${connect_ok}" -eq 1 ]]; then
        log_success "Database access verified for user '${DB_USER}'."
        return 0
    fi

    # Diagnostics — help narrow down root cause without exposing the password
    log_error "Cannot connect to database '${DB_NAME}' as '${DB_USER}'."
    log_info  "Diagnostic: checking if user exists in mysql.user..."
    mysql --user=root -e \
        "SELECT User, Host, plugin FROM mysql.user WHERE User='${DB_USER}';" \
        2>/dev/null || true
    log_info  "Diagnostic: checking grants..."
    mysql --user=root -e \
        "SHOW GRANTS FOR '${DB_USER}'@'localhost';" \
        2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Optimise MariaDB based on available RAM
# ---------------------------------------------------------------------------
mariadb_optimize() {
    log_section "MariaDB Optimization"

    local custom_conf="${MARIADB_CONF_DIR}/99-wordpress-optimized.cnf"
    rollback_backup "${custom_conf}" 2>/dev/null || true

    # Calculate InnoDB buffer pool (50% of RAM)
    local ram_mb="${SYS_RAM_MB:-512}"
    local buffer_pool_mb=$(( ram_mb / 2 ))
    local log_file_mb=64
    local max_connections=100
    local query_cache_size=0  # deprecated in newer MariaDB — keep 0

    if [[ "${ram_mb}" -ge 1024 ]]; then
        buffer_pool_mb=$(( ram_mb * 50 / 100 ))
        log_file_mb=128
        max_connections=150
    fi
    if [[ "${ram_mb}" -ge 2048 ]]; then
        buffer_pool_mb=$(( ram_mb * 60 / 100 ))
        log_file_mb=256
        max_connections=200
    fi
    if [[ "${ram_mb}" -ge 4096 ]]; then
        buffer_pool_mb=$(( ram_mb * 65 / 100 ))
        log_file_mb=512
        max_connections=300
    fi
    if [[ "${ram_mb}" -ge 8192 ]]; then
        buffer_pool_mb=$(( ram_mb * 70 / 100 ))
        log_file_mb=1024
        max_connections=500
    fi

    log_step "Writing MariaDB optimized config (${buffer_pool_mb}MB buffer pool)..."

    mkdir -p "${MARIADB_CONF_DIR}"
    cat > "${custom_conf}" <<EOF
[mysqld]
# -----------------------------------------------------------
# WordPress / wp-master-installer optimized configuration
# Generated: $(date)
# Server RAM: ${ram_mb} MB
# -----------------------------------------------------------

# InnoDB
innodb_buffer_pool_size         = ${buffer_pool_mb}M
innodb_log_file_size            = ${log_file_mb}M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = 1
innodb_read_io_threads          = 4
innodb_write_io_threads         = 4
innodb_io_capacity              = 400

# Connections
max_connections                 = ${max_connections}
connect_timeout                 = 10
wait_timeout                    = 600
interactive_timeout             = 600

# Query cache (disabled — use Redis instead)
query_cache_size                = 0
query_cache_type                = 0

# Logging
slow_query_log                  = 1
slow_query_log_file             = /var/log/mysql/slow-query.log
long_query_time                 = 2
log_error                       = /var/log/mysql/error.log

# Character set
character_set_server            = utf8mb4
collation_server                = utf8mb4_unicode_ci

# Networking
bind-address                    = 127.0.0.1

# Temp tables
tmp_table_size                  = 64M
max_heap_table_size             = 64M

# MyISAM (minimal — mostly for system tables)
key_buffer_size                 = 32M
myisam_recover_options          = BACKUP

[client]
default-character-set           = utf8mb4

[mysql]
default-character-set           = utf8mb4
EOF

    # Ensure log directory exists
    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql 2>/dev/null || true

    # Restart MariaDB
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
        | tail -1 \
        | tr -d '\n' \
        || echo "unknown"
}
