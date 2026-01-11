#!/usr/bin/env bash
#
# update.sh
#
# HelloSkyy / Proxmox – Supermicro H12 Series Fan Control Update Script
# --------------------------------------------------------------------
# Updates an existing installation of the fan control daemon.
# This script is idempotent and safe to run multiple times.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/update.sh | bash
#   OR
#   wget -qO- https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/update.sh | bash
# --------------------------------------------------------------------

set -eo pipefail

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

# Check if already installed
if [ ! -f /usr/local/sbin/hs-fan-daemon.sh ]; then
    log_error "Fan control daemon is not installed."
    log_error "Please run the deployment script first:"
    log_error "  curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash"
    exit 1
fi

log_info "Updating HelloSkyy H12 Fan Control..."

# Clone latest version
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Check if git is available
if ! command -v git >/dev/null 2>&1; then
    log_error "git is not installed. Please install git first:"
    log_error "  apt-get update && apt-get install -y git"
    exit 1
fi

log_info "Fetching latest version from repository..."
if ! git clone https://github.com/helloskyy-io/skyy-h12-fanctl.git "$TEMP_DIR" 2>&1; then
    log_error "Failed to clone repository. Possible issues:"
    log_error "  - Network connectivity"
    log_error "  - GitHub access"
    exit 1
fi

# Check for changes
CHANGED=false
SERVICE_RUNNING=false

if systemctl is-active --quiet hs-fan-daemon.service 2>/dev/null; then
    SERVICE_RUNNING=true
fi

# Compare daemon script
if command -v md5sum >/dev/null 2>&1; then
    OLD_MD5=$(md5sum /usr/local/sbin/hs-fan-daemon.sh 2>/dev/null | cut -d' ' -f1)
    NEW_MD5=$(md5sum "$TEMP_DIR/scripts/hs-fan-daemon.sh" 2>/dev/null | cut -d' ' -f1)
    
    if [ "$OLD_MD5" != "$NEW_MD5" ]; then
        CHANGED=true
        log_info "Daemon script has been updated."
    fi
fi

# Compare service file
if [ -f /etc/systemd/system/hs-fan-daemon.service ]; then
    if command -v md5sum >/dev/null 2>&1; then
        OLD_SVC_MD5=$(md5sum /etc/systemd/system/hs-fan-daemon.service 2>/dev/null | cut -d' ' -f1)
        NEW_SVC_MD5=$(md5sum "$TEMP_DIR/systemd/hs-fan-daemon.service" 2>/dev/null | cut -d' ' -f1)
        
        if [ "$OLD_SVC_MD5" != "$NEW_SVC_MD5" ]; then
            CHANGED=true
            log_info "Systemd service file has been updated."
        fi
    fi
fi

if [ "$CHANGED" = false ]; then
    log_info "Already running the latest version. No update needed."
    exit 0
fi

# Backup current installation (optional but good practice)
BACKUP_DIR="/root/hs-fan-daemon-backup-$(date +%Y%m%d-%H%M%S)"
log_info "Creating backup at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
cp /usr/local/sbin/hs-fan-daemon.sh "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/systemd/system/hs-fan-daemon.service "$BACKUP_DIR/" 2>/dev/null || true
log_info "Backup created."

# Install updated files
log_info "Installing updated files..."
install -m 755 "$TEMP_DIR/scripts/hs-fan-daemon.sh" /usr/local/sbin/hs-fan-daemon.sh
install -m 644 "$TEMP_DIR/systemd/hs-fan-daemon.service" /etc/systemd/system/hs-fan-daemon.service

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Restart service if it was running
if [ "$SERVICE_RUNNING" = true ]; then
    log_info "Restarting fan daemon service to apply updates..."
    systemctl restart hs-fan-daemon.service || {
        log_error "Failed to restart daemon service."
        log_warn "You can restore from backup if needed: $BACKUP_DIR"
        exit 1
    }
    
    # Verify it's running
    sleep 2
    if systemctl is-active --quiet hs-fan-daemon.service; then
        log_info "Update completed successfully! Service is running."
    else
        log_error "Service failed to start after update."
        log_warn "Check logs: journalctl -u hs-fan-daemon -n 50"
        log_warn "Backup available at: $BACKUP_DIR"
        exit 1
    fi
else
    log_info "Update completed. Service was not running, so it was not started."
    log_info "Start it manually with: systemctl start hs-fan-daemon"
fi

log_info ""
log_info "Update complete!"
log_info "Backup location: $BACKUP_DIR"

