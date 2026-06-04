#!/usr/bin/env bash
# =============================================================================
# modules/ssl.sh — Let's Encrypt SSL Certificate Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_SSL_SH_LOADED:-}" ]] && return 0
_SSL_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SSL_DOMAIN="${SSL_DOMAIN:-${DOMAIN:-localhost}}"
# Always derive SSL_EMAIL from ADMIN_EMAIL at runtime — never fall back to a placeholder
SSL_EMAIL="${ADMIN_EMAIL:-${SSL_EMAIL:-}}"
SSL_CERT_PATH="/etc/letsencrypt/live/${SSL_DOMAIN}/fullchain.pem"
SSL_KEY_PATH="/etc/letsencrypt/live/${SSL_DOMAIN}/privkey.pem"
SSL_ENABLED=false

# ---------------------------------------------------------------------------
# Install Certbot
# ---------------------------------------------------------------------------
ssl_install_certbot() {
    log_section "Certbot Installation"

    if command -v certbot &>/dev/null; then
        log_info "Certbot already installed: $(certbot --version 2>&1)"
        return 0
    fi

    log_step "Installing Certbot via snap..."
    # Prefer snap (official recommended method)
    if command -v snap &>/dev/null; then
        snap install --classic certbot 2>&1 | tee -a "${LOG_FILE}"
        ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
    else
        log_step "Snap not available. Installing Certbot via apt..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot \
            "python3-certbot-${WEB_SERVER}" 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot || {
            log_error "Certbot installation failed."
            return 1
        }
    fi

    # Install web server plugin
    case "${WEB_SERVER,,}" in
        nginx)
            snap install certbot-nginx 2>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-certbot-nginx 2>/dev/null || true
            ;;
        apache)
            snap install certbot-apache 2>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-certbot-apache 2>/dev/null || true
            ;;
    esac

    if command -v certbot &>/dev/null; then
        log_success "Certbot installed: $(certbot --version 2>&1)"
    else
        log_error "Certbot installation verification failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify DNS resolves to this server
# ---------------------------------------------------------------------------
ssl_verify_dns() {
    log_step "Verifying DNS for ${SSL_DOMAIN}..."

    # SYS_SERVER_IP may be empty if os_detect was skipped — read directly
    local server_ip="${SYS_SERVER_IP}"
    if [[ -z "${server_ip}" ]]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi

    local resolved_ip
    resolved_ip=$(dig +short "${SSL_DOMAIN}" A 2>/dev/null \
        || host -t A "${SSL_DOMAIN}" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 \
        || nslookup "${SSL_DOMAIN}" 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print $2}' | head -1)

    if [[ -z "${resolved_ip}" ]]; then
        resolved_ip=$(dig +short "www.${SSL_DOMAIN}" A 2>/dev/null || echo "")
    fi

    if [[ -z "${resolved_ip}" ]]; then
        log_warn "DNS resolution for '${SSL_DOMAIN}' failed. SSL certificate generation may fail."
        log_warn "Ensure your domain's A record points to ${server_ip}"
        return 1
    fi

    if [[ "${resolved_ip}" != "${server_ip}" ]]; then
        log_warn "DNS for '${SSL_DOMAIN}' resolves to ${resolved_ip}, but server IP is ${server_ip}."
        log_warn "SSL certificate generation may fail if DNS doesn't match."
    else
        log_success "DNS verified: ${SSL_DOMAIN} -> ${resolved_ip}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Obtain SSL certificate
# ---------------------------------------------------------------------------
ssl_obtain_certificate() {
    log_section "SSL Certificate Generation (Let's Encrypt)"

    # Abort early if email is missing or still a placeholder
    if [[ -z "${SSL_EMAIL}" || "${SSL_EMAIL}" == *"example.com"* ]]; then
        log_error "SSL email is not set or is a placeholder ('${SSL_EMAIL}')."
        log_error "Provide a real email via --email or the wizard prompt. Skipping SSL."
        return 1
    fi

    # Check if certificate already exists and is valid
    if [[ -f "${SSL_CERT_PATH}" ]]; then
        log_info "SSL certificate already exists for ${SSL_DOMAIN}."
        SSL_ENABLED=true
        return 0
    fi

    ssl_verify_dns || log_warn "Proceeding despite DNS warning..."

    # Stop web server temporarily if using standalone
    local certbot_args=(
        --non-interactive
        --agree-tos
        --email "${SSL_EMAIL}"
        --domains "${SSL_DOMAIN}"
        --domains "www.${SSL_DOMAIN}"
        --redirect
        --rsa-key-size 4096
    )

    log_step "Requesting certificate for ${SSL_DOMAIN}..."

    case "${WEB_SERVER,,}" in
        nginx)
            certbot --nginx "${certbot_args[@]}" 2>&1 | tee -a "${LOG_FILE}" || {
                log_warn "Nginx certbot plugin failed. Trying standalone..."
                ssl_obtain_standalone
            }
            ;;
        apache)
            certbot --apache "${certbot_args[@]}" 2>&1 | tee -a "${LOG_FILE}" || {
                log_warn "Apache certbot plugin failed. Trying standalone..."
                ssl_obtain_standalone
            }
            ;;
        *)
            ssl_obtain_standalone
            ;;
    esac

    if [[ -f "${SSL_CERT_PATH}" ]]; then
        SSL_ENABLED=true
        log_success "SSL certificate obtained for ${SSL_DOMAIN}."
    else
        log_error "SSL certificate generation failed."
        return 1
    fi

    # Update web server vhost for SSL
    _ssl_update_vhost

    return 0
}

# ---------------------------------------------------------------------------
# Standalone certbot (fallback)
# ---------------------------------------------------------------------------
ssl_obtain_standalone() {
    log_step "Using certbot standalone mode..."

    # Temporarily stop web server
    systemctl stop "${WEB_SERVER}" 2>/dev/null || true

    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "${SSL_EMAIL}" \
        -d "${SSL_DOMAIN}" \
        -d "www.${SSL_DOMAIN}" \
        --rsa-key-size 4096 \
        2>&1 | tee -a "${LOG_FILE}"

    local result=$?

    # Restart web server
    systemctl start "${WEB_SERVER}" 2>/dev/null || true

    return "${result}"
}

# ---------------------------------------------------------------------------
# Update web server configuration for SSL
# ---------------------------------------------------------------------------
_ssl_update_vhost() {
    log_step "Updating ${WEB_SERVER} vhost for SSL..."

    case "${WEB_SERVER,,}" in
        nginx)
            nginx_enable_ssl "${SSL_CERT_PATH}" "${SSL_KEY_PATH}" || return 1
            ;;
        apache)
            apache_enable_ssl "${SSL_CERT_PATH}" "${SSL_KEY_PATH}" || return 1
            ;;
    esac

    # Update WordPress URL to HTTPS
    if [[ -f "${WP_DIR}/wp-config.php" ]]; then
        sed -i "s|define( 'WP_HOME'.*|define( 'WP_HOME', 'https://${SSL_DOMAIN}' );|" \
            "${WP_DIR}/wp-config.php" 2>/dev/null || true
        sed -i "s|define( 'WP_SITEURL'.*|define( 'WP_SITEURL', 'https://${SSL_DOMAIN}' );|" \
            "${WP_DIR}/wp-config.php" 2>/dev/null || true
        log_success "WordPress URLs updated to HTTPS."
    fi
}

# ---------------------------------------------------------------------------
# Setup auto-renewal
# ---------------------------------------------------------------------------
ssl_setup_auto_renewal() {
    log_section "SSL Auto-Renewal Configuration"

    # Certbot installs a systemd timer or cron automatically
    # Verify it's in place and add a custom cron as fallback

    # Check for certbot systemd timer
    if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
        log_success "Certbot systemd timer found (auto-renewal active)."
        return 0
    fi

    log_step "Setting up certbot auto-renewal cron job..."
    local cron_job="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload ${WEB_SERVER}'"
    local cron_file="/etc/cron.d/certbot-renewal"

    cat > "${cron_file}" <<EOF
# Let's Encrypt SSL auto-renewal
# Runs twice daily with actual renewal only when cert is within 30 days of expiry
0 3,15 * * * root certbot renew --quiet --deploy-hook "systemctl reload ${WEB_SERVER} 2>/dev/null || true"
EOF
    chmod 644 "${cron_file}"
    log_success "Auto-renewal cron job configured: ${cron_file}"

    return 0
}

# ---------------------------------------------------------------------------
# Dry-run renewal test
# ---------------------------------------------------------------------------
ssl_test_renewal() {
    log_section "SSL Auto-Renewal Dry Run"
    log_step "Running: certbot renew --dry-run ..."

    certbot renew --dry-run 2>&1 | tee -a "${LOG_FILE}"
    local result=$?

    if [[ "${result}" -eq 0 ]]; then
        log_success "Auto-renewal dry run PASSED."
        return 0
    else
        log_error "Auto-renewal dry run FAILED. Check Certbot configuration."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify SSL is working
# ---------------------------------------------------------------------------
ssl_verify() {
    log_step "Verifying SSL certificate for ${SSL_DOMAIN}..."

    if [[ ! -f "${SSL_CERT_PATH}" ]]; then
        log_error "Certificate file not found: ${SSL_CERT_PATH}"
        return 1
    fi

    # Check expiry
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "${SSL_CERT_PATH}" 2>/dev/null | cut -d= -f2)
    if [[ -n "${expiry}" ]]; then
        log_success "Certificate valid until: ${expiry}"
    fi

    # Check if HTTPS is reachable (curl check)
    if curl -fsS --max-time 10 "https://${SSL_DOMAIN}/" -o /dev/null 2>/dev/null; then
        log_success "HTTPS is accessible at https://${SSL_DOMAIN}/"
    else
        log_warn "HTTPS check failed for https://${SSL_DOMAIN}/ (may be DNS propagation)."
    fi

    return 0
}
