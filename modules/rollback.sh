#!/usr/bin/env bash
# =============================================================================
# modules/rollback.sh — Rollback & Backup Module
# wp-master-installer
# =============================================================================

[[ -n "${_ROLLBACK_SH_LOADED:-}" ]] && return 0
_ROLLBACK_SH_LOADED=1

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ROLLBACK_DIR="${ROLLBACK_DIR:-/var/backups/wp-master-installer}"
ROLLBACK_MANIFEST="${ROLLBACK_DIR}/manifest.txt"

# Stack of rollback actions (LIFO)
declare -a _ROLLBACK_STACK=()

# ---------------------------------------------------------------------------
# Initialise backup directory
# ---------------------------------------------------------------------------
rollback_init() {
    mkdir -p "${ROLLBACK_DIR}"
    chmod 700 "${ROLLBACK_DIR}"
    log_debug "Rollback directory: ${ROLLBACK_DIR}"
    : >> "${ROLLBACK_MANIFEST}"
}

# ---------------------------------------------------------------------------
# Register a rollback action (shell command string)
# Called BEFORE each risky operation.
# Actions are executed in reverse order (LIFO stack).
# ---------------------------------------------------------------------------
rollback_register() {
    local action="$1"
    _ROLLBACK_STACK+=("${action}")
    log_debug "Rollback registered: ${action}"
}

# ---------------------------------------------------------------------------
# Backup a file/directory before modifying it
# Usage: rollback_backup /path/to/file
# Returns the backup path via stdout
# ---------------------------------------------------------------------------
rollback_backup() {
    local source_path="$1"
    [[ -e "${source_path}" ]] || return 0  # nothing to back up

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local safe_name
    safe_name="${source_path//\//_}"
    local backup_path="${ROLLBACK_DIR}/${safe_name}.${ts}.bak"

    if [[ -d "${source_path}" ]]; then
        cp -a "${source_path}" "${backup_path}" 2>/dev/null
    else
        cp -p "${source_path}" "${backup_path}" 2>/dev/null
    fi

    echo "${source_path} -> ${backup_path}" >> "${ROLLBACK_MANIFEST}"
    log_debug "Backed up: ${source_path} -> ${backup_path}"

    # Register auto-restore
    rollback_register "cp -a '${backup_path}' '${source_path}' && log_info 'Restored: ${source_path}'"
    echo "${backup_path}"
}

# ---------------------------------------------------------------------------
# Execute all registered rollback actions in reverse order
# ---------------------------------------------------------------------------
rollback_execute() {
    local reason="${1:-unspecified failure}"
    log_error "=== ROLLBACK TRIGGERED: ${reason} ==="

    local stack_size="${#_ROLLBACK_STACK[@]}"
    if [[ "${stack_size}" -eq 0 ]]; then
        log_warn "No rollback actions registered."
        return 0
    fi

    local i
    for (( i = stack_size - 1; i >= 0; i-- )); do
        local action="${_ROLLBACK_STACK[${i}]}"
        log_step "Rollback[${i}]: ${action}"
        # shellcheck disable=SC2091
        if eval "${action}"; then
            log_success "Rollback action succeeded."
        else
            log_error "Rollback action FAILED: ${action}"
        fi
    done

    # Clear the stack after execution
    _ROLLBACK_STACK=()
    log_info "Rollback complete."
}

# ---------------------------------------------------------------------------
# Clear the rollback stack (call after successful completion of a phase)
# ---------------------------------------------------------------------------
rollback_clear() {
    _ROLLBACK_STACK=()
    log_debug "Rollback stack cleared."
}

# ---------------------------------------------------------------------------
# Snapshot helper — save named snapshots for phase-level rollback
# ---------------------------------------------------------------------------
rollback_snapshot_create() {
    local name="$1"
    shift
    local files=("$@")

    local snap_dir="${ROLLBACK_DIR}/snapshot-${name}"
    mkdir -p "${snap_dir}"

    for f in "${files[@]}"; do
        [[ -e "${f}" ]] || continue
        local safe
        safe="${f//\//_}"
        if [[ -d "${f}" ]]; then
            cp -a "${f}" "${snap_dir}/${safe}"
        else
            cp -p "${f}" "${snap_dir}/${safe}"
        fi
        log_debug "Snapshot '${name}': saved ${f}"
    done
    echo "${snap_dir}"
}

rollback_snapshot_restore() {
    local name="$1"
    local snap_dir="${ROLLBACK_DIR}/snapshot-${name}"

    [[ -d "${snap_dir}" ]] || {
        log_warn "No snapshot found for '${name}'"
        return 1
    }

    # Read manifest if present
    while IFS='|' read -r original backup; do
        [[ -z "${original}" ]] && continue
        cp -a "${backup}" "${original}" && log_info "Restored ${original}"
    done < <(find "${snap_dir}" -maxdepth 1 -name '*' -printf '%f|%p\n' 2>/dev/null || true)

    log_success "Snapshot '${name}' restored."
}
