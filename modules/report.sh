#!/usr/bin/env bash
# =============================================================================
# modules/report.sh — Deployment Report Generation Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_REPORT_SH_LOADED:-}" ]] && return 0
_REPORT_SH_LOADED=1

# ---------------------------------------------------------------------------
# Generate and save the deployment report
# ---------------------------------------------------------------------------
report_generate() {
    log_section "Deployment Report Generation"

    local report_dir="${REPORT_DIR:-/root}"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local report_file="${report_dir}/deployment-report-${timestamp}.txt"

    mkdir -p "${report_dir}"

    # ── Collect live values ───────────────────────────────────────────────
    local install_date
    install_date="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # Server info — re-read directly in case os_detect was skipped
    local server_ip hostname_str distro_ver distro_code ram_gb cpu_cores
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    hostname_str="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"
    distro_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}")"
    distro_code="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unknown}")"
    ram_gb="$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
    cpu_cores="$(nproc 2>/dev/null || echo '?')"

    # Stack versions
    local ws_ver php_ver mariadb_ver
    ws_ver="$(webserver_version 2>/dev/null || echo 'unknown')"
    php_ver="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "${PHP_VERSION:-unknown}")"
    mariadb_ver="$(mysql --user=root -e 'SELECT VERSION();' 2>/dev/null | tail -1 | tr -d '\n' || echo 'unknown')"

    # Redis
    local redis_status="Not installed"
    if systemctl is-active --quiet redis-server 2>/dev/null; then
        local rv
        rv="$(redis-server --version 2>/dev/null | awk '{print $3}' | cut -d= -f2)"
        redis_status="Running (v${rv})"
    elif dpkg -l redis-server 2>/dev/null | grep -q '^ii'; then
        redis_status="Installed (not running)"
    fi

    # WordPress
    local wp_url="http://${DOMAIN:-unknown}"
    local wp_dir="/var/www/wordpress"
    local wp_version="unknown"
    [[ -f "${wp_dir}/wp-includes/version.php" ]] && \
        wp_version="$(grep "\$wp_version" "${wp_dir}/wp-includes/version.php" \
            | head -1 | cut -d"'" -f2)"

    local health="${HEALTH_STATUS:-UNCHECKED}"

    # ── Build report ──────────────────────────────────────────────────────
    local line="════════════════════════════════════════════════════════════════════════"
    local thin="────────────────────────────────────────────────────────────────────────"

    local report
    report="$(cat <<REPORT
${line}
  WP MASTER INSTALLER — DEPLOYMENT REPORT
  © 2026 Pradip Nalwaya, Operisoft (https://operisoft.com)
${line}
  Generated       : ${install_date}
  Installer Ver   : 1.0.0
${thin}
  SERVER
${thin}
  Hostname        : ${hostname_str}
  Server IP       : ${server_ip}
  OS              : Ubuntu ${distro_ver} (${distro_code})
  RAM             : ${ram_gb} GB
  CPU Cores       : ${cpu_cores}
${thin}
  STACK
${thin}
  Web Server      : ${WEB_SERVER^^} ${ws_ver}
  PHP Version     : ${php_ver}
  MariaDB         : ${mariadb_ver}
  Redis           : ${redis_status}
  WordPress       : ${wp_version}
${thin}
  WORDPRESS SETUP
${thin}
  WordPress URL   : ${wp_url}/
  WordPress Dir   : ${wp_dir}
  Setup Page      : ${wp_url}/wp-admin/setup-config.php
${thin}
  DATABASE CREDENTIALS  (enter these on the WordPress setup page)
${thin}
  Database Name   : ${DB_NAME:-N/A}
  Database User   : ${DB_USER:-N/A}
  Database Pass   : ${DB_PASS:-N/A}
  Database Host   : 127.0.0.1
  Table Prefix    : wp_
${thin}
  REDIS — How to enable after WordPress setup
${thin}
  1. Add to wp-config.php:
       define('WP_REDIS_HOST', '127.0.0.1');
       define('WP_REDIS_PORT', 6379);
       define('WP_CACHE', true);
  2. Install 'Redis Object Cache' plugin from WP Admin → Plugins
  3. Activate and click 'Enable Object Cache'
${thin}
  HEALTH CHECK
${thin}
  Overall Status  : ${health}
${thin}
  LOG
${thin}
  Log File        : ${LOG_FILE}
${line}
  IMPORTANT: This report contains database credentials.
  Save it securely and delete from server after noting down credentials.
${line}
REPORT
)"

    # Save and display
    echo "${report}" > "${report_file}"
    chmod 600 "${report_file}"

    echo ""
    echo "${report}"
    echo ""
    log_success "Report saved to: ${report_file}"
}

# ---------------------------------------------------------------------------
# Final banner
# ---------------------------------------------------------------------------
report_final_banner() {
    local status="$1"
    local wp_url="http://${DOMAIN:-unknown}"

    if [[ "${status}" == "SUCCESS" ]]; then
        cat <<BANNER

${C_SUCCESS:-}╔══════════════════════════════════════════════════════════════════╗
║          ✔  INSTALLATION COMPLETE                                ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Open your browser and visit:                                    ║
║  ${wp_url}/
║                                                                  ║
║  Enter your database credentials to finish WordPress setup.      ║
║  (credentials shown in the report above)                         ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝${C_RESET:-}

BANNER
    else
        cat <<BANNER

${C_FATAL:-}╔══════════════════════════════════════════════════════════════════╗
║          ✘  INSTALLATION FAILED                                  ║
╠══════════════════════════════════════════════════════════════════╣
║  Check the log: ${LOG_FILE}
╚══════════════════════════════════════════════════════════════════╝${C_RESET:-}

BANNER
    fi
}
