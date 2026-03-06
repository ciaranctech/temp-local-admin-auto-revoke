#!/bin/bash

###################################################################################################
# Script Name: temp-local-admin-auto-revoke.sh
# Description: Temporarily elevates a standard local user to admin, then automatically revokes
#              admin rights after a configurable duration.
#              Designed for deployment via Jamf Pro (Self Service or policy).
#
# Author: Ciaran Coghlan
# Created: 2026-03-06
# Version: 1.1
#
# Usage: Run via Jamf Pro policy.
#
# Jamf Pro Notes:
#   - Scripts run as root.
#   - $3 contains the logged-in username by default.
#   - $4 can be used to override elevation duration in minutes.
#   - $5 can store optional ticket/justification text.
#
# Optional Testing Override:
#   - Set TEST_TARGET_USER environment variable to force a specific target user.
#
# Exit Codes:
#   0 - Success
#   1 - Failure (general error)
#   2 - Not running as root
###################################################################################################

# =================================================================================================
# CONFIGURATION
# =================================================================================================

SCRIPT_NAME="temp-local-admin-auto-revoke"
LOG_DIR="/Library/Application Support/Script Logs/${SCRIPT_NAME}"
LOG_FILE="${LOG_DIR}/$(date '+%Y-%m-%d_%H-%M-%S').log"
STATE_DIR="/Library/Application Support/${SCRIPT_NAME}/state"

DEFAULT_ELEVATION_MINUTES=10
MAX_ELEVATION_MINUTES=120
ELEVATION_MINUTES="${4:-${DEFAULT_ELEVATION_MINUTES}}"

# Prevent rapid re-grants after revocation
COOLDOWN_MINUTES=5

# Optional justification/ticket
JUSTIFICATION="${5:-unspecified}"

# Accounts that should never be modified by this script
PROTECTED_USERS=(
    "root"
    "daemon"
    "nobody"
)

# =================================================================================================
# LOGGING FUNCTION
# =================================================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ ! -d "${LOG_DIR}" ]]; then
        mkdir -p "${LOG_DIR}" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            echo "[${timestamp}] [ERROR] Failed to create log directory: ${LOG_DIR}" >&2
            return 1
        fi
    fi

    local line="[${timestamp}] [${level}] ${message}"
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
}

ulog() {
    # Unified log marker for easier incident correlation
    local message="$1"
    /usr/bin/logger -t "${SCRIPT_NAME}" "${message}" 2>/dev/null || true
}

# =================================================================================================
# HELPER FUNCTIONS
# =================================================================================================

ensure_state_dir() {
    if [[ ! -d "${STATE_DIR}" ]]; then
        mkdir -p "${STATE_DIR}"
        chown root:wheel "${STATE_DIR}" 2>/dev/null || true
        chmod 700 "${STATE_DIR}"
    fi
}

is_protected_user() {
    local user_to_check="$1"
    for protected_user in "${PROTECTED_USERS[@]}"; do
        if [[ "${user_to_check}" == "${protected_user}" ]]; then
            return 0
        fi
    done
    return 1
}

is_admin_user() {
    local user_to_check="$1"
    dseditgroup -o checkmember -m "${user_to_check}" admin 2>/dev/null | grep -q "yes"
    return $?
}

remove_existing_job() {
    local label="$1"
    local plist_path="/Library/LaunchDaemons/${label}.plist"

    if [[ -f "${plist_path}" ]]; then
        log "INFO" "Existing auto-revoke job found. Removing old job: ${label}"
        launchctl bootout "system/${label}" >/dev/null 2>&1 || true
        rm -f "${plist_path}"
    fi
}

check_cooldown() {
    local target_user="$1"
    local cooldown_state_file="${STATE_DIR}/${target_user}.cooldown"
    local now_epoch
    now_epoch=$(date +%s)

    if [[ -f "${cooldown_state_file}" ]]; then
        local cooldown_until
        cooldown_until=$(cat "${cooldown_state_file}" 2>/dev/null)
        if [[ "${cooldown_until}" =~ ^[0-9]+$ ]] && [[ "${now_epoch}" -lt "${cooldown_until}" ]]; then
            local seconds_remaining=$((cooldown_until - now_epoch))
            log "ERROR" "Cooldown active for ${target_user}. Try again in ${seconds_remaining} seconds."
            return 1
        fi
    fi

    return 0
}

run_reconcile() {
    log "INFO" "Running reconcile mode (stale elevation cleanup check)"

    if [[ ! -d "${STATE_DIR}" ]]; then
        log "INFO" "No state directory found. Nothing to reconcile."
        return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)

    find "${STATE_DIR}" -name "*.state" -type f 2>/dev/null | while read -r state_file; do
        local user
        user=$(basename "${state_file}" .state)

        local expiry_epoch
        expiry_epoch=$(awk -F= '/^expiry_epoch=/{print $2}' "${state_file}" 2>/dev/null)

        [[ -z "${expiry_epoch}" ]] && continue
        [[ ! "${expiry_epoch}" =~ ^[0-9]+$ ]] && continue

        if [[ "${now_epoch}" -ge "${expiry_epoch}" ]]; then
            if is_admin_user "${user}"; then
                log "WARNING" "Found stale elevated user during reconcile: ${user}. Removing admin rights now."
                if dseditgroup -o edit -d "${user}" -t user admin; then
                    log "INFO" "Reconcile removed stale admin rights for ${user}."
                    ulog "action=reconcile_revoke user=${user} result=success"
                else
                    log "ERROR" "Reconcile failed to remove stale admin rights for ${user}."
                    ulog "action=reconcile_revoke user=${user} result=failure"
                fi
            fi
            rm -f "${state_file}"
        fi
    done

    return 0
}

create_revoke_job() {
    local target_user="$1"
    local wait_seconds="$2"
    local request_id="$3"

    local label="com.ciaran.tempadmin.revoke.${target_user}"
    local revoke_script="/private/var/tmp/revoke-admin-${target_user}.sh"
    local plist_path="/Library/LaunchDaemons/${label}.plist"
    local state_file="${STATE_DIR}/${target_user}.state"
    local cooldown_file="${STATE_DIR}/${target_user}.cooldown"

    remove_existing_job "${label}"

    cat > "${revoke_script}" <<EOF
#!/bin/bash
TARGET_USER="${target_user}"
WAIT_SECONDS="${wait_seconds}"
LOG_DIR="${LOG_DIR}"
LOG_FILE="\${LOG_DIR}/revoke-\$(date '+%Y-%m-%d_%H-%M-%S').log"
LABEL="${label}"
PLIST_PATH="${plist_path}"
SCRIPT_PATH="${revoke_script}"
STATE_FILE="${state_file}"
COOLDOWN_FILE="${cooldown_file}"
COOLDOWN_MINUTES="${COOLDOWN_MINUTES}"
REQUEST_ID="${request_id}"

log() {
  local level="\$1"
  local msg="\$2"
  local ts
  ts=\$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "\$LOG_DIR"
  echo "[\$ts] [\$level] \$msg" | tee -a "\$LOG_FILE" >/dev/null
}

ulog() {
  /usr/bin/logger -t "${SCRIPT_NAME}" "\$1" 2>/dev/null || true
}

sleep "\$WAIT_SECONDS"

if dseditgroup -o checkmember -m "\$TARGET_USER" admin 2>/dev/null | grep -q "yes"; then
  if dseditgroup -o edit -d "\$TARGET_USER" -t user admin; then
    log "INFO" "Auto-revoke successful. Removed admin rights from \$TARGET_USER."
    ulog "action=revoke user=\$TARGET_USER request_id=\$REQUEST_ID result=success"
  else
    log "ERROR" "Auto-revoke failed for \$TARGET_USER."
    ulog "action=revoke user=\$TARGET_USER request_id=\$REQUEST_ID result=failure"
  fi
else
  log "INFO" "\$TARGET_USER was already standard at revoke time."
  ulog "action=revoke user=\$TARGET_USER request_id=\$REQUEST_ID result=already_standard"
fi

# Write cooldown window
NOW_EPOCH=\$(date +%s)
COOLDOWN_UNTIL=\$((NOW_EPOCH + (COOLDOWN_MINUTES * 60)))
echo "\$COOLDOWN_UNTIL" > "\$COOLDOWN_FILE"
chown root:wheel "\$COOLDOWN_FILE" 2>/dev/null || true
chmod 600 "\$COOLDOWN_FILE"

rm -f "\$STATE_FILE" "\$PLIST_PATH" "\$SCRIPT_PATH"
launchctl bootout "system/\$LABEL" >/dev/null 2>&1 || true
EOF

    chmod 700 "${revoke_script}"

    cat > "${plist_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${revoke_script}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd-${target_user}.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd-${target_user}.err.log</string>
</dict>
</plist>
EOF

    chmod 644 "${plist_path}"
    chown root:wheel "${plist_path}"

    launchctl bootstrap system "${plist_path}"
    if [[ $? -eq 0 ]]; then
        log "INFO" "Auto-revoke job loaded successfully: ${label}"
    else
        log "ERROR" "Failed to load auto-revoke job: ${label}"
        return 1
    fi

    return 0
}

# =================================================================================================
# MAIN SCRIPT EXECUTION
# =================================================================================================

main() {
    log "INFO" "========================================"
    log "INFO" "Starting: ${SCRIPT_NAME}"
    log "INFO" "========================================"

    if [[ ${EUID} -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 2
    fi

    ensure_state_dir

    if [[ "${RECONCILE_ONLY:-0}" == "1" ]]; then
        run_reconcile
        exit $?
    fi

    local request_id
    request_id="req-$(date +%s)-$RANDOM"

    local target_user
    if [[ -n "${TEST_TARGET_USER:-}" ]]; then
        target_user="${TEST_TARGET_USER}"
        log "INFO" "Using TEST_TARGET_USER override: ${target_user}"
    else
        target_user="${3:-$(stat -f%Su /dev/console)}"
        log "INFO" "Using Jamf/console user: ${target_user}"
    fi

    if ! [[ "${ELEVATION_MINUTES}" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid duration: ${ELEVATION_MINUTES}. Must be integer minutes."
        exit 1
    fi

    if [[ "${ELEVATION_MINUTES}" -lt 1 || "${ELEVATION_MINUTES}" -gt "${MAX_ELEVATION_MINUTES}" ]]; then
        log "ERROR" "Duration must be between 1 and ${MAX_ELEVATION_MINUTES} minutes."
        exit 1
    fi

    if [[ -z "${target_user}" || "${target_user}" == "loginwindow" ]]; then
        log "ERROR" "No valid target user detected."
        exit 1
    fi

    if ! id "${target_user}" &>/dev/null; then
        log "ERROR" "Target user does not exist: ${target_user}"
        exit 1
    fi

    if is_protected_user "${target_user}"; then
        log "ERROR" "Protected account cannot be modified: ${target_user}"
        exit 1
    fi

    if ! check_cooldown "${target_user}"; then
        exit 1
    fi

    if is_admin_user "${target_user}"; then
        log "INFO" "User is already admin. No changes made to avoid unintended demotion risk."
        exit 0
    fi

    local now_epoch expiry_epoch state_file
    now_epoch=$(date +%s)
    expiry_epoch=$((now_epoch + (ELEVATION_MINUTES * 60)))
    state_file="${STATE_DIR}/${target_user}.state"

    cat > "${state_file}" <<EOF
request_id=${request_id}
user=${target_user}
start_epoch=${now_epoch}
expiry_epoch=${expiry_epoch}
duration_minutes=${ELEVATION_MINUTES}
justification=${JUSTIFICATION}
EOF
    chown root:wheel "${state_file}" 2>/dev/null || true
    chmod 600 "${state_file}"

    log "INFO" "Granting temporary admin to: ${target_user}"
    dseditgroup -o edit -a "${target_user}" -t user admin
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to add user to admin group: ${target_user}"
        rm -f "${state_file}"
        exit 1
    fi

    local wait_seconds
    wait_seconds=$((ELEVATION_MINUTES * 60))
    log "INFO" "Scheduling auto-revoke in ${ELEVATION_MINUTES} minute(s) (${wait_seconds} seconds)."

    create_revoke_job "${target_user}" "${wait_seconds}" "${request_id}"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Auto-revoke job setup failed. Rolling back admin grant."
        dseditgroup -o edit -d "${target_user}" -t user admin >/dev/null 2>&1 || true
        rm -f "${state_file}"
        exit 1
    fi

    ulog "action=grant user=${target_user} request_id=${request_id} duration=${ELEVATION_MINUTES}m result=success"

    log "INFO" "========================================"
    log "INFO" "Summary"
    log "INFO" "========================================"
    log "INFO" "Request ID: ${request_id}"
    log "INFO" "Target user elevated: ${target_user}"
    log "INFO" "Auto-revoke scheduled in: ${ELEVATION_MINUTES} minute(s)"
    log "INFO" "Justification: ${JUSTIFICATION}"
    log "INFO" "Log file location: ${LOG_FILE}"
    log "INFO" "========================================"
    log "INFO" "Script completed successfully"
    log "INFO" "========================================"

    exit 0
}

main "$@"
