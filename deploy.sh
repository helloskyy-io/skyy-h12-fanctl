#!/usr/bin/env bash
#
# deploy.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Fan Control Deployment Script
# -------------------------------------------------------------------
# Automated deployment script for installing and configuring the
# Supermicro H12 fan control system on Proxmox/Ubuntu/Debian servers.
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
apt-get install -y ipmitool lm-sensors >/dev/null 2>&1 || {
    log_error "Failed to install prerequisites."
    exit 1
}

# Verify ipmitool works
log_info "Verifying IPMI access..."
if ! ipmitool mc info >/dev/null 2>&1; then
    log_warn "IPMI may not be accessible. Continuing anyway..."
fi

# Install scripts
log_info "Installing scripts to /usr/local/sbin/..."
install -m 755 "$REPO_DIR/scripts/hs-fan-daemon.sh" /usr/local/sbin/hs-fan-daemon.sh
install -m 755 "$REPO_DIR/scripts/hs-fan-mode-init.sh" /usr/local/sbin/hs-fan-mode-init.sh

# Install systemd services
log_info "Installing systemd services..."
install -m 644 "$REPO_DIR/systemd/hs-fan-mode-init.service" /etc/systemd/system/hs-fan-mode-init.service
install -m 644 "$REPO_DIR/systemd/hs-fan-daemon.service" /etc/systemd/system/hs-fan-daemon.service

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start services
log_info "Enabling and starting services..."
systemctl enable hs-fan-mode-init.service
systemctl enable hs-fan-daemon.service

# Start mode init first
systemctl start hs-fan-mode-init.service || log_warn "Failed to start mode init service (may be OK if already configured)"

# Start daemon
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

