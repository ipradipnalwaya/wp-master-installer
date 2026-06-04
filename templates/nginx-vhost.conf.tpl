# =============================================================================
# WP Master Installer — Nginx Virtual Host Template
# Variables replaced at runtime: {{DOMAIN}}, {{WEB_ROOT}}, {{PHP_SOCKET}}
# =============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root  {{WEB_ROOT}}/{{DOMAIN}};
    index index.php index.html;

    access_log /var/log/nginx/{{DOMAIN}}-access.log combined buffer=512k flush=1m;
    error_log  /var/log/nginx/{{DOMAIN}}-error.log warn;

    # Security headers
    add_header X-Frame-Options        "SAMEORIGIN"  always;
    add_header X-XSS-Protection       "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy        "no-referrer-when-downgrade" always;

    autoindex off;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   {{PHP_SOCKET}};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location = /wp-config.php { deny all; return 404; }
    location = /xmlrpc.php    { deny all; return 404; }
    location ~ /\.            { deny all; return 404; }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|woff|woff2|ttf|svg|webp)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml image/svg+xml;
}
