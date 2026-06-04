# =============================================================================
# WP Master Installer — Apache2 Virtual Host Template
# Variables replaced at runtime: {{DOMAIN}}, {{WEB_ROOT}}, {{PHP_SOCKET}}
# =============================================================================

<VirtualHost *:80>
    ServerName  {{DOMAIN}}
    ServerAlias www.{{DOMAIN}}

    DocumentRoot {{WEB_ROOT}}/{{DOMAIN}}

    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}-error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}-access.log combined

    <FilesMatch \.php$>
        SetHandler "proxy:{{PHP_SOCKET}}"
    </FilesMatch>

    <Directory {{WEB_ROOT}}/{{DOMAIN}}>
        Options -Indexes -FollowSymLinks
        AllowOverride All
        Require all granted

        Header always set X-Frame-Options        "SAMEORIGIN"
        Header always set X-XSS-Protection       "1; mode=block"
        Header always set X-Content-Type-Options "nosniff"
        Header always set Referrer-Policy        "no-referrer-when-downgrade"
    </Directory>

    <Files wp-config.php> Require all denied </Files>
    <Files xmlrpc.php>    Require all denied </Files>
    <FilesMatch "^\.">    Require all denied </FilesMatch>

    KeepAlive On
    KeepAliveTimeout 5
    MaxKeepAliveRequests 100
</VirtualHost>
