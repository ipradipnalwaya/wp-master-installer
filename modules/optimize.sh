#!/usr/bin/env bash
# =============================================================================
# modules/optimize.sh — System-Wide Performance Optimization Module
# wp-master-installer
# =============================================================================

[[ -n "${_OPTIMIZE_SH_LOADED:-}" ]] && return 0
_OPTIMIZE_SH_LOADED=1

# ---------------------------------------------------------------------------
# Master optimization entry point
# Calls individual optimizers from php.sh, mariadb.sh, nginx.sh / apache.sh
# ---------------------------------------------------------------------------
optimize_all() {
    log_section "Performance Optimization"
    log_info "Tuning for system: ${SYS_RAM_MB}MB RAM / ${SYS_CPU_CORES} CPU cores"

    optimize_php     || log_warn "PHP optimization had errors."
    optimize_mariadb || log_warn "MariaDB optimization had errors."
    optimize_webserver || log_warn "Web server optimization had errors."
    optimize_system_kernel || log_warn "Kernel optimization had errors."

    log_success "Optimization complete."
}

# ---------------------------------------------------------------------------
# PHP optimization (delegates to php.sh)
# ---------------------------------------------------------------------------
optimize_php() {
    log_step "Optimizing PHP..."
    php_configure 2>/dev/null || {
        # If php_configure already ran, just ensure values are current
        log_info "PHP may have already been configured."
    }
    return 0
}

# ---------------------------------------------------------------------------
# MariaDB optimization (delegates to mariadb.sh)
# ---------------------------------------------------------------------------
optimize_mariadb() {
    log_step "Optimizing MariaDB..."
    mariadb_optimize 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Web server optimization (delegates to nginx.sh or apache.sh)
# ---------------------------------------------------------------------------
optimize_webserver() {
    log_step "Optimizing ${WEB_SERVER}..."
    case "${WEB_SERVER,,}" in
        nginx)  nginx_optimize  || true ;;
        apache) apache_optimize || true ;;
    esac
}

# ---------------------------------------------------------------------------
# Linux kernel / sysctl optimizations for a web server
# ---------------------------------------------------------------------------
optimize_system_kernel() {
    log_step "Applying kernel sysctl optimizations..."

    local sysctl_conf="/etc/sysctl.d/99-wp-master-installer.conf"
    rollback_backup "${sysctl_conf}" 2>/dev/null || true

    cat > "${sysctl_conf}" <<EOF
# wp-master-installer kernel optimizations
# Generated: $(date)

# --- Network ---
# Increase the maximum number of open file descriptors
fs.file-max = 65535

# TCP connection handling
net.core.somaxconn          = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syn_retries    = 2
net.ipv4.tcp_synack_retries = 2

# TCP TIME_WAIT optimization
net.ipv4.tcp_fin_timeout    = 15
net.ipv4.tcp_tw_reuse       = 1

# TCP keepalive
net.ipv4.tcp_keepalive_time  = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl  = 15

# Increase TCP buffer sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Disable IPv6 if not needed (comment out to keep IPv6)
# net.ipv6.conf.all.disable_ipv6 = 1

# --- Memory ---
vm.swappiness        = 10
vm.dirty_ratio       = 15
vm.dirty_background_ratio = 5
EOF

    sysctl -p "${sysctl_conf}" 2>&1 | tee -a "${LOG_FILE}" || \
        log_warn "Some sysctl settings may not have applied."

    # Set file descriptor limits
    local limits_conf="/etc/security/limits.d/99-wp-master-installer.conf"
    rollback_backup "${limits_conf}" 2>/dev/null || true
    cat > "${limits_conf}" <<EOF
# wp-master-installer file descriptor limits
www-data soft nofile 65535
www-data hard nofile 65535
root     soft nofile 65535
root     hard nofile 65535
EOF

    log_success "Kernel optimizations applied."
}

# ---------------------------------------------------------------------------
# WordPress-specific optimizations
# ---------------------------------------------------------------------------
optimize_wordpress() {
    log_step "Applying WordPress optimizations..."

    [[ -f "${WP_DIR}/wp-config.php" ]] || return 0

    # Ensure object caching is configured
    if [[ "${REDIS_ENABLED:-false}" == "true" ]]; then
        log_info "Redis object cache active — no additional WP cache needed."
    fi

    # Set cron if real cron is preferred over WP-Cron
    local cron_file="/etc/cron.d/wordpress-${DOMAIN}"
    if [[ ! -f "${cron_file}" ]]; then
        cat > "${cron_file}" <<EOF
# WordPress WP-Cron via system cron (every 5 minutes)
*/5 * * * * www-data ${WP_CLI_BIN} --path=${WP_DIR} cron event run --due-now --quiet 2>/dev/null
EOF
        chmod 644 "${cron_file}"
        log_success "WordPress system cron configured."
    fi
}
