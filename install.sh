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
# Author  : wp-master-installer project
# License : MIT
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
    DB_ROOT_PASS=""
    WP_ADMIN_USER="admin"
    WP_ADMIN_PASS=""
    WP_ADMIN_EMAIL=""
    WP_SITE_TITLE="My WordPress Site"
    INSTALL_REDIS=true
    INSTALL_SSL=true
    UNATTENDED_MODE=false
    CONFIG_FILE=""
    ROLLBACK_ON_ERROR=true
    WEB_ROOT="/var/www"
    WP_DIR=""
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
            --wp-admin-user)
                WP_ADMIN_USER="${2:-admin}"
                shift 2
                ;;
            --wp-admin-pass)
                WP_ADMIN_PASS="${2:-}"
                shift 2
                ;;
            --wp-title)
                WP_SITE_TITLE="${2:-}"
                shift 2
                ;;
            --no-ssl)
                INSTALL_SSL=false
                shift
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
  --db-pass     PASS      Database password (auto-generated if empty)
  --wp-admin-user USER    WordPress admin username (default: admin)
  --wp-admin-pass PASS    WordPress admin password (auto-generated if empty)
  --wp-title    TITLE     WordPress site title
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
    --webserver nginx --php-version 8.3 --wp-title "My Site" --no-redis

CONFIG FILE FORMAT:
  See config/unattended.env.example for a sample configuration file.

HELP
}

# ---------------------------------------------------------------------------
# Input validation helpers
# ---------------------------------------------------------------------------
_validate_domain() {
    local domain="$1"
    if [[ "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
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
    echo "  This wizard will configure your WordPress installation."
    echo "  Press Ctrl+C at any time to cancel."
    echo ""

    # Domain
    while true; do
        read -rp "  Domain name (e.g., example.com): " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if _validate_domain "${DOMAIN}"; then
            break
        fi
        echo "  [!] Invalid domain. Please enter a valid domain (e.g., example.com)."
    done

    # Admin email
    while true; do
        read -rp "  Admin email address: " ADMIN_EMAIL
        ADMIN_EMAIL="${ADMIN_EMAIL// /}"
        if _validate_email "${ADMIN_EMAIL}"; then
            break
        fi
        echo "  [!] Invalid email address. Please try again."
    done
    WP_ADMIN_EMAIL="${ADMIN_EMAIL}"

    # Web server
    echo ""
    echo "  Web server options:"
    echo "    1) Nginx  (recommended)"
    echo "    2) Apache"
    while true; do
        read -rp "  Choose web server [1-2, default: 1]: " ws_choice
        ws_choice="${ws_choice:-1}"
        case "${ws_choice}" in
            1) WEB_SERVER="nginx";  break ;;
            2) WEB_SERVER="apache"; break ;;
            *) echo "  [!] Invalid choice. Enter 1 or 2." ;;
        esac
    done

    # PHP version
    echo ""
    echo "  PHP version options:"
    echo "    1) PHP 8.1"
    echo "    2) PHP 8.2"
    echo "    3) PHP 8.3 (latest stable — recommended)"
    while true; do
        read -rp "  Choose PHP version [1-3, default: 3]: " php_choice
        php_choice="${php_choice:-3}"
        case "${php_choice}" in
            1) PHP_VERSION="8.1"; break ;;
            2) PHP_VERSION="8.2"; break ;;
            3) PHP_VERSION="8.3"; break ;;
            *) echo "  [!] Invalid choice. Enter 1, 2, or 3." ;;
        esac
    done

    # WordPress site title
    echo ""
    read -rp "  WordPress site title [default: My WordPress Site]: " WP_SITE_TITLE
    WP_SITE_TITLE="${WP_SITE_TITLE:-My WordPress Site}"

    # Database name
    echo ""
    while true; do
        read -rp "  Database name [default: wordpress]: " DB_NAME
        DB_NAME="${DB_NAME:-wordpress}"
        if _validate_db_name "${DB_NAME}"; then
            break
        fi
        echo "  [!] Invalid database name. Use letters, numbers and underscores."
    done

    # Database user
    while true; do
        read -rp "  Database user [default: wp_user]: " DB_USER
        DB_USER="${DB_USER:-wp_user}"
        if _validate_username "${DB_USER}"; then
            break
        fi
        echo "  [!] Invalid username. Use letters, numbers, underscores, hyphens (3-32 chars)."
    done

    # Database password
    while true; do
        read -rsp "  Database password (leave blank to auto-generate): " DB_PASS
        echo ""
        if [[ -z "${DB_PASS}" ]]; then
            DB_PASS="$(openssl rand -base64 20)"
            echo "  [✔] Auto-generated database password."
            break
        fi
        if _validate_password "${DB_PASS}"; then
            break
        fi
        echo "  [!] Password must be at least 8 characters."
    done

    # WP admin username
    echo ""
    while true; do
        read -rp "  WordPress admin username [default: admin]: " WP_ADMIN_USER
        WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
        if _validate_username "${WP_ADMIN_USER}"; then
            break
        fi
        echo "  [!] Invalid username."
    done

    # WP admin password
    while true; do
        read -rsp "  WordPress admin password (leave blank to auto-generate): " WP_ADMIN_PASS
        echo ""
        if [[ -z "${WP_ADMIN_PASS}" ]]; then
            WP_ADMIN_PASS="$(openssl rand -base64 16)"
            echo "  [✔] Auto-generated WordPress admin password."
            break
        fi
        if _validate_password "${WP_ADMIN_PASS}"; then
            break
        fi
        echo "  [!] Password must be at least 8 characters."
    done

    # SSL
    echo ""
    read -rp "  Install SSL certificate (Let's Encrypt)? [Y/n]: " ssl_choice
    ssl_choice="${ssl_choice:-Y}"
    if [[ "${ssl_choice,,}" == "n" ]]; then
        INSTALL_SSL=false
    else
        INSTALL_SSL=true
    fi

    # Redis
    read -rp "  Install Redis object cache? [Y/n]: " redis_choice
    redis_choice="${redis_choice:-Y}"
    if [[ "${redis_choice,,}" == "n" ]]; then
        INSTALL_REDIS=false
    else
        INSTALL_REDIS=true
    fi

    # Confirmation summary
    echo ""
    log_section "Installation Summary"
    echo ""
    printf "  %-25s %s\n" "Domain:"           "${DOMAIN}"
    printf "  %-25s %s\n" "Admin Email:"      "${ADMIN_EMAIL}"
    printf "  %-25s %s\n" "Web Server:"       "${WEB_SERVER}"
    printf "  %-25s %s\n" "PHP Version:"      "${PHP_VERSION}"
    printf "  %-25s %s\n" "Site Title:"       "${WP_SITE_TITLE}"
    printf "  %-25s %s\n" "Database Name:"    "${DB_NAME}"
    printf "  %-25s %s\n" "Database User:"    "${DB_USER}"
    printf "  %-25s %s\n" "WP Admin User:"    "${WP_ADMIN_USER}"
    printf "  %-25s %s\n" "Install SSL:"      "${INSTALL_SSL}"
    printf "  %-25s %s\n" "Install Redis:"    "${INSTALL_REDIS}"
    echo ""

    read -rp "  Proceed with installation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" == "n" ]]; then
        log_info "Installation cancelled by user."
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
    elif ! _validate_domain "${DOMAIN}"; then
        log_error "DOMAIN '${DOMAIN}' is invalid."
        errors=$(( errors + 1 ))
    fi

    if [[ -z "${ADMIN_EMAIL}" ]]; then
        log_error "ADMIN_EMAIL is required."
        errors=$(( errors + 1 ))
    elif ! _validate_email "${ADMIN_EMAIL}"; then
        log_error "ADMIN_EMAIL '${ADMIN_EMAIL}' is invalid."
        errors=$(( errors + 1 ))
    fi

    WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-${ADMIN_EMAIL}}"

    if [[ "${WEB_SERVER,,}" != "nginx" && "${WEB_SERVER,,}" != "apache" ]]; then
        log_error "WEB_SERVER must be 'nginx' or 'apache'."
        errors=$(( errors + 1 ))
    fi

    if [[ "${errors}" -gt 0 ]]; then
        log_fatal "${errors} configuration error(s). Cannot proceed."
        exit 1
    fi

    # Auto-generate passwords if not set
    [[ -z "${DB_PASS}" ]]       && DB_PASS="$(openssl rand -base64 20)"
    [[ -z "${WP_ADMIN_PASS}" ]] && WP_ADMIN_PASS="$(openssl rand -base64 16)"

    log_success "Configuration validated."
}

# ---------------------------------------------------------------------------
# Export all globals to sub-processes / modules
# ---------------------------------------------------------------------------
_export_globals() {
    export DOMAIN ADMIN_EMAIL WEB_SERVER PHP_VERSION
    export DB_NAME DB_USER DB_PASS DB_ROOT_PASS
    export WP_ADMIN_USER WP_ADMIN_PASS WP_ADMIN_EMAIL WP_SITE_TITLE
    export INSTALL_REDIS INSTALL_SSL
    export WEB_ROOT WP_DIR SSL_ENABLED HEALTH_STATUS
    # Derived
    WP_DIR="${WEB_ROOT}/${DOMAIN}"
    WP_DOMAIN="${DOMAIN}"
    SSL_DOMAIN="${DOMAIN}"
    export WP_DIR WP_DOMAIN SSL_DOMAIN
}

# ---------------------------------------------------------------------------
# Main installation flow
# ---------------------------------------------------------------------------
_run_installation() {
    local start_time
    start_time=$(date +%s)

    log_section "WP Master Installer v1.0.0"
    log_info "Log file: ${LOG_FILE}"
    log_info "Mode: $(${UNATTENDED_MODE} && echo 'Unattended' || echo 'Interactive')"

    # Show any already-completed steps so user knows what will be skipped
    checkpoint_status

    # --- Phase 1: OS Detection ---
    rollback_init
    checkpoint_run "os_detect"              os_detect           || exit 1
    checkpoint_run "os_update"              os_update           || exit 1

    # --- Phase 2: Web Server ---
    checkpoint_run "webserver_install"      webserver_install   || exit 1
    checkpoint_run "webserver_enable"       webserver_enable    warn

    # --- Phase 3: PHP ---
    checkpoint_run "php_install"            php_install         || exit 1
    checkpoint_run "php_configure"          php_configure       || exit 1

    # --- Phase 4: MariaDB ---
    checkpoint_run "mariadb_install"        mariadb_install     || exit 1
    checkpoint_run "mariadb_secure"         mariadb_secure      || exit 1
    checkpoint_run "mariadb_create_db"      mariadb_create_database || exit 1
    # Always verify access — not checkpointed since it's a read-only check
    mariadb_verify_access || exit 1

    # --- Phase 5: WordPress ---
    checkpoint_run "wpcli_install"          wpcli_install       || exit 1
    checkpoint_run "wordpress_download"     wordpress_download  || exit 1
    checkpoint_run "wordpress_configure"    wordpress_configure || exit 1

    # --- Phase 6: Web Server Virtual Host ---
    checkpoint_run "webserver_vhost"        webserver_configure_vhost   || exit 1
    checkpoint_run "wordpress_htaccess"     wordpress_create_htaccess   warn
    checkpoint_run "wordpress_permissions"  wordpress_set_permissions   || exit 1

    # --- Phase 7: WordPress Core Install ---
    checkpoint_run "wordpress_install"      wordpress_install   || exit 1

    # --- Phase 8: Redis (optional) ---
    if [[ "${INSTALL_REDIS}" == "true" ]]; then
        checkpoint_run "redis_install"              redis_install               warn
        checkpoint_run "redis_configure"            redis_configure             warn
        checkpoint_run "redis_configure_wordpress"  redis_configure_wordpress   warn
    fi

    # --- Phase 9: SSL (optional) ---
    if [[ "${INSTALL_SSL}" == "true" ]]; then
        checkpoint_run "ssl_install_certbot"    ssl_install_certbot     warn
        checkpoint_run "ssl_obtain_cert"        ssl_obtain_certificate  warn
        if [[ "${SSL_ENABLED}" == "true" ]]; then
            checkpoint_run "ssl_auto_renewal"   ssl_setup_auto_renewal  warn
            checkpoint_run "ssl_test_renewal"   ssl_test_renewal        warn
        fi
    fi

    # --- Phase 10: Optimization ---
    checkpoint_run "optimize_mariadb"   mariadb_optimize        warn
    checkpoint_run "optimize_kernel"    optimize_system_kernel  warn
    checkpoint_run "optimize_wordpress" optimize_wordpress      warn

    # --- Phase 11: Health Check ---
    checkpoint_run "verify_stack"       verify_full_stack       warn

    # --- Phase 12: Report ---
    report_generate

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    log_info "Installation completed in ${duration} seconds."

    # --- Final Banner ---
    if [[ "${HEALTH_STATUS:-UNCHECKED}" != *"DEGRADED"* ]]; then
        report_final_banner "SUCCESS"
    else
        report_final_banner "FAILED"
        exit 1
    fi
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
    fi

    _run_installation
}

main "$@"
