#!/usr/bin/env bash
# =============================================================================
# modules/wordpress.sh — WordPress Download, Config & Installation Module
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
# Globals (set by caller / wizard)
# ---------------------------------------------------------------------------
WP_DOMAIN="${WP_DOMAIN:-${DOMAIN:-localhost}}"
WP_DIR="/var/www/wordpress"          # always fixed — WordPress standard location
WP_CLI_BIN="/usr/local/bin/wp"

# ---------------------------------------------------------------------------
# Install WP-CLI
# ---------------------------------------------------------------------------
wpcli_install() {
    log_section "WP-CLI Installation"

    if [[ -x "${WP_CLI_BIN}" ]]; then
        local current_ver
        current_ver="$(_wpcli_run --version 2>/dev/null | awk '{print $2}')"
        log_info "WP-CLI already installed: v${current_ver}"
        return 0
    fi

    if ! command -v php &>/dev/null; then
        log_error "PHP is not installed or not in PATH. WP-CLI requires PHP."
        return 1
    fi

    log_step "Downloading WP-CLI..."
    local tmp_phar
    tmp_phar="$(mktemp /tmp/wp-cli.phar.XXXXXX)"

    # Try multiple official sources in order
    local urls=(
        "https://github.com/wp-cli/wp-cli/releases/latest/download/wp-cli.phar"
        "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        "https://wp-cli.org/packages/phar/wp-cli.phar"
    )

    local downloaded=false
    for url in "${urls[@]}"; do
        log_info "Trying: ${url}"
        if curl -fsSL --connect-timeout 15 --retry 3 "${url}" -o "${tmp_phar}" 2>/dev/null; then
            # Verify it is actually a PHP phar (first bytes must be <?php)
            if head -c 5 "${tmp_phar}" | grep -q '<?php'; then
                downloaded=true
                log_info "Downloaded successfully from: ${url}"
                break
            else
                log_warn "Response from ${url} is not a valid PHP phar. Trying next..."
            fi
        else
            log_warn "Failed to fetch from ${url}. Trying next..."
        fi
    done

    if [[ "${downloaded}" != "true" ]]; then
        rm -f "${tmp_phar}"
        log_error "All WP-CLI download sources failed."
        log_info  "Manual install: curl -O https://github.com/wp-cli/wp-cli/releases/latest/download/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"
        return 1
    fi

    chmod +x "${tmp_phar}"
    mv "${tmp_phar}" "${WP_CLI_BIN}"

    local ver
    ver="$(_wpcli_run --version 2>/dev/null)"
    if [[ -n "${ver}" ]]; then
        log_success "WP-CLI installed: ${ver}"
    else
        log_error "WP-CLI verification failed."
        rm -f "${WP_CLI_BIN}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Internal: run WP-CLI via php if direct execution fails
# ---------------------------------------------------------------------------
_wpcli_run() {
    if "${WP_CLI_BIN}" "$@" 2>/dev/null; then
        return 0
    fi
    # Fallback: invoke explicitly through php
    php "${WP_CLI_BIN}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: run WP-CLI as www-data
# ---------------------------------------------------------------------------
wp() {
    sudo -u www-data php "${WP_CLI_BIN}" \
        --path="${WP_DIR}" \
        --allow-root \
        "$@"
}

# ---------------------------------------------------------------------------
# Download & extract latest WordPress
# ---------------------------------------------------------------------------
wordpress_download() {
    log_section "WordPress Download"

    mkdir -p "${WP_DIR}"
    chown www-data:www-data "${WP_DIR}"

    if [[ -f "${WP_DIR}/wp-config.php" ]] || [[ -f "${WP_DIR}/wp-login.php" ]]; then
        log_info "WordPress already present at ${WP_DIR}. Skipping download."
        return 0
    fi

    log_step "Downloading latest WordPress to ${WP_DIR}..."
    sudo -u www-data "${WP_CLI_BIN}" core download \
        --path="${WP_DIR}" \
        --locale=en_US \
        --allow-root \
        2>&1 | tee -a "${LOG_FILE}" || {
        log_error "WordPress download failed."
        return 1
    }

    log_success "WordPress downloaded."
    return 0
}

# ---------------------------------------------------------------------------
# Generate secure WordPress salts
# ---------------------------------------------------------------------------
_wp_generate_salts() {
    curl -fsSL "https://api.wordpress.org/secret-key/1.1/salt/" 2>/dev/null \
        || _wp_generate_salts_local
}

_wp_generate_salts_local() {
    # Fallback: generate salts locally if API unreachable
    local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_[]{}<>~`+=,.;:/?|'
    local salt_keys=(
        AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
        AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT
    )
    for key in "${salt_keys[@]}"; do
        local val
        val="$(cat /dev/urandom | tr -dc "${chars}" | fold -w 64 | head -1)"
        printf "define('%s', '%s');\n" "${key}" "${val}"
    done
}

# ---------------------------------------------------------------------------
# Create wp-config.php
# ---------------------------------------------------------------------------
wordpress_configure() {
    log_section "WordPress Configuration"

    local wp_config="${WP_DIR}/wp-config.php"
    local wp_config_sample="${WP_DIR}/wp-config-sample.php"

    rollback_backup "${wp_config}" 2>/dev/null || true

    if [[ -z "${WP_ADMIN_PASS}" ]]; then
        WP_ADMIN_PASS="$(openssl rand -base64 16)"
        log_info "Generated WordPress admin password."
    fi

    # Generate table prefix (random for security)
    local table_prefix
    table_prefix="wp_$(openssl rand -hex 3)_"

    log_step "Creating wp-config.php..."

    # Fetch salts
    local salts
    salts="$(_wp_generate_salts)"

    # Build site URL
    local site_url
    site_url="https://${WP_DOMAIN}"

    cp "${wp_config_sample}" "${wp_config}" || {
        log_error "wp-config-sample.php not found."
        return 1
    }

    # Replace database settings
    sed -i "s/database_name_here/${DB_NAME}/"   "${wp_config}"
    sed -i "s/username_here/${DB_USER}/"         "${wp_config}"
    sed -i "s/password_here/${DB_PASS}/"         "${wp_config}"
    sed -i "s/localhost/127.0.0.1/"              "${wp_config}"
    sed -i "s/wp_/${table_prefix}/g"             "${wp_config}"

    # Replace salts placeholder block
    # shellcheck disable=SC2016
    python3 - "${wp_config}" "${salts}" <<'PYEOF' 2>/dev/null || \
    _wp_replace_salts_bash "${wp_config}" "${salts}"
import sys, re

config_path = sys.argv[1]
new_salts   = sys.argv[2]

with open(config_path, 'r') as f:
    content = f.read()

# Remove existing salt lines
content = re.sub(
    r"define\s*\(\s*'(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)'.*?\n",
    '', content
)

# Insert after the DB_COLLATE line
marker = "define( 'DB_COLLATE', '' );"
content = content.replace(marker, marker + "\n\n" + new_salts)

with open(config_path, 'w') as f:
    f.write(content)
PYEOF

    # Add extra WordPress constants
    cat >> "${wp_config}" <<WPEXTRA

/* WordPress site URL */
define( 'WP_HOME',    '${site_url}' );
define( 'WP_SITEURL', '${site_url}' );

/* Security */
define( 'DISALLOW_FILE_EDIT',    true  );
define( 'FORCE_SSL_ADMIN',       true  );
define( 'WP_POST_REVISIONS',     5     );
define( 'AUTOSAVE_INTERVAL',     300   );

/* Cron */
define( 'DISABLE_WP_CRON', false );

/* Memory */
define( 'WP_MEMORY_LIMIT',     '256M' );
define( 'WP_MAX_MEMORY_LIMIT', '512M' );

/* Trash */
define( 'EMPTY_TRASH_DAYS', 7 );

/* Debug (disabled for production) */
define( 'WP_DEBUG',         false );
define( 'WP_DEBUG_LOG',     false );
define( 'WP_DEBUG_DISPLAY', false );
define( 'SCRIPT_DEBUG',     false );

WPEXTRA

    log_success "wp-config.php created."
    return 0
}

_wp_replace_salts_bash() {
    local config="$1"
    local salts="$2"
    # Simple bash fallback: just append salts if python3 unavailable
    local salt_keys=(AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
                     AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT)
    for key in "${salt_keys[@]}"; do
        sed -i "/define.*'${key}'/d" "${config}"
    done
    echo "${salts}" >> "${config}"
}

# ---------------------------------------------------------------------------
# Set correct WordPress file/directory permissions
# ---------------------------------------------------------------------------
wordpress_set_permissions() {
    log_step "Setting WordPress file permissions..."

    chown -R www-data:www-data "${WP_DIR}"
    find "${WP_DIR}" -type d -exec chmod 755 {} \;
    find "${WP_DIR}" -type f -exec chmod 644 {} \;

    # Stricter permissions on sensitive files
    chmod 440 "${WP_DIR}/wp-config.php" 2>/dev/null || true

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
# Create .htaccess (for Apache)
# ---------------------------------------------------------------------------
wordpress_create_htaccess() {
    [[ "${WEB_SERVER,,}" == "apache" ]] || return 0

    local htaccess="${WP_DIR}/.htaccess"
    cat > "${htaccess}" <<'HTACCESS'
# WordPress .htaccess
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

# Security
<Files wp-config.php>
    Require all denied
</Files>

<Files xmlrpc.php>
    Require all denied
</Files>

<FilesMatch "^\.">
    Require all denied
</FilesMatch>

# Disable directory listing
Options -Indexes

# Prevent script execution in uploads
<Directory "wp-content/uploads">
    <FilesMatch "\.(php|php5|phtml)$">
        Require all denied
    </FilesMatch>
</Directory>
HTACCESS

    chown www-data:www-data "${htaccess}"
    chmod 644 "${htaccess}"
    log_success ".htaccess created."
}

# ---------------------------------------------------------------------------
# Run WordPress core install via WP-CLI
# ---------------------------------------------------------------------------
wordpress_install() {
    log_section "WordPress Core Installation"

    # Check if already installed
    if wp core is-installed 2>/dev/null; then
        log_info "WordPress already installed. Skipping core install."
        return 0
    fi

    log_step "Running WordPress installation..."
    wp core install \
        --url="https://${WP_DOMAIN}" \
        --title="${WP_SITE_TITLE}" \
        --admin_user="${WP_ADMIN_USER}" \
        --admin_password="${WP_ADMIN_PASS}" \
        --admin_email="${WP_ADMIN_EMAIL}" \
        --skip-email \
        2>&1 | tee -a "${LOG_FILE}" || {
        log_error "WordPress core installation failed."
        return 1
    }

    log_success "WordPress installed."

    # Post-install configuration
    wordpress_post_install_config

    log_success "WordPress fully configured at https://${WP_DOMAIN}"
    return 0
}

# ---------------------------------------------------------------------------
# Post-install WordPress configuration via WP-CLI
# ---------------------------------------------------------------------------
wordpress_post_install_config() {
    log_step "Applying WordPress post-install configuration..."

    # Set timezone
    wp option update timezone_string "UTC" 2>/dev/null || true

    # Set permalink structure (pretty URLs)
    wp rewrite structure '/%postname%/' --hard 2>/dev/null || true
    wp rewrite flush --hard 2>/dev/null || true

    # Discourage search engine indexing initially (can be changed in WP admin)
    wp option update blog_public 1 2>/dev/null || true

    # Set default ping status and comment settings
    wp option update default_ping_status closed  2>/dev/null || true
    wp option update default_comment_status open 2>/dev/null || true

    # Delete sample post/page
    wp post delete 1 --force 2>/dev/null || true  # Hello World
    wp post delete 2 --force 2>/dev/null || true  # Sample Page

    # Create a default page
    wp post create \
        --post_type=page \
        --post_status=publish \
        --post_title="Home" \
        --post_content="Welcome to ${WP_SITE_TITLE}" \
        2>/dev/null || true

    # Delete default themes (keep twentytwentyfour as fallback)
    wp theme delete twentytwentyone 2>/dev/null || true
    wp theme delete twentytwentytwo 2>/dev/null || true
    wp theme delete twentytwentythree 2>/dev/null || true

    # Delete unused plugins
    wp plugin delete hello akismet 2>/dev/null || true

    # Update all to latest
    wp core update --quiet 2>/dev/null || true
    wp plugin update --all --quiet 2>/dev/null || true
    wp theme update --all --quiet 2>/dev/null || true

    log_success "WordPress post-install configuration complete."
}

# ---------------------------------------------------------------------------
# Verify WordPress is working
# ---------------------------------------------------------------------------
wordpress_verify() {
    log_step "Verifying WordPress installation..."

    if wp core is-installed 2>/dev/null; then
        local version
        version="$(wp core version 2>/dev/null)"
        log_success "WordPress ${version} is installed and working."
        return 0
    else
        log_error "WordPress installation check failed."
        return 1
    fi
}
