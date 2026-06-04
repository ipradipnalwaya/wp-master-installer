; =============================================================================
; WP Master Installer — PHP-FPM Pool Template
; Variables: {{PHP_VER}}, {{MAX_CHILDREN}}, {{START_SERVERS}},
;            {{MIN_SPARE}}, {{MAX_SPARE}}, {{MEMORY_LIMIT}}
; =============================================================================

[www]
user  = www-data
group = www-data

listen = /run/php/php{{PHP_VER}}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

pm                   = dynamic
pm.max_children      = {{MAX_CHILDREN}}
pm.start_servers     = {{START_SERVERS}}
pm.min_spare_servers = {{MIN_SPARE}}
pm.max_spare_servers = {{MAX_SPARE}}
pm.max_requests      = 500

access.log  = /var/log/php{{PHP_VER}}-fpm-access.log
slowlog     = /var/log/php{{PHP_VER}}-fpm-slow.log
request_slowlog_timeout = 10s

php_admin_value[memory_limit]        = {{MEMORY_LIMIT}}
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size]       = 64M
php_admin_flag[display_errors]       = off
php_admin_flag[log_errors]           = on
php_admin_value[error_log]           = /var/log/php{{PHP_VER}}-fpm-errors.log
