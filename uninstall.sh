#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — WP Master Installer Uninstaller
# Removes everything installed by install.sh
#
# Usage:
#   sudo bash uninstall.sh                        # interactive (asks per section)
#   sudo bash uninstall.sh --force                # remove everything, no prompts
#   sudo bash uninstall.sh --domain example.com   # target a specific domain only
#   sudo bash uninstall.sh --help
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED="\033[0;31m"; C_YELLOW="\033[0;33m"; C_GREEN="\033[1;32m"
    C_CYAN="\033[0;36m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
else
    C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
FORCE=false
DOMAIN=""
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/wp-master-installer"
CREDS_FILE="/root/.wp-master-db-creds"
WEB_ROOT="/var/www"
PHP_VERSION=""   # auto-detected

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_info()    { printf "  ${C_CYAN}[INFO]${C_RESET}  %s\n"    "$*"; }
_ok()      { printf "  ${C_GREEN}[DONE]${C_RESET}  %s\n"   "$*"; }
_warn()    { printf "  ${C_YELLOW}[WARN]${C_RESET}  %s\n"  "$*" >&2; }
_error()   { printf "  ${C_RED}[ERROR]${C_RESET} %s\n"     "$*" >&2; }
_section() {
    local line
    line="$(printf '=%.0s' {1..60})"
    printf "\n${C_BOLD}%s\n  %s\n%s${C_RESET}\n\n" "${line}" "$*" "${line}"
}

_confirm() {
    # Returns 0 (yes) or 1 (no/skip).  Always returns 0 when --force.
    [[ "${FORCE}" == "true" ]] && return 0
    local prompt="$1"
    local answer
    read -rp "  ${prompt} [y/N]: " answer
    [[ "${answer,,}" == "y" ]]
}

_run() {
    # Run a command, swallow output unless it fails
    "$@" &>/dev/null || true
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                FORCE=true
                shift ;;
            --domain|-d)
                DOMAIN="${2:-}"
                shift 2 ;;
            --help|-h)
                _show_help
                exit 0 ;;
            *)
                _warn "Unknown argument: $1"
                shift ;;
        esac
    done
}

_show_help() {
    cat <<HELP

WP Master Installer — Uninstaller
===================================
Removes everything installed by install.sh.

USAGE:
  sudo bash uninstall.sh [OPTIONS]

OPTIONS:
  --force,  -f          Remove everything without confirmation prompts
  --domain, -d DOMAIN   Only remove site-specific files for this domain
  --help,   -h          Show this help

EXAMPLES:
  sudo bash uninstall.sh
  sudo bash uninstall.sh --force
  sudo bash uninstall.sh --domain example.com

WARNING:
  This script permanently deletes WordPress files, databases, users,
  SSL certificates, web server configs, and installed packages.
  There is NO undo. Make backups before running.

HELP
}

# ---------------------------------------------------------------------------
# Auto-detect installed PHP version
# ---------------------------------------------------------------------------
_detect_php_version() {
    # Try checkpoint state files first for exact version
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")

    if [[ -z "${PHP_VERSION}" ]]; then
        # Scan installed php-fpm packages
        PHP_VERSION=$(dpkg -l 'php*-fpm' 2>/dev/null \
            | awk '/^ii/{print $2}' \
            | grep -oP '\d+\.\d+' \
            | sort -rV | head -1 || echo "8.3")
    fi
    _info "Detected PHP version: ${PHP_VERSION}"
}

# ---------------------------------------------------------------------------
# Auto-detect web server
# ---------------------------------------------------------------------------
_detect_webserver() {
    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then
        echo "nginx"
    elif dpkg -l apache2 2>/dev/null | grep -q '^ii'; then
        echo "apache2"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Load domain from credentials file if not provided
# ---------------------------------------------------------------------------
_detect_domain() {
    if [[ -n "${DOMAIN}" ]]; then
        return 0
    fi

    # Try to find installed domains from web root
    local domains=()
    if [[ -d "${WEB_ROOT}" ]]; then
        while IFS= read -r d; do
            [[ -f "${d}/wp-login.php" || -f "${d}/wp-settings.php" ]] && \
                domains+=("$(basename "${d}")")
        done < <(find "${WEB_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    fi

    if [[ ${#domains[@]} -eq 1 ]]; then
        DOMAIN="${domains[0]}"
        _info "Auto-detected domain: ${DOMAIN}"
    elif [[ ${#domains[@]} -gt 1 ]]; then
        echo ""
        echo "  Multiple WordPress sites found:"
        for i in "${!domains[@]}"; do
            printf "    %d) %s\n" $(( i + 1 )) "${domains[$i]}"
        done
        echo "    0) All domains"
        read -rp "  Select [0-${#domains[@]}]: " sel
        if [[ "${sel}" == "0" ]]; then
            DOMAIN="__ALL__"
        elif [[ "${sel}" =~ ^[0-9]+$ ]] && [[ "${sel}" -ge 1 && "${sel}" -le ${#domains[@]} ]]; then
            DOMAIN="${domains[$(( sel - 1 ))]}"
        else
            _error "Invalid selection."
            exit 1
        fi
    else
        _warn "No WordPress installations found in ${WEB_ROOT}."
        DOMAIN=""
    fi
}

# ---------------------------------------------------------------------------
# Load DB credentials
# ---------------------------------------------------------------------------
_load_db_creds() {
    DB_NAME=""; DB_USER=""; DB_ROOT_PASS=""
    if [[ -f "${CREDS_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CREDS_FILE}"
        _info "Loaded DB credentials from ${CREDS_FILE}"
    else
        _warn "No credentials file found at ${CREDS_FILE}."
        _warn "Database removal will be skipped unless you enter credentials manually."
    fi
}

# ---------------------------------------------------------------------------
# STEP 1 — WordPress files
# ---------------------------------------------------------------------------
_remove_wordpress() {
    _section "WordPress Files"

    local targets=()

    if [[ "${DOMAIN}" == "__ALL__" ]]; then
        # Collect all WP installs
        while IFS= read -r d; do
            [[ -f "${d}/wp-login.php" || -f "${d}/wp-settings.php" ]] && targets+=("${d}")
        done < <(find "${WEB_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    elif [[ -n "${DOMAIN}" ]]; then
        targets=("${WEB_ROOT}/${DOMAIN}")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        _warn "No WordPress directories found. Skipping."
        return
    fi

    for target in "${targets[@]}"; do
        if [[ -d "${target}" ]]; then
            if _confirm "Delete WordPress files at ${target}?"; then
                rm -rf "${target}"
                _ok "Removed: ${target}"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# STEP 2 — MariaDB database and user
# ---------------------------------------------------------------------------
_remove_database() {
    _section "MariaDB Database & User"

    if ! command -v mysql &>/dev/null; then
        _warn "MySQL client not found. Skipping database removal."
        return
    fi

    if [[ -z "${DB_NAME:-}" && -z "${DB_USER:-}" ]]; then
        _warn "DB_NAME and DB_USER not set. Skipping database removal."
        return
    fi

    if ! _confirm "Drop database '${DB_NAME}' and user '${DB_USER}'?"; then
        _info "Skipping database removal."
        return
    fi

    mysql --user=root 2>/dev/null <<MYSQL_DROP || _warn "Database removal had errors (may not exist)."
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_DROP

    _ok "Database '${DB_NAME}' and user '${DB_USER}' removed."
}

# ---------------------------------------------------------------------------
# STEP 3 — Web server vhost configs
# ---------------------------------------------------------------------------
_remove_vhost() {
    _section "Web Server Virtual Host"

    local ws
    ws="$(_detect_webserver)"

    if [[ -z "${ws}" ]]; then
        _warn "No web server detected. Skipping vhost removal."
        return
    fi

    local domains_to_clean=()
    if [[ "${DOMAIN}" == "__ALL__" ]]; then
        # Find all vhosts we created
        case "${ws}" in
            nginx)
                while IFS= read -r f; do
                    domains_to_clean+=("$(basename "${f}" .conf)")
                done < <(find /etc/nginx/sites-available -maxdepth 1 -name '*.conf' \
                    ! -name 'default*' 2>/dev/null)
                ;;
            apache2)
                while IFS= read -r f; do
                    domains_to_clean+=("$(basename "${f}" .conf)")
                done < <(find /etc/apache2/sites-available -maxdepth 1 -name '*.conf' \
                    ! -name '000-default*' ! -name 'default-ssl*' 2>/dev/null)
                ;;
        esac
    elif [[ -n "${DOMAIN}" ]]; then
        domains_to_clean=("${DOMAIN}")
    fi

    for dom in "${domains_to_clean[@]}"; do
        if ! _confirm "Remove ${ws} vhost for '${dom}'?"; then
            continue
        fi
        case "${ws}" in
            nginx)
                _run rm -f "/etc/nginx/sites-enabled/${dom}.conf"
                _run rm -f "/etc/nginx/sites-available/${dom}.conf"
                _run rm -f "/var/log/nginx/${dom}-access.log"
                _run rm -f "/var/log/nginx/${dom}-error.log"
                _ok "Nginx vhost removed for ${dom}"
                ;;
            apache2)
                _run a2dissite "${dom}.conf"
                _run a2dissite "${dom}-ssl.conf"
                _run rm -f "/etc/apache2/sites-available/${dom}.conf"
                _run rm -f "/etc/apache2/sites-available/${dom}-ssl.conf"
                _run rm -f "/var/log/apache2/${dom}-access.log"
                _run rm -f "/var/log/apache2/${dom}-error.log"
                _run rm -f "/var/log/apache2/${dom}-ssl-access.log"
                _run rm -f "/var/log/apache2/${dom}-ssl-error.log"
                _ok "Apache2 vhost removed for ${dom}"
                ;;
        esac
    done

    # Reload web server
    case "${ws}" in
        nginx)  _run systemctl reload nginx  ;;
        apache2) _run systemctl reload apache2 ;;
    esac
}

# ---------------------------------------------------------------------------
# STEP 4 — SSL certificates
# ---------------------------------------------------------------------------
_remove_ssl() {
    _section "SSL Certificates (Let's Encrypt)"

    if ! command -v certbot &>/dev/null; then
        _info "Certbot not installed. Skipping SSL removal."
        return
    fi

    local domains_to_revoke=()
    if [[ "${DOMAIN}" == "__ALL__" ]]; then
        while IFS= read -r d; do
            domains_to_revoke+=("${d}")
        done < <(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d \
            2>/dev/null | xargs -I{} basename {})
    elif [[ -n "${DOMAIN}" && -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        domains_to_revoke=("${DOMAIN}")
    fi

    for dom in "${domains_to_revoke[@]}"; do
        [[ "${dom}" == "README" ]] && continue
        if _confirm "Revoke & delete SSL certificate for '${dom}'?"; then
            certbot delete --cert-name "${dom}" --non-interactive 2>/dev/null || \
                _run rm -rf "/etc/letsencrypt/live/${dom}" \
                           "/etc/letsencrypt/archive/${dom}" \
                           "/etc/letsencrypt/renewal/${dom}.conf"
            _ok "SSL certificate removed for ${dom}"
        fi
    done

    # Remove auto-renewal cron
    if _confirm "Remove certbot auto-renewal cron job?"; then
        _run rm -f /etc/cron.d/certbot-renewal
        _ok "Certbot renewal cron removed."
    fi
}

# ---------------------------------------------------------------------------
# STEP 5 — PHP
# ---------------------------------------------------------------------------
_remove_php() {
    _section "PHP ${PHP_VERSION} & Extensions"

    if ! _confirm "Remove PHP ${PHP_VERSION} and all its extensions?"; then
        _info "Skipping PHP removal."
        return
    fi

    local ver="${PHP_VERSION}"

    _run systemctl stop  "php${ver}-fpm" 2>/dev/null
    _run systemctl disable "php${ver}-fpm" 2>/dev/null

    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        "php${ver}" "php${ver}-*" 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true

    # Remove PHP config dirs
    _run rm -rf "/etc/php/${ver}"
    _run rm -f  "/var/log/php${ver}-fpm-errors.log"
    _run rm -f  "/var/log/php${ver}-fpm-access.log"
    _run rm -f  "/var/log/php${ver}-fpm-slow.log"
    _run rm -rf "/run/php/php${ver}-fpm.sock"

    # Remove Ondrej PPA if no other PHP versions remain
    if ! dpkg -l 'php*' 2>/dev/null | grep -q '^ii'; then
        _run add-apt-repository --remove -y ppa:ondrej/php 2>/dev/null || true
    fi

    _ok "PHP ${ver} removed."
}

# ---------------------------------------------------------------------------
# STEP 6 — Web server (Nginx or Apache2)
# ---------------------------------------------------------------------------
_remove_webserver() {
    _section "Web Server"

    local ws
    ws="$(_detect_webserver)"

    if [[ -z "${ws}" ]]; then
        _info "No web server found. Skipping."
        return
    fi

    if ! _confirm "Remove ${ws} completely (including all configs)?"; then
        _info "Skipping web server removal."
        return
    fi

    _run systemctl stop    "${ws}"
    _run systemctl disable "${ws}"

    case "${ws}" in
        nginx)
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq nginx nginx-common nginx-full 2>/dev/null || true
            _run rm -rf /etc/nginx
            _run rm -f  /usr/share/keyrings/nginx-archive-keyring.gpg
            _run rm -f  /etc/apt/sources.list.d/nginx.list
            ;;
        apache2)
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq apache2 apache2-utils apache2-bin libapache2-mod-fcgid 2>/dev/null || true
            _run rm -rf /etc/apache2
            ;;
    esac

    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
    _ok "${ws} removed."
}

# ---------------------------------------------------------------------------
# STEP 7 — MariaDB server
# ---------------------------------------------------------------------------
_remove_mariadb() {
    _section "MariaDB Server"

    if ! dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
        _info "MariaDB not installed. Skipping."
        return
    fi

    if ! _confirm "Remove MariaDB server completely? (ALL databases will be lost)"; then
        _info "Skipping MariaDB removal."
        return
    fi

    _run systemctl stop    mariadb
    _run systemctl disable mariadb

    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        mariadb-server mariadb-client mariadb-common \
        'mariadb-server-*' 'mariadb-client-*' 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true

    _run rm -rf /etc/mysql
    _run rm -rf /var/lib/mysql
    _run rm -rf /var/log/mysql
    _run rm -f  /root/.my.cnf
    _run rm -f  "${CREDS_FILE}"
    _run rm -f  /etc/mysql/mariadb.conf.d/99-wordpress-optimized.cnf

    _ok "MariaDB removed."
}

# ---------------------------------------------------------------------------
# STEP 8 — Redis
# ---------------------------------------------------------------------------
_remove_redis() {
    _section "Redis"

    if ! dpkg -l redis-server 2>/dev/null | grep -q '^ii'; then
        _info "Redis not installed. Skipping."
        return
    fi

    if ! _confirm "Remove Redis server?"; then
        _info "Skipping Redis removal."
        return
    fi

    _run systemctl stop    redis-server
    _run systemctl disable redis-server

    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq redis-server redis-tools 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true

    _run rm -rf /etc/redis
    _run rm -f  /var/log/redis/redis-server.log

    _ok "Redis removed."
}

# ---------------------------------------------------------------------------
# STEP 9 — WP-CLI
# ---------------------------------------------------------------------------
_remove_wpcli() {
    _section "WP-CLI"

    if [[ ! -f /usr/local/bin/wp ]]; then
        _info "WP-CLI not found. Skipping."
        return
    fi

    if _confirm "Remove WP-CLI (/usr/local/bin/wp)?"; then
        _run rm -f /usr/local/bin/wp
        _ok "WP-CLI removed."
    fi
}

# ---------------------------------------------------------------------------
# STEP 10 — System optimizations
# ---------------------------------------------------------------------------
_remove_system_optimizations() {
    _section "System Optimizations"

    if _confirm "Remove kernel sysctl optimizations?"; then
        _run rm -f /etc/sysctl.d/99-wp-master-installer.conf
        _run sysctl --system &>/dev/null || true
        _ok "Sysctl optimizations removed."
    fi

    if _confirm "Remove file descriptor limits config?"; then
        _run rm -f /etc/security/limits.d/99-wp-master-installer.conf
        _ok "Limits config removed."
    fi

    # WordPress cron jobs
    local domain_to_clean="${DOMAIN}"
    if [[ "${domain_to_clean}" == "__ALL__" ]]; then
        while IFS= read -r f; do
            if _confirm "Remove WP cron for $(basename "${f}" | sed 's/wordpress-//')?"; then
                _run rm -f "${f}"
                _ok "Removed: ${f}"
            fi
        done < <(find /etc/cron.d -name 'wordpress-*' 2>/dev/null)
    elif [[ -n "${domain_to_clean}" ]]; then
        if [[ -f "/etc/cron.d/wordpress-${domain_to_clean}" ]]; then
            if _confirm "Remove WordPress cron for ${domain_to_clean}?"; then
                _run rm -f "/etc/cron.d/wordpress-${domain_to_clean}"
                _ok "WordPress cron removed."
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# STEP 11 — Installer logs, reports, and checkpoint files
# ---------------------------------------------------------------------------
_remove_installer_artifacts() {
    _section "Installer Logs, Reports & Checkpoints"

    if _confirm "Remove installer log files (${LOG_DIR})?"; then
        _run rm -rf "${LOG_DIR}"
        _ok "Log directory removed."
    fi

    if _confirm "Remove deployment report files (/root/deployment-report-*.txt)?"; then
        _run rm -f /root/deployment-report-*.txt
        _ok "Deployment reports removed."
    fi

    if _confirm "Remove MariaDB credentials file (${CREDS_FILE})?"; then
        _run rm -f "${CREDS_FILE}"
        _ok "Credentials file removed."
    fi
}

# ---------------------------------------------------------------------------
# STEP 12 — Snap / Certbot snap package
# ---------------------------------------------------------------------------
_remove_certbot_snap() {
    _section "Certbot (Snap)"

    if ! command -v snap &>/dev/null; then
        _info "Snap not available. Skipping."
        return
    fi

    if ! snap list certbot &>/dev/null 2>&1; then
        _info "Certbot snap not installed. Skipping."
        return
    fi

    if _confirm "Remove Certbot snap package?"; then
        _run snap remove certbot
        _run rm -f /usr/bin/certbot
        _ok "Certbot snap removed."
    fi
}

# ---------------------------------------------------------------------------
# Final apt cleanup
# ---------------------------------------------------------------------------
_apt_cleanup() {
    _section "APT Cleanup"

    if _confirm "Run apt autoremove and autoclean?"; then
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get autoclean  -y -qq 2>/dev/null || true
        _ok "APT cleanup done."
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    _parse_args "$@"

    # Must run as root
    if [[ "${EUID}" -ne 0 ]]; then
        _error "This script must be run as root (sudo bash uninstall.sh)."
        exit 1
    fi

    clear
    cat <<'BANNER'
 ___       ______   _____ __  __           _
/ _ \     | ___\ \ / /  _|  \/  |         | |
| | | |    | |_   \ V /| |_| \  / | __ _ ___| |_ ___ _ __
| | | |____| __|   | | |  _| |\/| |/ _` / __| __/ _ \ '__|
| |_| |____| |___  | | | | | |  | | (_| \__ \ ||  __/ |
 \___/      |_____| |_| |_| |_|  |_|\__,_|___/\__\___|_|

     WP Master Installer — UNINSTALLER
     © 2026 Pradip Nalwaya, Operisoft (https://operisoft.com)
BANNER
    echo ""

    printf "  ${C_RED}${C_BOLD}WARNING: This will permanently remove the WordPress stack.${C_RESET}\n"
    printf "  ${C_YELLOW}There is NO undo. Ensure you have backups before continuing.${C_RESET}\n\n"

    if [[ "${FORCE}" != "true" ]]; then
        read -rp "  Type 'yes' to continue: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            _info "Uninstall cancelled."
            exit 0
        fi
    fi

    _detect_php_version
    _detect_domain
    _load_db_creds

    echo ""
    _info "Target domain : ${DOMAIN:-all}"
    _info "PHP version   : ${PHP_VERSION}"
    _info "Force mode    : ${FORCE}"
    echo ""

    # Run each removal step
    _remove_wordpress
    _remove_database
    _remove_vhost
    _remove_ssl
    _remove_certbot_snap
    _remove_php
    _remove_webserver
    _remove_mariadb
    _remove_redis
    _remove_wpcli
    _remove_system_optimizations
    _remove_installer_artifacts
    _apt_cleanup

    echo ""
    printf "  ${C_GREEN}${C_BOLD}Uninstall complete.${C_RESET}\n\n"
}

main "$@"
