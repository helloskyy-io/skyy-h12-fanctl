#!/usr/bin/env bash
#
# hs-fan-daemon.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Series Fan Controller
# ----------------------------------------------------------
# IMPORTANT: This script is ONLY compatible with Supermicro H12 series
#            motherboards. It uses H12-specific IPMI commands and will not
#            work correctly on other Supermicro models or non-Supermicro hardware.
#
# - Runs as a simple daemon on the Proxmox host
# - Reads max(Tctl) across all EPYC CPUs using `sensors`
# - Uses a hysteresis-based fan curve to avoid flapping
# - Applies PWM via Supermicro H12-specific raw IPMI commands
# - Sets BMC fan mode to Full Speed (0x01) on startup (REQUIRED for PWM control)
# - Takes full control of fan speeds via raw PWM commands
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

# Fan zones to control (comma-separated). H12 boards have 2 IPMI zones: 0x00 = general-purpose (FAN1..8), 0x01 = CPU fan headers (FANA,FANB). 0x02/0x03 do nothing on H12.
FAN_ZONES="${FAN_ZONES:-0x00,0x01}"

# Legacy support: if FAN_ZONE is set, use it as single zone
if [ -n "${FAN_ZONE:-}" ]; then
    FAN_ZONES="$FAN_ZONE"
fi

# Polling interval in seconds
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Minimum duty (%), held FLAT from 0 up to FAN_MIN_TEMP. Any integer 10..100.
# No longer restricted to steps of 10: the BMC duty register is a plain byte,
# which is observable in its own readback (a write of 30 reads back as 29).
FAN_MIN_LEVEL="${FAN_MIN_LEVEL:-25}"
case "$FAN_MIN_LEVEL" in
    ''|*[!0-9]*) FAN_MIN_LEVEL=25 ;;
    *) [ "$FAN_MIN_LEVEL" -lt 10 ]  && FAN_MIN_LEVEL=10
       [ "$FAN_MIN_LEVEL" -gt 100 ] && FAN_MIN_LEVEL=100 ;;
esac

# THE RAMP. Duty is flat at FAN_MIN_LEVEL up to FAN_MIN_TEMP, then rises
# linearly to 100% at FAN_MAX_TEMP.
#
#   floor 25%, flat to 45C, 100% at 85C  ->  slope 1.88 %/C
#     45C 25%   55C 44%   65C 63%   75C 81%   85C 100%
#
# WHY THESE NUMBERS AND NOT STEEPER. This is a closed loop: duty changes
# temperature, which changes duty. It converges only while
#
#     slope x thermal_response  <  1
#
# Measured on H12DSi with EPYC 7002: 10 duty points moves Tctl about 4C, so
# thermal_response is about 0.4 C per point. At slope 1.88 the loop gain is
# 0.75 and it settles. A "more responsive" curve reaching 100% at 70C instead
# gives slope 3.0 and loop gain 1.2, and the fans oscillate indefinitely at
# whatever band they land on. That is not a tuning preference, it is the
# stability limit, and the guard in the main loop warns when a config crosses it.
FAN_MIN_TEMP="${FAN_MIN_TEMP:-45}"
FAN_MAX_TEMP="${FAN_MAX_TEMP:-85}"

# Write deadband, in duty points. Hold the current duty until the computed
# target has moved this far, so 1C of sensor jitter does not write the BMC
# every POLL_INTERVAL. Stable at any width while loop gain stays below 1.
FAN_WRITE_DELTA="${FAN_WRITE_DELTA:-3}"

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

# Initialize BMC fan mode to Full Speed (0x01) - REQUIRED for PWM control
# This only runs once at daemon startup
# Checks current mode first and only sets it if needed
initialize_fan_mode() {
    local fan_mode="${FAN_MODE:-0x01}"
    
    # Check current fan mode
    local current_mode
    current_mode="$("$IPMITOOL_BIN" raw 0x30 0x45 0x00 2>/dev/null | tr -d '[:space:]')"
    
    if [ "$current_mode" = "01" ]; then
        log_info "BMC fan mode is already set to Full Speed (0x01). No change needed."
        return 0
    fi
    
    # Mode is not Full Speed, need to set it
    log_info "Current BMC fan mode is ${current_mode:-unknown}, setting to Full Speed ($fan_mode) - required for PWM control..."
    
    "$IPMITOOL_BIN" raw 0x30 0x45 0x01 "$fan_mode" >/dev/null 2>&1
    local rc=$?
    
    if [ $rc -eq 0 ]; then
        # Verify the setting was applied
        local new_mode
        new_mode="$("$IPMITOOL_BIN" raw 0x30 0x45 0x00 2>/dev/null | tr -d '[:space:]')"
        if [ "$new_mode" = "01" ]; then
            log_info "BMC fan mode successfully set to Full Speed (0x01)."
        else
            log_warn "Warning: Attempted to set mode to 01, but current mode is $new_mode. PWM control may not work properly."
        fi
    else
        log_error "Failed to set BMC fan mode to Full Speed (rc=$rc). PWM control requires mode 0x01!"
        log_error "Daemon will continue but may not function correctly."
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

# Map logical fan level (20,30,40,50,60,70,80,90,100) to PWM hex.
# Uses numeric comparison and sanitizes input to digits only.
level_to_pwm() {
    local raw_level="$1"
    # Keep only digits (defensive: strip spaces, CR, etc.)
    local lvl="${raw_level//[^0-9]/}"

    if   [ "$lvl" -eq 20 ]; then
        echo "0x14"   # 20%
    elif [ "$lvl" -eq 30 ]; then
        echo "0x1E"   # 30%
    elif [ "$lvl" -eq 40 ]; then
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

# Duty (%) from temperature: flat floor, then a linear ramp. Replaces the
# nine-bucket lookup, the nine-arm hysteresis table and its eighteen hardcoded
# thresholds. Pure function of temperature, so it has no path dependence of its
# own; the only hysteresis in the daemon is FAN_WRITE_DELTA, which is symmetric.
pwm_from_temp() {
    local t="$1"
    [ "$t" -le "$FAN_MIN_TEMP" ] && { echo "$FAN_MIN_LEVEL"; return; }
    [ "$t" -ge "$FAN_MAX_TEMP" ] && { echo 100; return; }
    local span=$(( FAN_MAX_TEMP - FAN_MIN_TEMP ))
    local rise=$(( 100 - FAN_MIN_LEVEL ))
    local dt=$(( t - FAN_MIN_TEMP ))
    echo $(( FAN_MIN_LEVEL + (dt * rise + span / 2) / span ))
}

# Initial level based purely on temperature (no hysteresis),
# used only when there is no previous level recorded.
# RETAINED UNUSED: kept so a rollback to the bucket design is a one-line
# change in the main loop rather than a restore from git.
#
# Neutral bands:
# < 35   -> 20%
# 35–39  -> 30%
# 40–44  -> 40%
# 45–49  -> 50%
# 50–54  -> 60%
# 55–59  -> 70%
# 60–64  -> 80%
# 65–69  -> 90%
# >= 70  -> 100%
initial_level_from_temp() {
    local t="$1"
    if   [ "$t" -lt 35 ]; then
        echo 20
    elif [ "$t" -lt 40 ]; then
        echo 30
    elif [ "$t" -lt 45 ]; then
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
        20)
            # 20 -> 30 when temp >= 37
            if [ "$temp" -ge 37 ]; then echo 30; else echo 20; fi
            ;;
        30)
            # 30 -> 40 when temp >= 42
            # 30 -> 20 when temp <= 33
            if   [ "$temp" -ge 42 ]; then echo 40
            elif [ "$temp" -le 33 ]; then echo 20
            else echo 30
            fi
            ;;
        40)
            # 40 -> 50 when temp >= 47
            # 40 -> 30 when temp <= 38
            if   [ "$temp" -ge 47 ]; then echo 50
            elif [ "$temp" -le 38 ]; then echo 30
            else echo 40
            fi
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

# Applies a PWM value to all configured fan zones if it differs from the last applied value.
apply_pwm_if_changed() {
    local new_pwm="$1"
    local last_pwm="$2"

    # Only send IPMI commands if PWM actually changed
    if [ "$new_pwm" != "$last_pwm" ]; then
        local zones_changed=0
        local zones_failed=0
        local zones_list=""
        
        # Apply PWM to each zone
        IFS=',' read -ra ZONE_ARRAY <<< "$FAN_ZONES"
        for zone in "${ZONE_ARRAY[@]}"; do
            # Trim whitespace from zone
            zone=$(echo "$zone" | xargs)
            
            "$IPMITOOL_BIN" raw 0x30 0x70 0x66 0x01 "$zone" "$new_pwm" >/dev/null 2>&1
            local rc=$?
            if [ $rc -eq 0 ]; then
                zones_changed=$((zones_changed + 1))
                zones_list="${zones_list}${zones_list:+, }${zone}"
            else
                zones_failed=$((zones_failed + 1))
                log_warn "Failed to set PWM=${new_pwm} for zone ${zone} (rc=$rc)."
            fi
        done
        
        if [ $zones_changed -gt 0 ]; then
            log_info "Set PWM=${new_pwm} on ${zones_changed} zone(s) [${zones_list}] (previous=${last_pwm:-none})."
            if [ $zones_failed -gt 0 ]; then
                log_warn "${zones_failed} zone(s) failed to update."
            fi
            echo "$new_pwm"
        else
            log_error "Failed to set PWM=${new_pwm} on any zone. Keeping previous=${last_pwm:-none}."
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

    log_info "Starting main loop (interval=${POLL_INTERVAL}s, zones=${FAN_ZONES}, floor=${FAN_MIN_LEVEL}% flat to ${FAN_MIN_TEMP}C, 100% at ${FAN_MAX_TEMP}C, write_delta=${FAN_WRITE_DELTA})."
    # Stability guard. Warns at loop gain >= 0.9, i.e. slope >= 3.0 %/C, using
    # the thermal response MEASURED on 2026-11-10 (0.3 C per duty point). The
    # first version of this guard used an inferred 0.4 and so fired at slope
    # 2.25, which is gain 0.68 and perfectly stable: it was warning about
    # curves that work. The threshold is 100-floor >= 3 x (max - flat_to).
    if [ "$(( 100 - FAN_MIN_LEVEL ))" -ge "$(( 3 * (FAN_MAX_TEMP - FAN_MIN_TEMP) ))" ]; then
        log_warn "Curve slope is steep enough that the control loop may OSCILLATE (loop gain approaching 1). Raise FAN_MAX_TEMP or lower FAN_MIN_TEMP."
    fi
    # Quantisation guard: FAN_WRITE_DELTA must EXCEED the slope in points-per-degree.
    # Tctl arrives as whole degrees, so if one degree of sensor jitter moves the
    # target by a full deadband, the smallest reportable input change writes the
    # BMC. Measured 2026-11-10 on puma-server-204: slope 3.0 with delta 3 gave 13
    # writes in 5.4 minutes, flipping 3 points up and down on 1C of noise; delta 5
    # on the identical slope gave 1. This is NOT the loop instability above, which
    # is about gain; it is the input's resolution against the deadband.
    if [ "$(( FAN_WRITE_DELTA * (FAN_MAX_TEMP - FAN_MIN_TEMP) ))" -le "$(( 100 - FAN_MIN_LEVEL ))" ]; then
        log_warn "FAN_WRITE_DELTA=${FAN_WRITE_DELTA} is not larger than the curve slope, so 1C of sensor jitter will write the BMC. Raise FAN_WRITE_DELTA."
    fi

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

        # Target duty straight from the curve.
        local want
        want="$(pwm_from_temp "$temp_int")"

        # Write deadband: hold the current duty until the target moves far enough.
        local new_duty
        if [ -z "$last_level" ]; then
            new_duty="$want"
        else
            local d=$(( want - last_level ))
            [ "$d" -lt 0 ] && d=$(( -d ))
            if [ "$d" -ge "$FAN_WRITE_DELTA" ]; then
                new_duty="$want"
            else
                new_duty="$last_level"
            fi
        fi

        local pwm
        pwm="$(printf '0x%02X' "$new_duty")"

        local prev_pwm="$last_pwm"
        last_pwm="$(apply_pwm_if_changed "$pwm" "$last_pwm")"
        last_level="$new_duty"

        if [ "$last_pwm" != "$prev_pwm" ]; then
            log_info "Temp=${temp_int}°C, duty=${new_duty}% (target ${want}%), PWM=${last_pwm}."
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
initialize_fan_mode
log_info "Launching hs-fan-daemon."
main_loop

