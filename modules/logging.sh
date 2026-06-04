#!/usr/bin/env bash
# =============================================================================
# modules/logging.sh — Centralized Logging Module
# wp-master-installer
# =============================================================================

# Guard against double-sourcing
[[ -n "${_LOGGING_SH_LOADED:-}" ]] && return 0
_LOGGING_SH_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly LOG_DIR="${LOG_DIR:-/var/log/wp-master-installer}"
readonly LOG_FILE="${LOG_FILE:-${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log}"
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# Default verbosity (can be overridden before sourcing)
LOG_VERBOSITY="${LOG_VERBOSITY:-${LOG_LEVEL_INFO}}"

# Colour codes (disabled when not a TTY)
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_DEBUG="\033[0;36m"   # cyan
    C_INFO="\033[0;32m"    # green
    C_WARN="\033[0;33m"    # yellow
    C_ERROR="\033[0;31m"   # red
    C_FATAL="\033[1;31m"   # bold red
    C_SECTION="\033[1;34m" # bold blue
    C_SUCCESS="\033[1;32m" # bold green
    C_STEP="\033[1;35m"    # bold magenta
else
    C_RESET="" C_DEBUG="" C_INFO="" C_WARN=""
    C_ERROR="" C_FATAL="" C_SECTION="" C_SUCCESS="" C_STEP=""
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_log_init() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || {
        echo "[WARN] Cannot create log directory ${LOG_DIR}. Using /tmp." >&2
        readonly LOG_DIR="/tmp"
        readonly LOG_FILE="/tmp/wp-master-install-$$.log"
    }
    # Create / touch log file
    : >> "${LOG_FILE}" 2>/dev/null || true
    chmod 640 "${LOG_FILE}" 2>/dev/null || true
}

_log_write() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local caller_info=""
    if [[ "${LOG_VERBOSITY}" -le "${LOG_LEVEL_DEBUG}" ]]; then
        # include caller for debug builds
        caller_info=" [${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}]"
    fi
    printf '%s [%-5s]%s %s\n' \
        "${timestamp}" "${level}" "${caller_info}" "${message}" \
        >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Public logging functions
# ---------------------------------------------------------------------------
log_debug() {
    [[ "${LOG_VERBOSITY}" -gt "${LOG_LEVEL_DEBUG}" ]] && return 0
    _log_write "DEBUG" "$*"
    printf "${C_DEBUG}[DEBUG]${C_RESET} %s\n" "$*" >&2
}

log_info() {
    [[ "${LOG_VERBOSITY}" -gt "${LOG_LEVEL_INFO}" ]] && return 0
    _log_write "INFO " "$*"
    printf "${C_INFO}[INFO ]${C_RESET}  %s\n" "$*"
}

log_warn() {
    [[ "${LOG_VERBOSITY}" -gt "${LOG_LEVEL_WARN}" ]] && return 0
    _log_write "WARN " "$*"
    printf "${C_WARN}[WARN ]${C_RESET}  %s\n" "$*" >&2
}

log_error() {
    _log_write "ERROR" "$*"
    printf "${C_ERROR}[ERROR]${C_RESET}  %s\n" "$*" >&2
}

log_fatal() {
    _log_write "FATAL" "$*"
    printf "${C_FATAL}[FATAL]${C_RESET}  %s\n" "$*" >&2
}

# ---------------------------------------------------------------------------
# UX helpers
# ---------------------------------------------------------------------------
log_section() {
    local title="$1"
    local line
    line="$(printf '=%.0s' {1..60})"
    _log_write "====" "${line}"
    _log_write "====" "  ${title}"
    _log_write "====" "${line}"
    printf "\n${C_SECTION}%s\n  %s\n%s${C_RESET}\n\n" \
        "${line}" "${title}" "${line}"
}

log_step() {
    _log_write "STEP " ">> $*"
    printf "  ${C_STEP}▸${C_RESET} %s\n" "$*"
}

log_success() {
    _log_write "OK   " "$*"
    printf "  ${C_SUCCESS}✔${C_RESET}  %s\n" "$*"
}

log_failure() {
    _log_write "FAIL " "$*"
    printf "  ${C_ERROR}✘${C_RESET}  %s\n" "$*" >&2
}

# ---------------------------------------------------------------------------
# Initialise on source
# ---------------------------------------------------------------------------
_log_init
