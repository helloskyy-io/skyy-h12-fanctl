#!/usr/bin/env bash
#
# hs-fan-mode-init.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Fan Mode Initialization
# ------------------------------------------------------------
# Sets the Supermicro BMC fan mode to Heavy I/O (0x04) which is
# optimal for EPYC systems. This should run before the daemon
# starts to ensure the BMC is in the correct mode.
#
# This script is designed to run as a systemd oneshot service
# at boot time.
# -------------------------------------------------------------------

# ipmitool path (override via environment if needed)
IPMITOOL_BIN="${IPMITOOL_BIN:-/usr/bin/ipmitool}"

# Fan mode: 0x04 = Heavy I/O (best for EPYC thermals)
FAN_MODE="${FAN_MODE:-0x04}"

# Tag used in syslog
LOG_TAG="${LOG_TAG:-hs-fan-mode-init}"

log_info()  { logger -t "$LOG_TAG" "INFO: $*"; }
log_warn()  { logger -t "$LOG_TAG" "WARN: $*"; }
log_error() { logger -t "$LOG_TAG" "ERROR: $*"; }

# Check prerequisites
if ! command -v "$IPMITOOL_BIN" >/dev/null 2>&1; then
    log_error "ipmitool not found at '$IPMITOOL_BIN'. Exiting."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    log_error "Script must be run as root. Exiting."
    exit 1
fi

# Set fan mode to Heavy I/O (0x04)
log_info "Setting Supermicro fan mode to Heavy I/O (0x04)."
"$IPMITOOL_BIN" raw 0x30 0x45 0x01 "$FAN_MODE" >/dev/null 2>&1
rc=$?

if [ $rc -eq 0 ]; then
    # Verify the setting
    current_mode="$("$IPMITOOL_BIN" raw 0x30 0x45 0x00 2>/dev/null | tr -d '[:space:]')"
    log_info "Fan mode set successfully. Current mode: ${current_mode:-unknown}"
    exit 0
else
    log_error "Failed to set fan mode (rc=$rc)."
    exit 1
fi

