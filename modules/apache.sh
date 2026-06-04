#!/usr/bin/env bash
# =============================================================================
# modules/apache.sh — Apache2 Installation & Configuration Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_APACHE_SH_LOADED:-}" ]] && return 0
_APACHE_SH_LOADED=1

# ---------------------------------------------------------------------------
# Install Apache2 (latest stable from Ubuntu repos)
# ---------------------------------------------------------------------------
apache_install() {
    log_section "Installing Apache2 (latest stable)"

    if dpkg -l apache2 2>/dev/null | grep -q '^ii'; then
        log_info "Apache2 already installed. Skipping."
    else
        log_step "Installing Apache2 and modules..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            apache2 \
            apache2-utils \
            libapache2-mod-fcgid || {
            log_error "Apache2 installation failed."
            return 1
        }
    fi

    log_step "Enabling required Apache2 modules..."
    local mods=(
        rewrite headers expires deflate
        proxy proxy_fcgi setenvif
        ssl http2
        mpm_event
    )
    for mod in "${mods[@]}"; do
        a2enmod "${mod}" --quiet 2>/dev/null || log_warn "Module '${mod}' may not be available."
    done

    # Disable prefork if mpm_event is available
    a2dismod mpm_prefork --quiet 2>/dev/null || true

    systemctl enable apache2 --quiet
    systemctl start  apache2 || { log_error "Apache2 failed to start."; return 1; }
    log_success "Apache2 installed and started."
    return 0
}

# ---------------------------------------------------------------------------
# Configure Apache2 virtual host for WordPress
# ---------------------------------------------------------------------------
apache_configure_vhost() {
    log_section "Apache2 Virtual Host Configuration"

    local vhost_file="/etc/apache2/sites-available/${DOMAIN}.conf"
    local web_root="${WEB_ROOT}/${DOMAIN}"
    local php_socket
    php_socket="$(php_get_socket)" || php_socket="unix:/run/php/php-fpm.sock|fcgi://localhost"

    rollback_backup "${vhost_file}" 2>/dev/null || true

    log_step "Writing Apache2 vhost: ${vhost_file}"

    cat > "${vhost_file}" <<APACHECONF
<VirtualHost *:80>
    ServerName   ${DOMAIN}
    ServerAlias  www.${DOMAIN}
    DocumentRoot ${web_root}

    # Logging
    ErrorLog  \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined

    # PHP-FPM via proxy
    <FilesMatch \.php$>
        SetHandler "proxy:${php_socket}"
    </FilesMatch>

    <Directory ${web_root}>
        Options -Indexes -FollowSymLinks
        AllowOverride All
        Require all granted

        # Security headers
        Header always set X-Frame-Options           "SAMEORIGIN"
        Header always set X-XSS-Protection          "1; mode=block"
        Header always set X-Content-Type-Options    "nosniff"
        Header always set Referrer-Policy           "no-referrer-when-downgrade"
        Header always set Permissions-Policy        "geolocation=(),camera=(),microphone=()"
    </Directory>

    # Protect wp-config.php
    <Files wp-config.php>
        Require all denied
    </Files>

    # Disable XML-RPC
    <Files xmlrpc.php>
        Require all denied
    </Files>

    # Block hidden files
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>

    # Block sensitive extensions
    <FilesMatch "\.(htaccess|htpasswd|ini|log|sh|sql|bak)$">
        Require all denied
    </FilesMatch>

    # Enable compression
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/plain text/html text/css
        AddOutputFilterByType DEFLATE application/json application/javascript
        AddOutputFilterByType DEFLATE application/xml text/xml
        AddOutputFilterByType DEFLATE image/svg+xml
    </IfModule>

    # Cache static assets
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/jpeg      "access plus 1 year"
        ExpiresByType image/png       "access plus 1 year"
        ExpiresByType image/gif       "access plus 1 year"
        ExpiresByType image/webp      "access plus 1 year"
        ExpiresByType image/svg+xml   "access plus 1 year"
        ExpiresByType text/css        "access plus 1 year"
        ExpiresByType application/javascript "access plus 1 year"
        ExpiresByType font/woff       "access plus 1 year"
        ExpiresByType font/woff2      "access plus 1 year"
    </IfModule>

    # Keep-Alive
    KeepAlive On
    KeepAliveTimeout 5
    MaxKeepAliveRequests 100
</VirtualHost>
APACHECONF

    log_step "Enabling site: ${DOMAIN}"
    a2ensite "${DOMAIN}.conf" --quiet || {
        log_error "Failed to enable Apache2 site."
        return 1
    }

    a2dissite 000-default.conf --quiet 2>/dev/null || true

    # Test configuration
    apache2ctl configtest 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Apache2 configuration test failed."
        return 1
    }

    systemctl reload apache2 || systemctl restart apache2 || {
        log_error "Apache2 reload failed."
        return 1
    }

    log_success "Apache2 virtual host configured: ${vhost_file}"
    return 0
}

# ---------------------------------------------------------------------------
# Enable SSL on Apache2 (called from ssl.sh)
# ---------------------------------------------------------------------------
apache_enable_ssl() {
    local cert_path="$1"
    local key_path="$2"
    local ssl_vhost_file="/etc/apache2/sites-available/${DOMAIN}-ssl.conf"
    local web_root="${WEB_ROOT}/${DOMAIN}"
    local php_socket
    php_socket="$(php_get_socket)" || php_socket="unix:/run/php/php-fpm.sock|fcgi://localhost"

    rollback_backup "${ssl_vhost_file}" 2>/dev/null || true

    log_step "Writing Apache2 SSL vhost..."

    cat > "${ssl_vhost_file}" <<APACHESSLCONF
# HTTP -> HTTPS redirect
<VirtualHost *:80>
    ServerName  ${DOMAIN}
    ServerAlias www.${DOMAIN}
    Redirect permanent / https://${DOMAIN}/
</VirtualHost>

# HTTPS VirtualHost
<VirtualHost *:443>
    ServerName   ${DOMAIN}
    ServerAlias  www.${DOMAIN}
    DocumentRoot ${web_root}

    SSLEngine             on
    SSLCertificateFile    ${cert_path}
    SSLCertificateKeyFile ${key_path}

    # Modern TLS
    SSLProtocol             -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder     off
    SSLSessionTickets       off

    # PHP-FPM
    <FilesMatch \.php$>
        SetHandler "proxy:${php_socket}"
    </FilesMatch>

    <Directory ${web_root}>
        Options -Indexes -FollowSymLinks
        AllowOverride All
        Require all granted

        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        Header always set X-Frame-Options           "SAMEORIGIN"
        Header always set X-XSS-Protection          "1; mode=block"
        Header always set X-Content-Type-Options    "nosniff"
        Header always set Referrer-Policy           "no-referrer-when-downgrade"
    </Directory>

    <Files wp-config.php>    Require all denied </Files>
    <Files xmlrpc.php>       Require all denied </Files>
    <FilesMatch "^\.">       Require all denied </FilesMatch>

    ErrorLog  \${APACHE_LOG_DIR}/${DOMAIN}-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-access.log combined

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/plain text/html text/css
        AddOutputFilterByType DEFLATE application/json application/javascript
    </IfModule>
</VirtualHost>
APACHESSLCONF

    a2ensite "${DOMAIN}-ssl.conf" --quiet
    a2enmod  ssl http2 --quiet 2>/dev/null || true

    # Disable plain HTTP vhost
    a2dissite "${DOMAIN}.conf" --quiet 2>/dev/null || true

    apache2ctl configtest 2>&1 | tee -a "${LOG_FILE}" && \
        systemctl reload apache2 || {
        log_error "Apache2 SSL vhost failed."
        return 1
    }
    log_success "Apache2 SSL vhost enabled."
}

# ---------------------------------------------------------------------------
# Apache2 MPM Event optimisation (called from optimize.sh)
# ---------------------------------------------------------------------------
apache_optimize() {
    log_step "Applying Apache2 MPM Event optimizations..."

    local mpm_conf="/etc/apache2/mods-available/mpm_event.conf"
    rollback_backup "${mpm_conf}"

    local start_servers=2
    local min_spare_threads=25
    local max_spare_threads=75
    local thread_limit=64
    local threads_per_child=25
    local max_request_workers=150
    local max_conn_per_child=0

    if [[ "${SYS_RAM_MB:-512}" -ge 2048 ]]; then
        start_servers=4
        min_spare_threads=50
        max_spare_threads=150
        max_request_workers=300
    fi

    if [[ "${SYS_RAM_MB:-512}" -ge 4096 ]]; then
        start_servers=8
        min_spare_threads=75
        max_spare_threads=250
        max_request_workers=500
        thread_limit=128
    fi

    cat > "${mpm_conf}" <<EOF
<IfModule mpm_event_module>
    StartServers            ${start_servers}
    MinSpareThreads         ${min_spare_threads}
    MaxSpareThreads         ${max_spare_threads}
    ThreadLimit             ${thread_limit}
    ThreadsPerChild         ${threads_per_child}
    MaxRequestWorkers       ${max_request_workers}
    MaxConnectionsPerChild  ${max_conn_per_child}
</IfModule>
EOF

    apache2ctl configtest 2>&1 | tee -a "${LOG_FILE}" && \
        systemctl reload apache2 || log_warn "Apache2 optimization reload failed."
    log_success "Apache2 optimized."
}
