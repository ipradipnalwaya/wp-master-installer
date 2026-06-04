#!/usr/bin/env bash
# =============================================================================
# modules/verify.sh — Self-Healing Health Check & Verification Module
# wp-master-installer
# =============================================================================

[[ -n "${_VERIFY_SH_LOADED:-}" ]] && return 0
_VERIFY_SH_LOADED=1

# ---------------------------------------------------------------------------
# Service restart with retry
# ---------------------------------------------------------------------------
_service_heal() {
    local service="$1"
    local max_attempts="${2:-3}"
    local attempt=1

    while [[ "${attempt}" -le "${max_attempts}" ]]; do
        log_step "Healing: restarting ${service} (attempt ${attempt}/${max_attempts})..."
        systemctl restart "${service}" 2>&1 | tee -a "${LOG_FILE}"

        sleep 2
        if systemctl is-active --quiet "${service}"; then
            log_success "${service} is now running."
            log_info "Self-healing event: ${service} restarted at $(date)."
            return 0
        fi
        (( attempt++ ))
    done

    log_error "Self-healing FAILED for ${service} after ${max_attempts} attempts."
    return 1
}

# ---------------------------------------------------------------------------
# Verify + heal web server
# ---------------------------------------------------------------------------
verify_webserver() {
    log_step "Checking ${WEB_SERVER} service..."

    if systemctl is-active --quiet "${WEB_SERVER}"; then
        log_success "${WEB_SERVER} is running."
        return 0
    fi

    log_warn "${WEB_SERVER} is down. Attempting self-healing..."
    _service_heal "${WEB_SERVER}"
}

# ---------------------------------------------------------------------------
# Verify + heal PHP-FPM
# ---------------------------------------------------------------------------
verify_php_fpm() {
    local fpm_service="php${PHP_VERSION}-fpm"
    log_step "Checking ${fpm_service} service..."

    if systemctl is-active --quiet "${fpm_service}"; then
        log_success "${fpm_service} is running."
        return 0
    fi

    log_warn "${fpm_service} is down. Attempting self-healing..."
    _service_heal "${fpm_service}"
}

# ---------------------------------------------------------------------------
# Verify + heal MariaDB
# ---------------------------------------------------------------------------
verify_mariadb() {
    log_step "Checking MariaDB service..."

    if systemctl is-active --quiet mariadb; then
        log_success "MariaDB is running."
    else
        log_warn "MariaDB is down. Attempting self-healing..."
        _service_heal mariadb || return 1
    fi

    # Verify DB connection
    if mysql --user="${DB_USER}" --password="${DB_PASS}" \
             --host=127.0.0.1 --protocol=TCP "${DB_NAME}" \
             -e "SELECT 1;" &>/dev/null; then
        log_success "MariaDB connection verified."
        return 0
    else
        log_error "MariaDB is running but cannot connect to database '${DB_NAME}'."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify + heal Redis
# ---------------------------------------------------------------------------
verify_redis() {
    log_step "Checking Redis service..."

    if ! systemctl is-active --quiet redis-server; then
        log_warn "Redis is down. Attempting self-healing..."
        _service_heal redis-server || return 1
    fi

    local pong
    pong=$(redis-cli ping 2>/dev/null)
    if [[ "${pong}" == "PONG" ]]; then
        log_success "Redis is responding."
        return 0
    else
        log_error "Redis is running but not responding to ping."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify WordPress HTTP response
# ---------------------------------------------------------------------------
verify_wordpress_http() {
    log_step "Checking WordPress HTTP response..."

    local proto="http"
    [[ "${SSL_ENABLED:-false}" == "true" ]] && proto="https"
    local url="${proto}://${DOMAIN}/"

    local http_code
    http_code=$(curl -fsS --max-time 15 --insecure -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000")

    case "${http_code}" in
        200|301|302)
            log_success "WordPress HTTP check: ${http_code} at ${url}"
            return 0
            ;;
        000)
            log_error "Could not connect to ${url} (connection refused or timeout)."
            return 1
            ;;
        *)
            log_warn "WordPress HTTP check returned: ${http_code} at ${url}"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Verify PHP processing
# ---------------------------------------------------------------------------
verify_php_processing() {
    log_step "Verifying PHP processing via web server..."

    local probe_file="${WP_DIR}/wp-master-probe-$$.php"
    local proto="http"
    [[ "${SSL_ENABLED:-false}" == "true" ]] && proto="https"

    # Create a temporary probe
    cat > "${probe_file}" <<'PHPPROBE'
<?php
header('Content-Type: text/plain');
echo 'PHP_OK:' . PHP_VERSION;
PHPPROBE
    chown www-data:www-data "${probe_file}"

    local response
    response=$(curl -fsS --max-time 10 --insecure \
        "${proto}://${DOMAIN}/$(basename ${probe_file})" 2>/dev/null || echo "")

    # Clean up probe
    rm -f "${probe_file}"

    if echo "${response}" | grep -q "PHP_OK:"; then
        local php_ver
        php_ver=$(echo "${response}" | grep -oP 'PHP_OK:\K[0-9.]+')
        log_success "PHP processing verified: v${php_ver}"
        return 0
    else
        log_error "PHP processing check failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify SSL certificate
# ---------------------------------------------------------------------------
verify_ssl() {
    [[ "${SSL_ENABLED:-false}" == "true" ]] || {
        log_info "SSL not enabled. Skipping SSL verification."
        return 0
    }

    log_step "Verifying SSL certificate..."

    if [[ ! -f "${SSL_CERT_PATH}" ]]; then
        log_error "SSL certificate not found: ${SSL_CERT_PATH}"
        return 1
    fi

    local expiry_epoch
    expiry_epoch=$(openssl x509 -enddate -noout -in "${SSL_CERT_PATH}" 2>/dev/null \
        | cut -d= -f2 \
        | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)

    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ "${days_left}" -gt 30 ]]; then
        log_success "SSL certificate valid for ${days_left} more days."
        return 0
    elif [[ "${days_left}" -gt 0 ]]; then
        log_warn "SSL certificate expires in ${days_left} days. Renewal recommended."
        return 0
    else
        log_error "SSL certificate has EXPIRED."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Full stack health check
# ---------------------------------------------------------------------------
verify_full_stack() {
    log_section "Full Stack Health Check"

    local errors=0

    verify_webserver         || errors=$(( errors + 1 ))
    verify_php_fpm           || errors=$(( errors + 1 ))
    verify_mariadb           || errors=$(( errors + 1 ))
    verify_redis             || log_warn "Redis verification failed (non-fatal)."
    verify_wordpress_http    || errors=$(( errors + 1 ))
    verify_php_processing    || errors=$(( errors + 1 ))
    verify_ssl               || log_warn "SSL verification had issues."

    if [[ "${errors}" -eq 0 ]]; then
        log_success "All services healthy."
        HEALTH_STATUS="HEALTHY"
        return 0
    else
        log_error "${errors} service(s) failed health check."
        HEALTH_STATUS="DEGRADED (${errors} failures)"
        return 1
    fi
}

# Export health status for report
HEALTH_STATUS="UNCHECKED"
