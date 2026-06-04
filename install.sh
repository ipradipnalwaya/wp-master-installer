#!/usr/bin/env bash
# =============================================================================
# install.sh — WP Master Installer
# Universal Ubuntu WordPress Stack Installer
#
# Supported: Ubuntu 20.04 LTS, 22.04 LTS, 24.04 LTS
# Usage:
#   Interactive  : sudo bash install.sh
#   Unattended   : sudo bash install.sh --unattended --config /path/to/config.env
#   Help         : bash install.sh --help
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Bootstrap paths
# ---------------------------------------------------------------------------
readonly INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="${INSTALLER_DIR}/modules"
readonly TEMPLATES_DIR="${INSTALLER_DIR}/templates"
readonly CONFIG_DIR="${INSTALLER_DIR}/config"

export LOG_DIR="/var/log/wp-master-installer"
export LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
export ROLLBACK_DIR="/var/backups/wp-master-installer"
export REPORT_DIR="/root"
export MODULES_DIR

# ---------------------------------------------------------------------------
# Source logging first (needed by all other modules)
# ---------------------------------------------------------------------------
# shellcheck source=modules/logging.sh
source "${MODULES_DIR}/logging.sh"

# ---------------------------------------------------------------------------
# Global error handler
# ---------------------------------------------------------------------------
_on_error() {
    local exit_code=$?
    local line_number="${BASH_LINENO[0]}"
    local command="${BASH_COMMAND}"

    log_fatal "Error in ${BASH_SOURCE[1]:-install.sh} at line ${line_number}: '${command}' exited with ${exit_code}"
    log_fatal "Check log: ${LOG_FILE}"

    if [[ "${ROLLBACK_ON_ERROR:-true}" == "true" ]]; then
        log_warn "Initiating automatic rollback..."
        rollback_execute "Error at line ${line_number}: ${command}"
    fi

    report_final_banner "FAILED" 2>/dev/null || true
    exit "${exit_code}"
}

_on_interrupt() {
    echo ""
    log_warn "Installation interrupted by user."
    rollback_execute "User interrupt" 2>/dev/null || true
    exit 130
}

trap '_on_error'     ERR
trap '_on_interrupt' INT TERM

# ---------------------------------------------------------------------------
# Source all modules
# ---------------------------------------------------------------------------
_source_modules() {
    local module_files=(
        checkpoint
        rollback
        os
        webserver
        nginx
        apache
        php
        mariadb
        wordpress
        ssl
        redis
        optimize
        verify
        report
    )

    for mod in "${module_files[@]}"; do
        local mod_path="${MODULES_DIR}/${mod}.sh"
        if [[ -f "${mod_path}" ]]; then
            # shellcheck disable=SC1090
            source "${mod_path}"
        else
            log_fatal "Module not found: ${mod_path}"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
_set_defaults() {
    DOMAIN=""
    ADMIN_EMAIL=""
    WEB_SERVER="nginx"
    PHP_VERSION="8.3"
    DB_NAME="wordpress"
    DB_USER="wp_user"
    DB_PASS=""
    INSTALL_REDIS=true
    UNATTENDED_MODE=false
    CONFIG_FILE=""
    ROLLBACK_ON_ERROR=true
    WEB_ROOT="/var/www"
    WP_DIR="/var/www/wordpress"
    SSL_ENABLED=false
    HEALTH_STATUS="UNCHECKED"
    RESET_CHECKPOINTS=false
}

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unattended|-u)
                UNATTENDED_MODE=true
                shift
                ;;
            --config|-c)
                CONFIG_FILE="${2:-}"
                shift 2
                ;;
            --domain)
                DOMAIN="${2:-}"
                shift 2
                ;;
            --email)
                ADMIN_EMAIL="${2:-}"
                shift 2
                ;;
            --webserver)
                WEB_SERVER="${2:-nginx}"
                shift 2
                ;;
            --php-version)
                PHP_VERSION="${2:-8.3}"
                shift 2
                ;;
            --db-name)
                DB_NAME="${2:-wordpress}"
                shift 2
                ;;
            --db-user)
                DB_USER="${2:-wp_user}"
                shift 2
                ;;
            --db-pass)
                DB_PASS="${2:-}"
                shift 2
                ;;
            --no-redis)
                INSTALL_REDIS=false
                shift
                ;;
            --no-rollback)
                ROLLBACK_ON_ERROR=false
                shift
                ;;
            --reset-checkpoints)
                # Handled after modules are loaded, flag it for now
                RESET_CHECKPOINTS=true
                shift
                ;;
            --debug)
                LOG_VERBOSITY=0
                shift
                ;;
            --help|-h)
                _show_help
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $1"
                shift
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Load config file for unattended mode
# ---------------------------------------------------------------------------
_load_config_file() {
    if [[ -n "${CONFIG_FILE}" ]]; then
        if [[ -f "${CONFIG_FILE}" ]]; then
            log_info "Loading configuration from: ${CONFIG_FILE}"
            # shellcheck disable=SC1090
            source "${CONFIG_FILE}"
        else
            log_fatal "Config file not found: ${CONFIG_FILE}"
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------
_show_help() {
    cat <<HELP
WP Master Installer — Universal Ubuntu WordPress Stack Installer
================================================================

USAGE:
  sudo bash install.sh [OPTIONS]

OPTIONS:
  --unattended, -u        Run without interactive prompts
  --config, -c  FILE      Load configuration from .env file
  --domain      DOMAIN    Target domain name
  --email       EMAIL     Admin email address
  --webserver   TYPE      Web server: nginx (default) or apache
  --php-version VER       PHP version: 8.1, 8.2, 8.3 (default: 8.3)
  --db-name     NAME      Database name (default: wordpress)
  --db-user     USER      Database username (default: wp_user)
  --db-pass     PASS      Database password (prompted if empty)
  --no-ssl                Skip SSL certificate setup
  --no-redis              Skip Redis installation
  --no-rollback           Disable automatic rollback on error
  --reset-checkpoints     Wipe saved progress and start from scratch
  --debug                 Enable verbose debug logging
  --help, -h              Show this help

EXAMPLES:
  # Interactive installation
  sudo bash install.sh

  # Unattended with config file
  sudo bash install.sh --unattended --config /path/to/config.env

  # Unattended with flags
  sudo bash install.sh --unattended --domain example.com --email admin@example.com \\
    --webserver nginx --php-version 8.3 --no-redis

NOTE:
  wp-config.php is NOT generated automatically. After installation, visit
  http(s)://DOMAIN/ to complete the WordPress setup through the browser.

CONFIG FILE FORMAT:
  See config/unattended.env.example for a sample configuration file.

HELP
}

# ---------------------------------------------------------------------------
# Validate domain or IP (accepts both)
# ---------------------------------------------------------------------------
_validate_domain_or_ip() {
    local input="$1"
    # Valid domain
    if [[ "${input}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    # Valid IPv4
    if [[ "${input}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "${input}"
        for oct in "${octets[@]}"; do
            [[ "${oct}" -le 255 ]] || return 1
        done
        return 0
    fi
    return 1
}

_validate_email() {
    local email="$1"
    if [[ "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

_validate_password() {
    local pass="$1"
    if [[ "${#pass}" -ge 8 ]]; then
        return 0
    fi
    return 1
}

_validate_username() {
    local user="$1"
    if [[ "${user}" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]; then
        return 0
    fi
    return 1
}

_validate_db_name() {
    local name="$1"
    if [[ "${name}" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Interactive wizard
# ---------------------------------------------------------------------------
_run_wizard() {
    log_section "WP Master Installer — Interactive Setup Wizard"

    echo ""
    echo "  This wizard installs the full LEMP/LAMP stack and downloads WordPress"
    echo "  to /var/www/wordpress. After installation, open your domain or IP in"
    echo "  a browser to complete WordPress setup."
    echo ""
    echo "  Press Ctrl+C at any time to cancel."
    echo ""

    # Domain or IP
    echo "  ── Site Address ──────────────────────────────────────────────────"
    echo "  Enter a domain name (e.g., example.com) or your server IP address."
    echo "  If you don't have a domain yet, enter the server's public IP."
    echo ""
    while true; do
        read -rp "  Domain or IP: " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if _validate_domain_or_ip "${DOMAIN}"; then
            break
        fi
        echo "  [!] Invalid input. Enter a domain (example.com) or IPv4 address."
    done

    # Web server
    echo ""
    echo "  ── Web Server ────────────────────────────────────────────────────"
    echo "    1) Nginx  (recommended)"
    echo "    2) Apache"
    while true; do
        read -rp "  Choose [1-2, default: 1]: " ws_choice
        ws_choice="${ws_choice:-1}"
        case "${ws_choice}" in
            1) WEB_SERVER="nginx";  break ;;
            2) WEB_SERVER="apache"; break ;;
            *) echo "  [!] Enter 1 or 2." ;;
        esac
    done

    # PHP version
    echo ""
    echo "  ── PHP Version ───────────────────────────────────────────────────"
    echo "    1) PHP 8.1"
    echo "    2) PHP 8.2"
    echo "    3) PHP 8.3 (latest stable — recommended)"
    while true; do
        read -rp "  Choose [1-3, default: 3]: " php_choice
        php_choice="${php_choice:-3}"
        case "${php_choice}" in
            1) PHP_VERSION="8.1"; break ;;
            2) PHP_VERSION="8.2"; break ;;
            3) PHP_VERSION="8.3"; break ;;
            *) echo "  [!] Enter 1, 2, or 3." ;;
        esac
    done

    # Database credentials
    echo ""
    echo "  ── Database Credentials ──────────────────────────────────────────"
    echo "  These will be created in MariaDB. You will enter them on the"
    echo "  WordPress setup page in your browser after installation."
    echo ""

    while true; do
        read -rp "  Database name   [default: wordpress]: " DB_NAME
        DB_NAME="${DB_NAME:-wordpress}"
        if _validate_db_name "${DB_NAME}"; then break; fi
        echo "  [!] Use letters, numbers and underscores only."
    done

    while true; do
        read -rp "  Database user   [default: wp_user]: " DB_USER
        DB_USER="${DB_USER:-wp_user}"
        if _validate_username "${DB_USER}"; then break; fi
        echo "  [!] Use letters, numbers, underscores, hyphens (3-32 chars)."
    done

    while true; do
        read -rsp "  Database password (blank = auto-generate): " DB_PASS
        echo ""
        if [[ -z "${DB_PASS}" ]]; then
            DB_PASS="$(openssl rand -base64 20 | tr -d '/+=' | cut -c1-20)"
            echo "  [✔] Auto-generated password: ${DB_PASS}"
            break
        fi
        if _validate_password "${DB_PASS}"; then break; fi
        echo "  [!] Password must be at least 8 characters."
    done

    # Redis — always installed, just ask preference
    echo ""
    echo "  ── Redis ─────────────────────────────────────────────────────────"
    read -rp "  Install Redis? (recommended for caching) [Y/n]: " redis_choice
    redis_choice="${redis_choice:-Y}"
    [[ "${redis_choice,,}" == "n" ]] && INSTALL_REDIS=false || INSTALL_REDIS=true

    # Summary
    echo ""
    log_section "Installation Summary"
    echo ""
    printf "  %-22s %s\n" "WordPress URL:"   "http://${DOMAIN}/"
    printf "  %-22s %s\n" "WordPress dir:"   "/var/www/wordpress"
    printf "  %-22s %s\n" "Web Server:"      "${WEB_SERVER}"
    printf "  %-22s %s\n" "PHP Version:"     "${PHP_VERSION}"
    printf "  %-22s %s\n" "Database Name:"   "${DB_NAME}"
    printf "  %-22s %s\n" "Database User:"   "${DB_USER}"
    printf "  %-22s %s\n" "Database Pass:"   "${DB_PASS}"
    printf "  %-22s %s\n" "Redis:"           "${INSTALL_REDIS}"
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────┐"
    echo "  │  Save the database credentials above — you will enter them   │"
    echo "  │  on the WordPress setup page after installation completes.   │"
    echo "  └──────────────────────────────────────────────────────────────┘"
    echo ""

    read -rp "  Proceed with installation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" == "n" ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Validate unattended configuration
# ---------------------------------------------------------------------------
_validate_unattended_config() {
    local errors=0

    if [[ -z "${DOMAIN}" ]]; then
        log_error "DOMAIN is required."
        errors=$(( errors + 1 ))
    elif ! _validate_domain_or_ip "${DOMAIN}"; then
        log_error "DOMAIN '${DOMAIN}' is not a valid domain or IP."
        errors=$(( errors + 1 ))
    fi

    if [[ "${WEB_SERVER,,}" != "nginx" && "${WEB_SERVER,,}" != "apache" ]]; then
        log_error "WEB_SERVER must be 'nginx' or 'apache'."
        errors=$(( errors + 1 ))
    fi

    if [[ "${errors}" -gt 0 ]]; then
        log_fatal "${errors} configuration error(s). Cannot proceed."
        exit 1
    fi

    [[ -z "${DB_PASS}" ]] && DB_PASS="$(openssl rand -base64 20 | tr -d '/+=' | cut -c1-20)"
    log_success "Configuration validated."
}

# ---------------------------------------------------------------------------
# Export all globals to sub-processes / modules
# ---------------------------------------------------------------------------
_export_globals() {
    export DOMAIN ADMIN_EMAIL WEB_SERVER PHP_VERSION
    export DB_NAME DB_USER DB_PASS
    export INSTALL_REDIS
    export WEB_ROOT WP_DIR SSL_ENABLED HEALTH_STATUS
    # WordPress always lives at /var/www/wordpress
    WP_DIR="/var/www/wordpress"
    WP_DOMAIN="${DOMAIN}"
    export WP_DIR WP_DOMAIN
}

# ---------------------------------------------------------------------------
# Main installation flow
# ---------------------------------------------------------------------------
_run_installation() {
    local start_time
    start_time=$(date +%s)

    log_section "WP Master Installer v1.0.0"
    log_info "Log file: ${LOG_FILE}"
    log_info "WordPress dir: /var/www/wordpress"

    checkpoint_status

    # --- Phase 1: OS ---
    rollback_init
    checkpoint_run "os_detect"  os_detect  || exit 1
    checkpoint_run "os_update"  os_update  || exit 1

    # --- Phase 2: Web Server ---
    checkpoint_run "webserver_install" webserver_install || exit 1
    checkpoint_run "webserver_enable"  webserver_enable  warn

    # --- Phase 3: PHP ---
    checkpoint_run "php_install"   php_install   || exit 1
    checkpoint_run "php_configure" php_configure || exit 1

    # --- Phase 4: MariaDB — install, create DB, optimize (no secure step) ---
    checkpoint_run "mariadb_install"    mariadb_install         || exit 1
    checkpoint_run "mariadb_create_db"  mariadb_create_database || exit 1
    checkpoint_run "optimize_mariadb"   mariadb_optimize        warn

    # --- Phase 5: WordPress ---
    checkpoint_run "wpcli_install"          wpcli_install             || exit 1
    checkpoint_run "wordpress_download"     wordpress_download        || exit 1
    checkpoint_run "webserver_vhost"        webserver_configure_vhost || exit 1
    checkpoint_run "wordpress_htaccess"     wordpress_create_htaccess warn
    checkpoint_run "wordpress_permissions"  wordpress_set_permissions || exit 1

    # --- Phase 6: Redis — install only, user decides configuration ---
    if [[ "${INSTALL_REDIS}" == "true" ]]; then
        checkpoint_run "redis_install" redis_install warn
    fi

    # --- Phase 7: Optimization ---
    checkpoint_run "optimize_kernel" optimize_system_kernel warn

    # --- Phase 8: Health Check ---
    checkpoint_run "verify_stack" verify_full_stack warn

    # --- Phase 9: Report ---
    report_generate

    local end_time duration proto
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))
    proto="http"

    log_info "Installation completed in ${duration} seconds."

    report_final_banner "SUCCESS"

    # ── Credentials box ───────────────────────────────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║        NEXT STEP — Complete WordPress Setup in Browser           ║"
    echo "  ╠══════════════════════════════════════════════════════════════════╣"
    printf  "  ║  Open: %-59s║\n" "${proto}://${DOMAIN}/"
    echo "  ║                                                                  ║"
    echo "  ║  Enter these details on the WordPress setup page:               ║"
    printf  "  ║    Database Name  : %-45s║\n" "${DB_NAME}"
    printf  "  ║    Username       : %-45s║\n" "${DB_USER}"
    printf  "  ║    Password       : %-45s║\n" "${DB_PASS}"
    echo "  ║    Database Host  : 127.0.0.1                                    ║"
    echo "  ║    Table Prefix   : wp_                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"

    # ── Redis suggestion ──────────────────────────────────────────────────
    if [[ "${INSTALL_REDIS}" == "true" ]]; then
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════════╗"
        echo "  ║        Redis is installed — Here's how to enable it             ║"
        echo "  ╠══════════════════════════════════════════════════════════════════╣"
        echo "  ║  After completing WordPress setup, add this to wp-config.php:   ║"
        echo "  ║                                                                  ║"
        echo "  ║    define('WP_REDIS_HOST', '127.0.0.1');                        ║"
        echo "  ║    define('WP_REDIS_PORT', 6379);                               ║"
        echo "  ║    define('WP_CACHE', true);                                    ║"
        echo "  ║                                                                  ║"
        echo "  ║  Then install the 'Redis Object Cache' plugin from:             ║"
        echo "  ║    WP Admin → Plugins → Add New → search 'Redis Object Cache'   ║"
        echo "  ║  Activate it and click 'Enable Object Cache' in the plugin.     ║"
        echo "  ╚══════════════════════════════════════════════════════════════════╝"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    _set_defaults
    _parse_args "$@"
    _load_config_file

    # Print banner
    cat <<'BANNER'
 ___       ______   _____ __  __           _
/ _ \     | ___\ \ / /  _|  \/  |         | |
| | | |    | |_   \ V /| |_| \  / | __ _ ___| |_ ___ _ __
| | | |____| __|   | | |  _| |\/| |/ _` / __| __/ _ \ '__|
| |_| |____| |___  | | | | | |  | | (_| \__ \ ||  __/ |
 \___/      |_____| |_| |_| |_|  |_|\__,_|___/\__\___|_|

     WP Master Installer v1.0.0 — Ubuntu WordPress Stack
     © 2026 Pradip Nalwaya, Operisoft (https://operisoft.com)
BANNER
    echo ""

    # Source all modules
    _source_modules

    if [[ "${UNATTENDED_MODE}" == "true" ]]; then
        _validate_unattended_config
    else
        _run_wizard
    fi

    _export_globals

    # Reset checkpoints if requested (must come after globals so state file path is known)
    if [[ "${RESET_CHECKPOINTS}" == "true" ]]; then
        checkpoint_reset
        # Also wipe persisted credentials so fresh passwords are generated
        rm -f "/root/.wp-master-db-creds" /root/.my.cnf 2>/dev/null || true
        log_info "Persisted credentials cleared. Fresh passwords will be generated."
    fi

    # Reload persisted DB credentials so all phases use the same passwords
    if [[ -f "/root/.wp-master-db-creds" ]]; then
        # shellcheck disable=SC1091
        source "/root/.wp-master-db-creds"
        export DB_NAME DB_USER DB_PASS
        log_info "Loaded persisted database credentials."
    fi

    _run_installation
}

main "$@"
