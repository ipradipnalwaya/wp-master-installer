#!/usr/bin/env bash
# =============================================================================
# modules/checkpoint.sh — Resume / Checkpoint Module
# wp-master-installer
#
# Usage:
#   checkpoint_mark  <step_name>          # mark a step as done
#   checkpoint_done  <step_name>          # returns 0 if already done
#   checkpoint_reset                      # wipe all checkpoints (fresh run)
#   checkpoint_status                     # print progress summary
#
# State file: /var/log/wp-master-installer/checkpoint-<domain>.state
# =============================================================================

[[ -n "${_CHECKPOINT_SH_LOADED:-}" ]] && return 0
_CHECKPOINT_SH_LOADED=1

# ---------------------------------------------------------------------------
# Resolve state file path (depends on DOMAIN being exported first)
# ---------------------------------------------------------------------------
_checkpoint_state_file() {
    local domain_slug="${DOMAIN:-unknown}"
    # Sanitise: keep only alphanumeric, dots, hyphens
    domain_slug="${domain_slug//[^a-zA-Z0-9.\-]/_}"
    echo "${LOG_DIR}/checkpoint-${domain_slug}.state"
}

# ---------------------------------------------------------------------------
# Mark a step as completed
# ---------------------------------------------------------------------------
checkpoint_mark() {
    local step="$1"
    local state_file
    state_file="$(_checkpoint_state_file)"
    mkdir -p "$(dirname "${state_file}")" 2>/dev/null || true

    # Avoid duplicate entries
    if ! grep -qxF "${step}" "${state_file}" 2>/dev/null; then
        echo "${step}" >> "${state_file}"
    fi
    log_debug "Checkpoint marked: ${step}"
}

# ---------------------------------------------------------------------------
# Check if a step is already done   (returns 0 = done, 1 = not done)
# ---------------------------------------------------------------------------
checkpoint_done() {
    local step="$1"
    local state_file
    state_file="$(_checkpoint_state_file)"

    if [[ -f "${state_file}" ]] && grep -qxF "${step}" "${state_file}" 2>/dev/null; then
        return 0   # already done
    fi
    return 1       # not done yet
}

# ---------------------------------------------------------------------------
# Run a step only if not already completed
#
#   checkpoint_run  <step_name>  <function_name>  [fatal|warn]
#
#   fatal (default) : exit 1 on failure
#   warn            : log warning and continue
# ---------------------------------------------------------------------------
checkpoint_run() {
    local step="$1"
    local func="$2"
    local on_fail="${3:-fatal}"

    if checkpoint_done "${step}"; then
        log_info "  [SKIP] ${step} — already completed."
        return 0
    fi

    # Run the function
    if "${func}"; then
        checkpoint_mark "${step}"
        return 0
    else
        local rc=$?
        if [[ "${on_fail}" == "warn" ]]; then
            log_warn "${step} failed (non-fatal, rc=${rc}). Continuing..."
            return 0
        else
            log_error "${step} failed (rc=${rc})."
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Reset all checkpoints (forces a clean run)
# ---------------------------------------------------------------------------
checkpoint_reset() {
    local state_file
    state_file="$(_checkpoint_state_file)"
    if [[ -f "${state_file}" ]]; then
        rm -f "${state_file}"
        log_info "Checkpoints cleared. Next run will start from scratch."
    else
        log_info "No checkpoint file found. Nothing to reset."
    fi
}

# ---------------------------------------------------------------------------
# Print current progress
# ---------------------------------------------------------------------------
checkpoint_status() {
    local state_file
    state_file="$(_checkpoint_state_file)"

    log_section "Installation Progress"
    if [[ ! -f "${state_file}" ]]; then
        log_info "No checkpoint file found — installation has not started yet."
        return 0
    fi

    local count=0
    while IFS= read -r step; do
        printf "  ${C_SUCCESS}✔${C_RESET}  %s\n" "${step}"
        (( count++ )) || true
    done < "${state_file}"
    echo ""
    log_info "${count} step(s) completed."
}
