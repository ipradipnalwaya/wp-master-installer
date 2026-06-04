#!/usr/bin/env bash
# =============================================================================
# modules/os.sh — OS Detection & System Profile Module
# wp-master-installer
# =============================================================================

[[ -n "${_OS_SH_LOADED:-}" ]] && return 0
_OS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Supported versions
# ---------------------------------------------------------------------------
declare -A SUPPORTED_UBUNTU=(
    ["20.04"]="focal"
    ["22.04"]="jammy"
    ["24.04"]="noble"
)

# Exported globals populated by os_detect()
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
SYS_RAM_MB=0
SYS_RAM_GB=0
SYS_CPU_CORES=0
SYS_DISK_FREE_GB=0
SYS_SERVER_IP=""
SYS_HOSTNAME=""

# ---------------------------------------------------------------------------
# Internal: read /etc/os-release
# ---------------------------------------------------------------------------
_os_read_release() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-unknown}"
    else
        log_fatal "/etc/os-release not found. Cannot determine OS."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Validate Ubuntu version
# ---------------------------------------------------------------------------
_os_validate() {
    if [[ "${DISTRO_ID}" != "ubuntu" ]]; then
        log_fatal "Unsupported OS: '${DISTRO_ID}'. This installer requires Ubuntu."
        return 1
    fi

    if [[ -z "${SUPPORTED_UBUNTU[${DISTRO_VERSION}]+_}" ]]; then
        log_fatal "Unsupported Ubuntu version: ${DISTRO_VERSION}."
        log_fatal "Supported versions: ${!SUPPORTED_UBUNTU[*]}"
        return 1
    fi

    log_success "OS validated: Ubuntu ${DISTRO_VERSION} (${DISTRO_CODENAME})"
}

# ---------------------------------------------------------------------------
# Collect system resources
# ---------------------------------------------------------------------------
_os_collect_resources() {
    # RAM
    SYS_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo 0)
    SYS_RAM_GB=$(awk '/MemTotal/ { printf "%.1f", $2/1024/1024 }' /proc/meminfo 2>/dev/null || echo 0)

    # CPU cores
    SYS_CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

    # Disk free on /
    SYS_DISK_FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $4}' || echo 0)

    # Primary IP
    SYS_SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    # Hostname
    SYS_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
}

# ---------------------------------------------------------------------------
# Check minimum requirements
# ---------------------------------------------------------------------------
_os_check_requirements() {
    local errors=0

    if [[ "${SYS_RAM_MB}" -lt 512 ]]; then
        log_warn "Low RAM detected: ${SYS_RAM_MB} MB. Minimum recommended: 1 GB."
    fi

    if [[ "${SYS_DISK_FREE_GB}" -lt 5 ]]; then
        log_error "Insufficient disk space: ${SYS_DISK_FREE_GB} GB free. Minimum required: 5 GB."
        errors=$(( errors + 1 ))
    fi

    # Must run as root
    if [[ "${EUID}" -ne 0 ]]; then
        log_fatal "This installer must be run as root (or with sudo)."
        return 1
    fi

    if [[ "${errors}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Public: run full OS detection
# ---------------------------------------------------------------------------
os_detect() {
    log_section "OS Detection & System Profile"

    _os_read_release   || return 1
    _os_validate       || return 1
    _os_collect_resources
    _os_check_requirements || return 1

    log_info "Hostname      : ${SYS_HOSTNAME}"
    log_info "Server IP     : ${SYS_SERVER_IP}"
    log_info "RAM           : ${SYS_RAM_GB} GB (${SYS_RAM_MB} MB)"
    log_info "CPU Cores     : ${SYS_CPU_CORES}"
    log_info "Free Disk     : ${SYS_DISK_FREE_GB} GB"

    return 0
}

# ---------------------------------------------------------------------------
# Public: print system profile (for reports)
# ---------------------------------------------------------------------------
os_profile() {
    cat <<EOF
OS              : Ubuntu ${DISTRO_VERSION} (${DISTRO_CODENAME})
Hostname        : ${SYS_HOSTNAME}
Server IP       : ${SYS_SERVER_IP}
RAM             : ${SYS_RAM_GB} GB
CPU Cores       : ${SYS_CPU_CORES}
Free Disk Space : ${SYS_DISK_FREE_GB} GB
EOF
}

# ---------------------------------------------------------------------------
# Public: update system packages
# ---------------------------------------------------------------------------
os_update() {
    log_section "System Package Update"
    log_step "Updating apt package index..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        log_error "apt-get update failed."
        return 1
    }

    log_step "Upgrading installed packages..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || {
        log_warn "apt-get upgrade returned non-zero. Continuing..."
    }

    log_step "Installing prerequisites..."
    local packages=(
        curl wget gnupg2 ca-certificates lsb-release
        software-properties-common apt-transport-https
        unzip tar git openssl cron
    )
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" || {
        log_error "Failed to install prerequisite packages."
        return 1
    }

    log_success "System packages updated."
    return 0
}
