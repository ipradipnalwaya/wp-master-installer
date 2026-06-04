#!/usr/bin/env bash
# =============================================================================
# modules/nginx.sh — Nginx Installation & Configuration Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_NGINX_SH_LOADED:-}" ]] && return 0
_NGINX_SH_LOADED=1

# ---------------------------------------------------------------------------
# Install latest stable Nginx from the official repo
# ---------------------------------------------------------------------------
nginx_install() {
    log_section "Installing Nginx (latest stable)"

    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then
        log_info "Nginx already installed. Skipping."
        return 0
    fi

    log_step "Adding Nginx official APT repository..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

    local codename
    codename="$(lsb_release -sc)"
    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu ${codename} nginx
EOF

    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx || {
        log_warn "Official repo failed. Falling back to Ubuntu repo..."
        rm -f /etc/apt/sources.list.d/nginx.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx || {
            log_error "Nginx installation failed."
            return 1
        }
    }

    systemctl enable nginx --quiet
    systemctl start  nginx || { log_error "Nginx failed to start."; return 1; }
    log_success "Nginx installed and started."
    return 0
}

# ---------------------------------------------------------------------------
# Configure Nginx virtual host for WordPress
# ---------------------------------------------------------------------------
nginx_configure_vhost() {
    log_section "Nginx Virtual Host Configuration"

    local vhost_file="/etc/nginx/sites-available/${DOMAIN}.conf"
    local vhost_link="/etc/nginx/sites-enabled/${DOMAIN}.conf"
    local web_root="/var/www/wordpress"   # always fixed

    # Detect actual PHP-FPM socket
    local php_socket
    php_socket="$(php_get_socket 2>/dev/null)" || true
    # Fallback: scan for any running php-fpm socket
    if [[ -z "${php_socket}" ]]; then
        local sock
        sock="$(find /run/php -name 'php*-fpm.sock' 2>/dev/null | head -1)"
        php_socket="${sock:+unix:${sock}}"
    fi
    [[ -z "${php_socket}" ]] && php_socket="unix:/run/php/php${PHP_VERSION:-8.3}-fpm.sock"

    # Detect Nginx worker user (official package = nginx, Ubuntu = www-data)
    local nginx_user
    nginx_user="$(grep -E '^user\s' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')"
    [[ -z "${nginx_user}" ]] && nginx_user="www-data"

    log_step "Writing Nginx vhost: ${vhost_file} (root: ${web_root}, php user: ${nginx_user})"

    # Align PHP-FPM pool socket ownership with Nginx worker user
    local pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    if [[ -f "${pool_conf}" ]]; then
        sed -i "s/^listen\.owner.*/listen.owner = ${nginx_user}/" "${pool_conf}"
        sed -i "s/^listen\.group.*/listen.group = ${nginx_user}/" "${pool_conf}"
        sed -i "s/^listen\.mode.*/listen.mode = 0660/"            "${pool_conf}"
        systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
        log_info "PHP-FPM socket ownership set to ${nginx_user}."
    fi

    # Official Nginx package uses /etc/nginx/conf.d/, Ubuntu uses sites-available
    if [[ ! -d /etc/nginx/sites-available ]]; then
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        if ! grep -q 'sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
            sed -i '/http {/a\    include /etc/nginx/sites-enabled/*.conf;' \
                /etc/nginx/nginx.conf
        fi
    fi

    cat > "${vhost_file}" <<NGINXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${web_root};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}-access.log combined buffer=512k flush=1m;
    error_log  /var/log/nginx/${DOMAIN}-error.log warn;

    add_header X-Frame-Options        "SAMEORIGIN"  always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header X-XSS-Protection       "1; mode=block" always;
    add_header Referrer-Policy        "no-referrer-when-downgrade" always;

    autoindex off;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include        fastcgi_params;
        fastcgi_pass   ${php_socket};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size  128k;
        fastcgi_buffers      4 256k;
    }

    location = /wp-config.php          { deny all; return 404; }
    location = /xmlrpc.php             { deny all; return 404; }
    location ~ /\.                     { deny all; return 404; }
    location ~* \.(htaccess|htpasswd|ini|log|sh|sql|bak)\$ { deny all; return 404; }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|woff|woff2|ttf|svg|webp)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json
               application/javascript application/rss+xml image/svg+xml;
}
NGINXCONF

    ln -sf "${vhost_file}" "${vhost_link}" 2>/dev/null || true

    # Remove default sites
    rm -f /etc/nginx/sites-enabled/default \
          /etc/nginx/conf.d/default.conf 2>/dev/null || true

    # Test and reload
    if ! nginx -t 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Nginx configuration test failed."
        return 1
    fi

    systemctl reload nginx || systemctl restart nginx || {
        log_error "Nginx reload failed."
        return 1
    }

    log_success "Nginx vhost configured for ${DOMAIN} → ${web_root}"
    return 0
}

# ---------------------------------------------------------------------------
# Nginx performance optimisation (called from optimize.sh)
# ---------------------------------------------------------------------------
nginx_optimize() {
    log_step "Applying Nginx performance optimizations..."

    local nginx_conf="/etc/nginx/nginx.conf"
    rollback_backup "${nginx_conf}"

    local worker_processes="${SYS_CPU_CORES:-auto}"
    local worker_connections=1024
    if [[ "${SYS_RAM_MB:-512}" -ge 2048 ]]; then
        worker_connections=2048
    fi
    if [[ "${SYS_RAM_MB:-512}" -ge 4096 ]]; then
        worker_connections=4096
    fi

    # Patch worker_processes
    sed -i "s/^worker_processes.*/worker_processes ${worker_processes};/" "${nginx_conf}"

    # Patch events block
    sed -i "s/worker_connections.*/worker_connections ${worker_connections};/" "${nginx_conf}"

    # Enable multi_accept
    if ! grep -q 'multi_accept' "${nginx_conf}"; then
        sed -i '/worker_connections/a\    multi_accept on;' "${nginx_conf}"
    fi

    # Enable sendfile, tcp_nopush, tcp_nodelay
    if ! grep -q 'sendfile' "${nginx_conf}"; then
        sed -i '/http {/a\    sendfile on;\n    tcp_nopush on;\n    tcp_nodelay on;\n    keepalive_timeout 65;\n    types_hash_max_size 2048;' \
            "${nginx_conf}"
    fi

    nginx -t 2>&1 | tee -a "${LOG_FILE}" && systemctl reload nginx
    log_success "Nginx optimized."
}

# ---------------------------------------------------------------------------
# Add SSL server block to existing vhost (called from ssl.sh)
# ---------------------------------------------------------------------------
nginx_enable_ssl() {
    local cert_path="$1"
    local key_path="$2"
    local vhost_file="/etc/nginx/sites-available/${DOMAIN}.conf"

    rollback_backup "${vhost_file}"

    log_step "Updating Nginx vhost for HTTPS..."

    local php_socket
    php_socket="$(php_get_socket)" || php_socket="unix:/run/php/php-fpm.sock"
    local web_root="${WEB_ROOT}/${DOMAIN}"

    cat > "${vhost_file}" <<NGINXSSL
# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# HTTPS server block
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_session_timeout 1d;
    ssl_session_cache   shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # HSTS (2 years)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    root ${web_root};
    index index.php index.html;

    access_log /var/log/nginx/${DOMAIN}-access.log combined buffer=512k flush=1m;
    error_log  /var/log/nginx/${DOMAIN}-error.log warn;

    # Security headers
    add_header X-Frame-Options           "SAMEORIGIN"  always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header X-Content-Type-Options    "nosniff"     always;
    add_header Referrer-Policy           "no-referrer-when-downgrade" always;
    add_header Permissions-Policy        "geolocation=(),camera=(),microphone=()" always;

    autoindex off;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   ${php_socket};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }

    location = /wp-config.php   { deny all; return 404; }
    location = /xmlrpc.php      { deny all; return 404; }
    location ~ /\.              { deny all; return 404; }
    location ~* \.(htaccess|htpasswd|ini|log|sh|sql|bak)$ { deny all; return 404; }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|woff|woff2|ttf|svg|webp)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    gzip            on;
    gzip_vary       on;
    gzip_comp_level 6;
    gzip_types      text/plain text/css text/xml application/json
                    application/javascript application/rss+xml
                    application/atom+xml image/svg+xml;
}
NGINXSSL

    nginx -t 2>&1 | tee -a "${LOG_FILE}" && systemctl reload nginx || {
        log_error "Nginx SSL vhost configuration failed."
        return 1
    }
    log_success "Nginx SSL vhost updated."
}
