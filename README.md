# WP Master Installer

**Universal Ubuntu WordPress Stack Installer**
Production-grade, fully automated WordPress deployment for Ubuntu servers.

---

## Table of Contents

- [Overview](#overview)
- [Supported Systems](#supported-systems)
- [Stack Components](#stack-components)
- [Project Structure](#project-structure)
- [Getting the Installer onto Your Server](#getting-the-installer-onto-your-server)
- [Prerequisites](#prerequisites)
- [How to Run](#how-to-run)
  - [Interactive Mode](#1-interactive-mode-recommended-for-beginners)
  - [Unattended Mode with Config File](#2-unattended-mode-with-config-file)
  - [Unattended Mode with Flags](#3-unattended-mode-with-flags)
  - [CI/CD Pipeline Mode](#4-cicd-pipeline-mode)
- [All Command-Line Options](#all-command-line-options)
- [Configuration File Reference](#configuration-file-reference)
- [What Gets Installed](#what-gets-installed)
- [After Installation](#after-installation)
- [Verification & Health Checks](#verification--health-checks)
- [Rollback System](#rollback-system)
- [Troubleshooting](#troubleshooting)
- [Module Reference](#module-reference)
- [Security Model](#security-model)
- [License](#license)

---

## Overview

WP Master Installer sets up a complete WordPress stack on Ubuntu in a single command. It handles everything: web server, PHP, MariaDB, WordPress, SSL, Redis, and performance tuning — with automatic rollback if anything goes wrong.

**Key properties:**

- Supports Ubuntu 20.04, 22.04, and 24.04 LTS
- Interactive wizard or fully unattended (CI/CD ready)
- Modular Bash — each component is independent and replaceable
- Centralized logging with timestamped log files
- Idempotent — safe to re-run on the same server
- Auto-rollback on failure with backup-before-modify pattern
- Self-healing: restarts failed services automatically
- Generates a full deployment report with all credentials

---

## Supported Systems

| Ubuntu Version | Codename | Status    |
|----------------|----------|-----------|
| 20.04 LTS      | Focal    | Supported |
| 22.04 LTS      | Jammy    | Supported |
| 24.04 LTS      | Noble    | Supported |

> Only Ubuntu is supported. Debian, CentOS, and other distributions are not compatible.

---

## Stack Components

| Component | Version/Source                          |
|-----------|-----------------------------------------|
| Nginx     | Latest stable — nginx.org               |
| Apache2   | Latest stable — Ubuntu repos            |
| PHP       | 8.1 / 8.2 / 8.3 — Ondřej Surý PPA     |
| MariaDB   | 11.4 — official MariaDB repo            |
| WordPress | Latest stable — via WP-CLI              |
| WP-CLI    | Latest — GitHub                         |
| Redis     | Latest — Ubuntu repos                   |
| Certbot   | Let's Encrypt — snap (apt fallback)     |

---

## Project Structure

```
wp-master-installer/
├── install.sh                      # Main entry point — run this
├── config/
│   └── unattended.env.example      # Template for unattended installs
├── templates/
│   ├── nginx-vhost.conf.tpl        # Nginx virtual host template
│   ├── apache-vhost.conf.tpl       # Apache virtual host template
│   ├── wp-config.php.tpl           # WordPress config template
│   └── php-fpm-pool.conf.tpl       # PHP-FPM pool template
├── modules/
│   ├── logging.sh                  # Centralized logging
│   ├── rollback.sh                 # Backup and rollback engine
│   ├── os.sh                       # OS detection and validation
│   ├── webserver.sh                # Web server dispatcher
│   ├── nginx.sh                    # Nginx install and config
│   ├── apache.sh                   # Apache2 install and config
│   ├── php.sh                      # PHP install and config
│   ├── mariadb.sh                  # MariaDB install and config
│   ├── wordpress.sh                # WordPress deploy via WP-CLI
│   ├── ssl.sh                      # Let's Encrypt SSL setup
│   ├── redis.sh                    # Redis install and WP integration
│   ├── optimize.sh                 # Performance tuning
│   ├── verify.sh                   # Health checks and self-healing
│   └── report.sh                   # Deployment report generation
├── logs/                           # Log files (created at runtime)
└── reports/                        # Report files (created at runtime)
```

---

## Getting the Installer onto Your Server

### Option A — Git clone (recommended)

```bash
git clone https://github.com/your-org/wp-master-installer.git
cd wp-master-installer
```

### Option B — Upload via SCP from your local machine

```bash
# From your local machine (Windows users: use WinSCP or the command below via WSL/Git Bash)
scp -r wp-master-installer/ user@your-server-ip:/root/wp-master-installer
```

### Option C — Upload the zip file and extract on server

```bash
# Upload wp-master-installer.zip to the server, then on the server:
apt-get install -y unzip
unzip wp-master-installer.zip
cd wp-master-installer
```

### Option D — Download directly on the server

```bash
wget https://github.com/your-org/wp-master-installer/archive/main.zip -O wp-master-installer.zip
unzip wp-master-installer.zip
cd wp-master-installer-main
```

---

## Prerequisites

Before running the installer, make sure your server meets these requirements:

| Requirement       | Minimum           | Recommended    |
|-------------------|-------------------|----------------|
| OS                | Ubuntu 20.04 LTS  | Ubuntu 24.04 LTS |
| RAM               | 512 MB            | 1 GB+          |
| Free disk space   | 5 GB              | 10 GB+         |
| Access level      | root or sudo      | root           |
| Network           | Internet access required | —        |
| Domain            | A record pointing to server IP | — |

**Check your Ubuntu version:**

```bash
lsb_release -a
```

**Update system packages first (recommended):**

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

**Make the script executable:**

```bash
chmod +x install.sh
```

---

## How to Run

All modes require root or sudo. The script will refuse to run as a regular user.

---

### 1. Interactive Mode (recommended for beginners)

Launch the setup wizard. It prompts you for each value with validation and shows a confirmation summary before starting.

```bash
sudo bash install.sh
```

The wizard asks for:

1. Domain name (e.g. `example.com`)
2. Admin email address
3. Web server — Nginx (default) or Apache
4. PHP version — 8.1, 8.2, or 8.3 (default: 8.3)
5. WordPress site title
6. Database name, user, and password (auto-generated if left blank)
7. WordPress admin username and password (auto-generated if left blank)
8. Whether to install SSL (Let's Encrypt)
9. Whether to install Redis object cache

A summary is displayed before installation begins. Enter `n` at the confirmation to cancel.

---

### 2. Unattended Mode with Config File

Best for repeatable deployments and team environments. Copy the example config, fill in your values, and run.

```bash
# Step 1 — Copy the example config
cp config/unattended.env.example config/my-site.env

# Step 2 — Edit it
nano config/my-site.env

# Step 3 — Run
sudo bash install.sh --unattended --config config/my-site.env
```

The config file uses shell variable syntax:

```bash
# config/my-site.env
DOMAIN="example.com"
ADMIN_EMAIL="admin@example.com"
WEB_SERVER="nginx"
PHP_VERSION="8.3"
DB_NAME="wordpress"
DB_USER="wp_user"
DB_PASS=""                    # leave blank to auto-generate
WP_ADMIN_USER="admin"
WP_ADMIN_PASS=""              # leave blank to auto-generate
WP_SITE_TITLE="My WordPress Site"
INSTALL_SSL=true
INSTALL_REDIS=true
```

> See `config/unattended.env.example` for the full list of options with comments.

---

### 3. Unattended Mode with Flags

Pass all values directly on the command line. Useful for quick one-off deployments.

```bash
sudo bash install.sh \
  --unattended \
  --domain example.com \
  --email admin@example.com \
  --webserver nginx \
  --php-version 8.3 \
  --wp-title "My Site"
```

Skip optional components:

```bash
# Install without SSL and without Redis
sudo bash install.sh \
  --unattended \
  --domain example.com \
  --email admin@example.com \
  --no-ssl \
  --no-redis
```

Use Apache instead of Nginx:

```bash
sudo bash install.sh \
  --unattended \
  --domain example.com \
  --email admin@example.com \
  --webserver apache \
  --php-version 8.2
```

---

### 4. CI/CD Pipeline Mode

For automated pipelines, use a config file stored securely (environment secret, vault, etc.) and disable rollback if the pipeline handles cleanup itself.

```bash
sudo bash install.sh \
  --unattended \
  --config /etc/wp-deploy/production.env \
  --no-rollback
```

Enable debug logging for troubleshooting:

```bash
sudo bash install.sh --unattended --config config/my-site.env --debug
```

---

## All Command-Line Options

```
Option                  Description
--------------------    -------------------------------------------------------
--unattended, -u        Run without interactive prompts
--config, -c FILE       Load settings from a .env config file
--domain DOMAIN         Domain name (e.g. example.com)
--email EMAIL           Admin email address
--webserver TYPE        nginx (default) or apache
--php-version VER       8.1 | 8.2 | 8.3  (default: 8.3)
--db-name NAME          Database name (default: wordpress)
--db-user USER          Database username (default: wp_user)
--db-pass PASS          Database password (auto-generated if omitted)
--wp-admin-user USER    WordPress admin username (default: admin)
--wp-admin-pass PASS    WordPress admin password (auto-generated if omitted)
--wp-title TITLE        WordPress site title
--no-ssl                Skip SSL certificate setup
--no-redis              Skip Redis installation
--no-rollback           Disable automatic rollback on error
--debug                 Enable verbose debug logging
--help, -h              Show help
```

---

## Configuration File Reference

| Variable           | Default             | Description                                |
|--------------------|---------------------|--------------------------------------------|
| `DOMAIN`           | _(required)_        | Target domain, e.g. `example.com`          |
| `ADMIN_EMAIL`      | _(required)_        | Admin email for SSL and WordPress          |
| `WEB_SERVER`       | `nginx`             | `nginx` or `apache`                        |
| `PHP_VERSION`      | `8.3`               | `8.1`, `8.2`, or `8.3`                    |
| `DB_NAME`          | `wordpress`         | MariaDB database name                      |
| `DB_USER`          | `wp_user`           | MariaDB username                           |
| `DB_PASS`          | _(auto-generated)_  | MariaDB password                           |
| `DB_ROOT_PASS`     | _(auto-generated)_  | MariaDB root password                      |
| `WP_ADMIN_USER`    | `admin`             | WordPress admin username                   |
| `WP_ADMIN_PASS`    | _(auto-generated)_  | WordPress admin password                   |
| `WP_ADMIN_EMAIL`   | `= ADMIN_EMAIL`     | WordPress admin email                      |
| `WP_SITE_TITLE`    | `My WordPress Site` | WordPress site title                       |
| `INSTALL_SSL`      | `true`              | Install Let's Encrypt SSL                  |
| `INSTALL_REDIS`    | `true`              | Install Redis object cache                 |
| `WEB_ROOT`         | `/var/www`          | Web root base directory                    |
| `LOG_VERBOSITY`    | `1` (INFO)          | `0`=DEBUG, `1`=INFO, `2`=WARN, `3`=ERROR  |
| `ROLLBACK_ON_ERROR`| `true`              | Auto-rollback on failure                   |

---

## What Gets Installed

The installer runs in 12 sequential phases:

| Phase | What happens                                                        |
|-------|---------------------------------------------------------------------|
| 1     | OS detection and system package update                              |
| 2     | Web server (Nginx or Apache) installed and enabled                  |
| 3     | PHP (selected version) + all WordPress extensions + FPM pool config |
| 4     | MariaDB installed, secured, database and user created               |
| 5     | WP-CLI installed, WordPress downloaded and configured               |
| 6     | Virtual host configured, .htaccess created, permissions set         |
| 7     | WordPress core installed via WP-CLI                                 |
| 8     | Redis installed and integrated with WordPress _(optional)_          |
| 9     | Let's Encrypt SSL certificate obtained and auto-renewal set up _(optional)_ |
| 10    | MariaDB, PHP-FPM, and kernel performance tuning applied             |
| 11    | Full health check with automatic service self-healing               |
| 12    | Deployment report generated at `/root/deployment-report-*.txt`      |

**Paths created:**

| Path                                        | Contents                              |
|---------------------------------------------|---------------------------------------|
| `/var/www/<domain>/`                        | WordPress files                       |
| `/var/log/wp-master-installer/`             | Installer log files                   |
| `/var/backups/wp-master-installer/`         | Rollback backups                      |
| `/root/deployment-report-<timestamp>.txt`   | Credentials and configuration report  |

---

## After Installation

### Find your credentials

```bash
cat /root/deployment-report-*.txt
```

The report contains your domain, WordPress admin URL, database name/user/password, WordPress admin username/password, and SSL status. It is readable only by root (`chmod 600`).

> Store credentials in a password manager, then delete the report file.

### Access your site

| URL                              | Purpose                  |
|----------------------------------|--------------------------|
| `https://example.com`            | WordPress front-end      |
| `https://example.com/wp-admin`   | WordPress admin dashboard |

### Log in to WordPress

Use the admin username and password from the deployment report (or the ones you set during installation).

### View the installation log

```bash
# View the full log
cat /var/log/wp-master-installer/install-*.log

# Follow a live install
tail -f /var/log/wp-master-installer/install-*.log
```

---

## Verification & Health Checks

Run these after installation to confirm everything is working:

```bash
# Check all services
systemctl status nginx php8.3-fpm mariadb redis-server

# Test HTTP response
curl -I http://example.com

# Test HTTPS response
curl -I https://example.com

# PHP version
php -v

# MariaDB connection
mysql -u wp_user -p wordpress -e "SELECT 1;"

# Redis
redis-cli ping

# WordPress via WP-CLI
wp --path=/var/www/example.com core is-installed
wp --path=/var/www/example.com option get siteurl

# SSL renewal dry run
certbot renew --dry-run
```

---

## Rollback System

Before every configuration change, the original file is backed up to `/var/backups/wp-master-installer/`. If the installer fails at any point, all changes are reversed in the order they were made.

**Rollback is triggered by:**
- Any unhandled Bash error (via `set -Eeuo pipefail` + `trap ERR`)
- Ctrl+C / user interrupt
- Explicit call during a failing phase

**What gets rolled back:**
- Web server virtual host configs
- PHP-FPM pool configuration
- MariaDB configuration
- `wp-config.php`
- Redis configuration
- Kernel sysctl settings

Disable rollback with `--no-rollback` if you want to inspect a partial install before cleanup.

---

## Troubleshooting

### PHP-FPM won't start

```bash
journalctl -u php8.3-fpm --no-pager
php8.3-fpm --test
```

### Nginx config error

```bash
nginx -t
journalctl -u nginx --no-pager
```

### Apache config error

```bash
apache2ctl configtest
journalctl -u apache2 --no-pager
```

### MariaDB — access denied

```bash
# Check root login
mysql --defaults-file=/root/.my.cnf -e "SHOW DATABASES;"

# Recreate WordPress user
mysql -u root -p
> GRANT ALL ON wordpress.* TO 'wp_user'@'localhost' IDENTIFIED BY 'newpassword';
> FLUSH PRIVILEGES;
```

### SSL certificate failed

```bash
# Check DNS is pointing to this server
dig A example.com

# Request certificate manually
certbot certonly --standalone -d example.com

# Check certbot logs
cat /var/log/letsencrypt/letsencrypt.log
```

### WordPress shows "Error establishing a database connection"

```bash
# Check wp-config.php settings
grep DB_ /var/www/example.com/wp-config.php

# Test the connection manually
mysql -u wp_user -p wordpress -e "SELECT 1;"
```

### View full installer log

```bash
ls /var/log/wp-master-installer/
cat /var/log/wp-master-installer/install-<timestamp>.log
```

---

## Module Reference

| Module          | Responsibility                                            |
|-----------------|-----------------------------------------------------------|
| `logging.sh`    | Coloured terminal output + timestamped file logging       |
| `rollback.sh`   | File backup and LIFO rollback stack                       |
| `os.sh`         | Ubuntu version check, RAM/CPU/disk detection              |
| `webserver.sh`  | Dispatcher that delegates to nginx.sh or apache.sh        |
| `nginx.sh`      | Nginx install, vhost config, SSL enable                   |
| `apache.sh`     | Apache2 install, vhost config, SSL enable                 |
| `php.sh`        | PHP + extensions install, php.ini + FPM pool config       |
| `mariadb.sh`    | MariaDB install, secure, DB/user creation, optimization   |
| `wordpress.sh`  | WP-CLI install, WordPress download, wp-config, core install |
| `ssl.sh`        | Certbot install, certificate request, auto-renewal        |
| `redis.sh`      | Redis install, configuration, WordPress plugin integration |
| `optimize.sh`   | RAM-based tuning for PHP, MariaDB, and kernel             |
| `verify.sh`     | Health checks for all services with auto-restart          |
| `report.sh`     | Deployment report with credentials and status             |

### Optimization tiers by server RAM

| RAM    | PHP Memory | FPM Workers | InnoDB Buffer | Max Connections |
|--------|-----------|-------------|---------------|-----------------|
| < 1 GB | 256 MB    | 5           | 256 MB        | 100             |
| 1–2 GB | 256 MB    | 10          | ~512 MB       | 150             |
| 2–4 GB | 512 MB    | 20          | ~1.2 GB       | 200             |
| 4–8 GB | 1024 MB   | 40          | ~2.6 GB       | 300             |
| 8+ GB  | 2048 MB   | 80          | ~5.7 GB       | 500             |

---

## Security Model

| Measure                     | Implementation                                           |
|-----------------------------|----------------------------------------------------------|
| File permissions            | Files: 644, Dirs: 755, `wp-config.php`: 440              |
| Directory listing           | Disabled in web server config                            |
| `wp-config.php` protection  | Blocked at web server level                              |
| XML-RPC                     | Blocked at web server level                              |
| Security headers            | X-Frame-Options, X-XSS-Protection, HSTS (with SSL), CSP |
| MariaDB network binding     | `127.0.0.1` only — no external access                   |
| Redis network binding       | `127.0.0.1` only                                         |
| Dangerous Redis commands    | Renamed/disabled                                         |
| TLS                         | TLS 1.2 / 1.3 only, modern cipher suite                  |
| PHP version exposure        | `expose_php = Off`                                       |
| PHP path info               | `cgi.fix_pathinfo = 0`                                   |
| WordPress file editing      | `DISALLOW_FILE_EDIT = true` in wp-config.php             |

---

## License

MIT License — free to use, modify, and distribute.

---

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss.

All Bash code must follow `set -Eeuo pipefail` and pass `shellcheck`:

```bash
shellcheck install.sh modules/*.sh
```
