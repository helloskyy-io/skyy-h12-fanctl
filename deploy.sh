#!/usr/bin/env bash
#
# deploy.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Series Fan Control Deployment Script
# -------------------------------------------------------------------------
# IMPORTANT: This solution is ONLY compatible with Supermicro H12 series
#            motherboards. It uses H12-specific IPMI commands.
#
# Automated deployment script for installing and configuring the
# Supermicro H12 series fan control system on Proxmox/Ubuntu/Debian servers.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash
#   OR
#   wget -qO- https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash
# -------------------------------------------------------------------

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Please use sudo."
    exit 1
fi

log_info "Starting deployment of HelloSkyy H12 Fan Control..."

# Detect if we're in a git repo or standalone script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/scripts/hs-fan-daemon.sh" ]; then
    # Running from cloned repo
    REPO_DIR="$SCRIPT_DIR"
    log_info "Detected local repository at $REPO_DIR"
else
    # Running from curl/wget - need to clone
    log_info "Cloning repository..."
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    git clone https://github.com/helloskyy-io/skyy-h12-fanctl.git "$TEMP_DIR" || {
        log_error "Failed to clone repository. Please check network connectivity."
        exit 1
    }
    REPO_DIR="$TEMP_DIR"
fi

# Install prerequisites
log_info "Installing prerequisites (ipmitool, lm-sensors)..."
apt-get update -qq

# Check and install ipmitool
if ! command -v ipmitool >/dev/null 2>&1; then
    log_info "Installing ipmitool..."
    apt-get install -y ipmitool >/dev/null 2>&1 || {
        log_error "Failed to install ipmitool."
        exit 1
    }
else
    log_info "ipmitool already installed."
fi

# Check and install lm-sensors
if ! command -v sensors >/dev/null 2>&1; then
    log_info "Installing lm-sensors..."
    apt-get install -y lm-sensors >/dev/null 2>&1 || {
        log_error "Failed to install lm-sensors."
        exit 1
    }
else
    log_info "lm-sensors already installed."
fi

# Load IPMI kernel modules if needed
log_info "Checking IPMI kernel modules..."
if ! lsmod | grep -q ipmi_msghandler; then
    log_info "Loading IPMI kernel modules..."
    modprobe ipmi_msghandler 2>/dev/null || true
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si 2>/dev/null || true
fi

# Verify ipmitool works
log_info "Verifying IPMI access..."
if ipmitool mc info >/dev/null 2>&1; then
    log_info "IPMI access verified successfully."
else
    log_warn "IPMI may not be accessible. This is OK if BMC is not configured or accessible."
    log_warn "The daemon will still start but may not be able to control fans."
fi

# Configure sensors (non-interactive)
log_info "Configuring lm-sensors..."
if [ ! -f /etc/sensors3.conf ] && [ ! -f /etc/sensors.conf ]; then
    log_info "Running sensors-detect (non-interactive)..."
    # Auto-answer yes to all sensors-detect prompts
    yes | sensors-detect --auto >/dev/null 2>&1 || {
        log_warn "sensors-detect had issues, but continuing..."
    }
    
    # Try to load detected modules
    if command -v sensors >/dev/null 2>&1; then
        log_info "Testing sensor detection..."
        if sensors >/dev/null 2>&1; then
            log_info "Sensors detected successfully."
        else
            log_warn "Sensors may need manual configuration. Run 'sensors-detect' manually if needed."
        fi
    fi
else
    log_info "Sensors already configured."
fi

# Install scripts
log_info "Installing scripts to /usr/local/sbin/..."
install -m 755 "$REPO_DIR/scripts/hs-fan-daemon.sh" /usr/local/sbin/hs-fan-daemon.sh

# Install systemd service
log_info "Installing systemd service..."
install -m 644 "$REPO_DIR/systemd/hs-fan-daemon.service" /etc/systemd/system/hs-fan-daemon.service

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start service
log_info "Enabling and starting fan daemon service..."
systemctl enable hs-fan-daemon.service

# Start daemon (it will initialize fan mode on startup)
systemctl start hs-fan-daemon.service || {
    log_error "Failed to start daemon service."
    exit 1
}

# Verify services are running
sleep 2
if systemctl is-active --quiet hs-fan-daemon.service; then
    log_info "Fan daemon is running successfully!"
else
    log_error "Fan daemon failed to start. Check logs with: journalctl -u hs-fan-daemon -n 50"
    exit 1
fi

log_info "Deployment complete!"
log_info ""
log_info "Useful commands:"
log_info "  Check status:    systemctl status hs-fan-daemon"
log_info "  View logs:       journalctl -f -t hs-fan-daemon"
log_info "  Stop daemon:     systemctl stop hs-fan-daemon"
log_info "  Restart daemon:  systemctl restart hs-fan-daemon"
log_info ""
log_info "The fan control system is now active and will automatically"
log_info "adjust fan speeds based on CPU temperature."

