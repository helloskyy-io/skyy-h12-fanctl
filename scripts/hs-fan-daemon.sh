#!/usr/bin/env bash
#
# hs-fan-daemon.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Fan Controller
# ---------------------------------------------------
# - Runs as a simple daemon on the Proxmox host
# - Reads max(Tctl) across all EPYC CPUs using `sensors`
# - Uses a hysteresis-based fan curve to avoid flapping
# - Applies PWM via Supermicro raw IPMI command
# - Assumes BMC fan mode is already set to FULL (0x01)
#
# Notes:
# - If this daemon stops, the BMC / BIOS logic will eventually take over,
#   usually ramping fans up, which is safe.
# - This script is intentionally minimal and self-contained
#   so it can be deployed easily via Ansible.
# -------------------------------------------------------------------

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

# ipmitool path (override via environment if needed)
IPMITOOL_BIN="${IPMITOOL_BIN:-/usr/bin/ipmitool}"

# Fan zone to control (0x00 = all fans on many H12 boards)
FAN_ZONE="${FAN_ZONE:-0x00}"

# Polling interval in seconds
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Tag used in syslog
LOG_TAG="${LOG_TAG:-hs-fan-daemon}"

# -------------------------------------------------------------------
# Utility Functions
# -------------------------------------------------------------------

log_info()  { logger -t "$LOG_TAG" "INFO: $*"; }
log_warn()  { logger -t "$LOG_TAG" "WARN: $*"; }
log_error() { logger -t "$LOG_TAG" "ERROR: $*"; }

# -------------------------------------------------------------------
# Environment / Sanity Checks
# -------------------------------------------------------------------

check_prerequisites() {
    # Ensure ipmitool exists and is executable
    if ! command -v "$IPMITOOL_BIN" >/dev/null 2>&1; then
        log_error "ipmitool not found at '$IPMITOOL_BIN'. Exiting."
        exit 1
    fi

    # Must be root to talk to IPMI and read sensors reliably
    if [ "$EUID" -ne 0 ]; then
        log_error "Script must be run as root. Exiting."
        exit 1
    fi

    # Ensure `sensors` command exists
    if ! command -v sensors >/dev/null 2>&1; then
        log_error "'sensors' command not found. Install lm-sensors. Exiting."
        exit 1
    fi
}

# -------------------------------------------------------------------
# Core Logic Functions
# -------------------------------------------------------------------

# Reads max(Tctl) across all CPUs.
# Returns a numeric value (e.g. "57.8") or exits non-zero on failure.
read_max_tctl() {
    sensors 2>/dev/null | awk '
        /Tctl:/ {
            val = $2
            gsub(/\+/,"",val)
            gsub(/°C/,"",val)
            if (val > max) max = val
        }
        END {
            if (max == "") exit 1
            print max
        }'
}

# Map logical fan level (40,50,60,70,80,90,100) to PWM hex.
# Uses numeric comparison and sanitizes input to digits only.
level_to_pwm() {
    local raw_level="$1"
    # Keep only digits (defensive: strip spaces, CR, etc.)
    local lvl="${raw_level//[^0-9]/}"

    if   [ "$lvl" -eq 40 ]; then
        echo "0x28"   # 40%
    elif [ "$lvl" -eq 50 ]; then
        echo "0x32"   # 50%
    elif [ "$lvl" -eq 60 ]; then
        echo "0x3C"   # 60%
    elif [ "$lvl" -eq 70 ]; then
        echo "0x46"   # 70%
    elif [ "$lvl" -eq 80 ]; then
        echo "0x50"   # 80%
    elif [ "$lvl" -eq 90 ]; then
        echo "0x5A"   # 90%
    elif [ "$lvl" -eq 100 ]; then
        echo "0x64"   # 100%
    else
        # Invalid / unknown level
        echo ""
    fi
}

# Initial level based purely on temperature (no hysteresis),
# used only when there is no previous level recorded.
#
# Neutral bands:
# < 45   -> 40%
# 45–49  -> 50%
# 50–54  -> 60%
# 55–59  -> 70%
# 60–64  -> 80%
# 65–69  -> 90%
# >= 70  -> 100%
initial_level_from_temp() {
    local t="$1"
    if   [ "$t" -lt 45 ]; then
        echo 40
    elif [ "$t" -lt 50 ]; then
        echo 50
    elif [ "$t" -lt 55 ]; then
        echo 60
    elif [ "$t" -lt 60 ]; then
        echo 70
    elif [ "$t" -lt 65 ]; then
        echo 80
    elif [ "$t" -lt 70 ]; then
        echo 90
    else
        echo 100
    fi
}

# Hysteresis-based level selection.
# We keep the "move up" thresholds from the neutral bands,
# and define slightly lower "move down" thresholds so the fan
# doesn't flap between adjacent levels.
#
# last_level + temp -> new_level
next_level_with_hysteresis() {
    local temp="$1"
    local last_level="$2"

    # First sample: choose level directly from temp.
    if [ -z "$last_level" ]; then
        initial_level_from_temp "$temp"
        return
    fi

    case "$last_level" in
        40)
            # 40 -> 50 when temp >= 47
            if [ "$temp" -ge 47 ]; then echo 50; else echo 40; fi
            ;;
        50)
            # 50 -> 60 when temp >= 52
            # 50 -> 40 when temp <= 43
            if   [ "$temp" -ge 52 ]; then echo 60
            elif [ "$temp" -le 43 ]; then echo 40
            else echo 50
            fi
            ;;
        60)
            # 60 -> 70 when temp >= 57
            # 60 -> 50 when temp <= 48
            if   [ "$temp" -ge 57 ]; then echo 70
            elif [ "$temp" -le 48 ]; then echo 50
            else echo 60
            fi
            ;;
        70)
            # 70 -> 80 when temp >= 62
            # 70 -> 60 when temp <= 53
            if   [ "$temp" -ge 62 ]; then echo 80
            elif [ "$temp" -le 53 ]; then echo 60
            else echo 70
            fi
            ;;
        80)
            # 80 -> 90 when temp >= 67
            # 80 -> 70 when temp <= 58
            if   [ "$temp" -ge 67 ]; then echo 90
            elif [ "$temp" -le 58 ]; then echo 70
            else echo 80
            fi
            ;;
        90)
            # 90 -> 100 when temp >= 72
            # 90 -> 80 when temp <= 63
            if   [ "$temp" -ge 72 ]; then echo 100
            elif [ "$temp" -le 63 ]; then echo 80
            else echo 90
            fi
            ;;
        100)
            # 100 -> 90 when temp <= 68
            if [ "$temp" -le 68 ]; then echo 90; else echo 100; fi
            ;;
        *)
            # Fallback: recompute from temp
            initial_level_from_temp "$temp"
            ;;
    esac
}

# Applies a PWM value if it differs from the last applied value.
apply_pwm_if_changed() {
    local new_pwm="$1"
    local last_pwm="$2"

    # Only send IPMI command if PWM actually changed
    if [ "$new_pwm" != "$last_pwm" ]; then
        "$IPMITOOL_BIN" raw 0x30 0x70 0x66 0x01 "$FAN_ZONE" "$new_pwm" >/dev/null 2>&1
        local rc=$?
        if [ $rc -eq 0 ]; then
            log_info "Set PWM=${new_pwm} (previous=${last_pwm:-none})."
            echo "$new_pwm"
        else
            log_error "Failed to set PWM=${new_pwm} (rc=$rc). Keeping previous=${last_pwm:-none}."
            echo "$last_pwm"
        fi
    else
        # No change
        echo "$last_pwm"
    fi
}

# -------------------------------------------------------------------
# Main Daemon Loop
# -------------------------------------------------------------------

main_loop() {
    local last_pwm=""
    local last_level=""

    log_info "Starting main loop (interval=${POLL_INTERVAL}s, zone=${FAN_ZONE})."

    while true; do
        # Read current max Tctl
        local cpu_temp
        cpu_temp="$(read_max_tctl)"
        if [ $? -ne 0 ] || [ -z "$cpu_temp" ]; then
            log_warn "Failed to read CPU temperature; keeping last PWM=${last_pwm:-unknown}."
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Strip decimal part: "57.8" -> "57"
        local temp_int="${cpu_temp%.*}"

        # Decide next level using hysteresis
        local new_level_raw
        new_level_raw="$(next_level_with_hysteresis "$temp_int" "$last_level")"

        # Sanitize level to digits only
        local new_level="${new_level_raw//[^0-9]/}"
        if [ -z "$new_level" ]; then
            log_warn "Hysteresis returned invalid level '${new_level_raw}' for temp=${temp_int}°C. Skipping."
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Convert to PWM hex
        local pwm
        pwm="$(level_to_pwm "$new_level")"
        if [ -z "$pwm" ]; then
            log_warn "Computed invalid fan level '${new_level}' for temp=${temp_int}°C. Skipping."
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Apply PWM if changed
        local prev_pwm="$last_pwm"
        last_pwm="$(apply_pwm_if_changed "$pwm" "$last_pwm")"
        last_level="$new_level"

        if [ "$last_pwm" != "$prev_pwm" ]; then
            log_info "Temp=${temp_int}°C, level=${last_level}%, PWM=${last_pwm}."
        fi

        sleep "$POLL_INTERVAL"
    done
}

# -------------------------------------------------------------------
# Entry Point
# -------------------------------------------------------------------

on_exit() {
    log_info "Exiting hs-fan-daemon."
}

trap on_exit EXIT

check_prerequisites
log_info "Launching hs-fan-daemon."
main_loop

