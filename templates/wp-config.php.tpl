<?php
/**
 * WP Master Installer — wp-config.php Template
 * Generated values replace {{PLACEHOLDERS}} at runtime.
 *
 * @package WordPress
 */

// ** Database settings ** //
define( 'DB_NAME',     '{{DB_NAME}}' );
define( 'DB_USER',     '{{DB_USER}}' );
define( 'DB_PASSWORD', '{{DB_PASS}}' );
define( 'DB_HOST',     '127.0.0.1' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  'utf8mb4_unicode_ci' );

// ** Authentication unique keys and salts ** //
{{SALTS}}

$table_prefix = '{{TABLE_PREFIX}}';

// ** Site URLs ** //
define( 'WP_HOME',    'https://{{DOMAIN}}' );
define( 'WP_SITEURL', 'https://{{DOMAIN}}' );

// ** Security ** //
define( 'DISALLOW_FILE_EDIT',    true  );
define( 'FORCE_SSL_ADMIN',       true  );
define( 'WP_POST_REVISIONS',     5     );
define( 'AUTOSAVE_INTERVAL',     300   );

// ** Memory ** //
define( 'WP_MEMORY_LIMIT',     '256M' );
define( 'WP_MAX_MEMORY_LIMIT', '512M' );

// ** Redis Cache ** //
define( 'WP_REDIS_HOST',     '127.0.0.1' );
define( 'WP_REDIS_PORT',     6379 );
define( 'WP_REDIS_DATABASE', 0 );
define( 'WP_CACHE',          true );

// ** Cron ** //
define( 'DISABLE_WP_CRON', false );

// ** Trash ** //
define( 'EMPTY_TRASH_DAYS', 7 );

// ** Debug (disabled for production) ** //
define( 'WP_DEBUG',         false );
define( 'WP_DEBUG_LOG',     false );
define( 'WP_DEBUG_DISPLAY', false );
define( 'SCRIPT_DEBUG',     false );

/* Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

/* Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';
