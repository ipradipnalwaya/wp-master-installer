#!/usr/bin/env bash
# =============================================================================
# modules/webserver.sh — Web Server Dispatcher Module
# wp-master-installer
# =============================================================================

[[ -n "${_WEBSERVER_SH_LOADED:-}" ]] && return 0
_WEBSERVER_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals (set by caller or wizard)
# ---------------------------------------------------------------------------
WEB_SERVER="${WEB_SERVER:-nginx}"   # "nginx" or "apache"
WEB_ROOT="${WEB_ROOT:-/var/www}"
DOMAIN="${DOMAIN:-localhost}"

# ---------------------------------------------------------------------------
# Dispatcher: install selected web server
# ---------------------------------------------------------------------------
webserver_install() {
    log_section "Web Server Installation: ${WEB_SERVER^^}"

    case "${WEB_SERVER,,}" in
        nginx)
            # shellcheck source=modules/nginx.sh
            source "${MODULES_DIR}/nginx.sh"
            nginx_install   || return 1
            ;;
        apache)
            # shellcheck source=modules/apache.sh
            source "${MODULES_DIR}/apache.sh"
            apache_install  || return 1
            ;;
        *)
            log_fatal "Unknown web server: '${WEB_SERVER}'. Choose nginx or apache."
            return 1
            ;;
    esac

    log_success "Web server '${WEB_SERVER}' installed."
    return 0
}

# ---------------------------------------------------------------------------
# Dispatcher: configure virtual host
# ---------------------------------------------------------------------------
webserver_configure_vhost() {
    log_section "Virtual Host Configuration"

    case "${WEB_SERVER,,}" in
        nginx)
            nginx_configure_vhost  || return 1
            ;;
        apache)
            apache_configure_vhost || return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Dispatcher: reload / restart web server
# ---------------------------------------------------------------------------
webserver_reload() {
    log_step "Reloading ${WEB_SERVER}..."
    systemctl reload "${WEB_SERVER}" 2>/dev/null \
        || systemctl restart "${WEB_SERVER}" 2>/dev/null \
        || { log_error "Failed to reload ${WEB_SERVER}."; return 1; }
    log_success "${WEB_SERVER} reloaded."
}

webserver_restart() {
    log_step "Restarting ${WEB_SERVER}..."
    systemctl restart "${WEB_SERVER}" || {
        log_error "Failed to restart ${WEB_SERVER}."
        return 1
    }
    log_success "${WEB_SERVER} restarted."
}

# ---------------------------------------------------------------------------
# Dispatcher: verify web server is up
# ---------------------------------------------------------------------------
webserver_verify() {
    log_step "Verifying ${WEB_SERVER} status..."
    if systemctl is-active --quiet "${WEB_SERVER}"; then
        log_success "${WEB_SERVER} is running."
        return 0
    else
        log_error "${WEB_SERVER} is NOT running."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Enable service on boot
# ---------------------------------------------------------------------------
webserver_enable() {
    systemctl enable "${WEB_SERVER}" --quiet 2>/dev/null || true
    log_success "${WEB_SERVER} enabled on startup."
}

# ---------------------------------------------------------------------------
# Return web server version string (for reports)
# ---------------------------------------------------------------------------
webserver_version() {
    case "${WEB_SERVER,,}" in
        nginx)  nginx -v 2>&1 | grep -oP 'nginx/\K[^ ]+' || echo "unknown" ;;
        apache) apache2 -v 2>&1 | grep -oP 'Apache/\K[^ ]+' || echo "unknown" ;;
        *)      echo "unknown" ;;
    esac
}
