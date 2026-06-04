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
# Generate and print the full deployment report
# ---------------------------------------------------------------------------
report_generate() {
    log_section "Deployment Report Generation"

    local report_dir="${REPORT_DIR:-/root}"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local report_file="${report_dir}/deployment-report-${timestamp}.txt"

    mkdir -p "${report_dir}"

    # Collect values
    local site_url="http://${DOMAIN}"
    local admin_url="http://${DOMAIN}/wp-admin/"
    [[ "${SSL_ENABLED:-false}" == "true" ]] && {
        site_url="https://${DOMAIN}"
        admin_url="https://${DOMAIN}/wp-admin/"
    }

    local mariadb_ver
    mariadb_ver="$(mariadb_version_string 2>/dev/null || echo 'unknown')"

    local php_ver
    php_ver="$(php_version_string 2>/dev/null || echo "${PHP_VERSION:-unknown}")"

    local ws_ver
    ws_ver="$(webserver_version 2>/dev/null || echo 'unknown')"

    local redis_status
    redis_status="$(redis_status_string 2>/dev/null || echo 'unknown')"

    local ssl_status="Disabled"
    local renewal_status="N/A"
    if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
        ssl_status="Active"
        renewal_status="Configured"
    fi

    local health="${HEALTH_STATUS:-UNCHECKED}"
    local install_date
    install_date="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # -------------------------------------------------------------------------
    # Build report content
    # -------------------------------------------------------------------------
    local report_content
    report_content="$(cat <<REPORT
================================================================================
  WP MASTER INSTALLER — DEPLOYMENT REPORT
================================================================================
  Generated     : ${install_date}
  Installer Ver : 1.0.0

--------------------------------------------------------------------------------
  SERVER INFORMATION
--------------------------------------------------------------------------------
  Ubuntu Version  : ${DISTRO_VERSION} (${DISTRO_CODENAME})
  Hostname        : ${SYS_HOSTNAME}
  Server IP       : ${SYS_SERVER_IP}
  RAM             : ${SYS_RAM_GB} GB
  CPU Cores       : ${SYS_CPU_CORES}

--------------------------------------------------------------------------------
  STACK INFORMATION
--------------------------------------------------------------------------------
  Web Server      : ${WEB_SERVER^^} ${ws_ver}
  PHP Version     : ${php_ver}
  MariaDB Version : ${mariadb_ver}
  Redis Status    : ${redis_status}

--------------------------------------------------------------------------------
  SSL / SECURITY
--------------------------------------------------------------------------------
  SSL Status      : ${ssl_status}
  Auto Renewal    : ${renewal_status}

--------------------------------------------------------------------------------
  WORDPRESS
--------------------------------------------------------------------------------
  Site Title      : ${WP_SITE_TITLE:-N/A}
  WordPress URL   : ${site_url}
  WP Admin URL    : ${admin_url}
  Admin Username  : ${WP_ADMIN_USER:-N/A}
  Admin Password  : ${WP_ADMIN_PASS:-N/A}
  Admin Email     : ${WP_ADMIN_EMAIL:-N/A}

--------------------------------------------------------------------------------
  DATABASE
--------------------------------------------------------------------------------
  Database Name   : ${DB_NAME:-N/A}
  Database User   : ${DB_USER:-N/A}
  Database Pass   : ${DB_PASS:-N/A}
  DB Root Pass    : ${DB_ROOT_PASS:-N/A}

--------------------------------------------------------------------------------
  HEALTH CHECK
--------------------------------------------------------------------------------
  Overall Status  : ${health}

--------------------------------------------------------------------------------
  LOG FILE
--------------------------------------------------------------------------------
  Log File        : ${LOG_FILE}

================================================================================
  IMPORTANT: Keep this report secure. It contains sensitive credentials.
  Store it in a safe location and delete after setup is complete.
================================================================================
REPORT
)"

    # Save to file
    echo "${report_content}" > "${report_file}"
    chmod 600 "${report_file}"

    # Print to screen
    echo ""
    echo "${report_content}"
    echo ""
    log_success "Report saved to: ${report_file}"
}

# ---------------------------------------------------------------------------
# Print final installation result banner
# ---------------------------------------------------------------------------
report_final_banner() {
    local status="$1"  # "SUCCESS" or "FAILED"

    local site_url="http://${DOMAIN}"
    local admin_url="http://${DOMAIN}/wp-admin/"
    [[ "${SSL_ENABLED:-false}" == "true" ]] && {
        site_url="https://${DOMAIN}"
        admin_url="https://${DOMAIN}/wp-admin/"
    }

    if [[ "${status}" == "SUCCESS" ]]; then
        cat <<BANNER

${C_SUCCESS:-}
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║          ✔  INSTALLATION SUCCESSFUL                              ║
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  WordPress Site   : ${site_url}
║  WordPress Admin  : ${admin_url}
║  Admin Username   : ${WP_ADMIN_USER:-admin}
║  Admin Password   : ${WP_ADMIN_PASS:-[see report]}
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
${C_RESET:-}

BANNER
    else
        cat <<BANNER

${C_FATAL:-}
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║          ✘  INSTALLATION FAILED                                  ║
║                                                                  ║
║  Please review the log file:                                     ║
║  ${LOG_FILE}
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
${C_RESET:-}

BANNER
    fi
}
