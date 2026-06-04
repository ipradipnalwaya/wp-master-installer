#!/usr/bin/env bash
# =============================================================================
# modules/wordpress.sh — WordPress Download & Setup Module
# WP Master Installer
#
# Author    : Pradip Nalwaya
# Company   : Operisoft (https://operisoft.com)
# Copyright : © 2026 Pradip Nalwaya, Operisoft. All rights reserved.
# License   : MIT
# =============================================================================

[[ -n "${_WORDPRESS_SH_LOADED:-}" ]] && return 0
_WORDPRESS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
WP_DOMAIN="${WP_DOMAIN:-${DOMAIN:-localhost}}"
WP_DIR="/var/www/wordpress"    # always fixed

# ---------------------------------------------------------------------------
# Download & extract latest WordPress from wordpress.org
# ---------------------------------------------------------------------------
wordpress_download() {
    log_section "WordPress Download"

    mkdir -p "${WP_DIR}"
    chown www-data:www-data "${WP_DIR}"

    if [[ -f "${WP_DIR}/wp-login.php" ]]; then
        log_info "WordPress already present at ${WP_DIR}. Skipping download."
        return 0
    fi

    # Ensure unzip is available
    if ! command -v unzip &>/dev/null; then
        log_step "Installing unzip..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip || {
            log_error "Cannot install unzip. Aborting."
            return 1
        }
    fi

    local tmp_zip="/tmp/wordpress-latest.zip"
    local tmp_dir="/tmp/wordpress-extract"

    log_step "Downloading https://wordpress.org/latest.zip ..."
    curl -fsSL --connect-timeout 30 --retry 3 \
        "https://wordpress.org/latest.zip" -o "${tmp_zip}" || {
        log_error "Failed to download WordPress."
        rm -f "${tmp_zip}"
        return 1
    }

    # Validate zip
    if ! unzip -t "${tmp_zip}" &>/dev/null; then
        log_error "Downloaded file is not a valid zip archive."
        rm -f "${tmp_zip}"
        return 1
    fi

    log_step "Extracting to ${WP_DIR}..."
    rm -rf "${tmp_dir}"
    unzip -q "${tmp_zip}" -d "${tmp_dir}" || {
        log_error "Failed to extract WordPress zip."
        rm -f "${tmp_zip}"
        return 1
    }

    # unzip produces a 'wordpress' subdir — copy contents into WP_DIR
    cp -a "${tmp_dir}/wordpress/." "${WP_DIR}/"

    rm -rf "${tmp_zip}" "${tmp_dir}"
    chown -R www-data:www-data "${WP_DIR}"

    log_success "WordPress downloaded and extracted to ${WP_DIR}."
    return 0
}

# ---------------------------------------------------------------------------
# Set correct WordPress file/directory permissions
# ---------------------------------------------------------------------------
wordpress_set_permissions() {
    log_step "Setting WordPress file permissions..."

    chown -R www-data:www-data "${WP_DIR}"
    find "${WP_DIR}" -type d -exec chmod 755 {} \;
    find "${WP_DIR}" -type f -exec chmod 644 {} \;

    # wp-content writable by web server
    chmod 755 "${WP_DIR}/wp-content"
    find "${WP_DIR}/wp-content" -type d -exec chmod 755 {} \;
    find "${WP_DIR}/wp-content" -type f -exec chmod 644 {} \;

    # Create uploads directory
    mkdir -p "${WP_DIR}/wp-content/uploads"
    chown -R www-data:www-data "${WP_DIR}/wp-content/uploads"
    chmod 755 "${WP_DIR}/wp-content/uploads"

    log_success "Permissions set."
}

# ---------------------------------------------------------------------------
# Create .htaccess (Apache only)
# ---------------------------------------------------------------------------
wordpress_create_htaccess() {
    [[ "${WEB_SERVER,,}" == "apache" ]] || return 0

    local htaccess="${WP_DIR}/.htaccess"
    cat > "${htaccess}" <<'HTACCESS'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress

<Files wp-config.php>
    Require all denied
</Files>
<Files xmlrpc.php>
    Require all denied
</Files>
<FilesMatch "^\.">
    Require all denied
</FilesMatch>
Options -Indexes
HTACCESS

    chown www-data:www-data "${htaccess}"
    chmod 644 "${htaccess}"
    log_success ".htaccess created."
}
