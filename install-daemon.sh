#!/bin/bash
set -e

# KompleteKontrol LibUSB Daemon Installer
# This script installs the daemon as a launchd service, allowing it to start
# without requiring password prompts each time.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_LABEL="media.vanille.kompletekontrol-libusb"
PLIST_FILE="$SCRIPT_DIR/media.vanille.kompletekontrol-libusb.plist"
LAUNCHD_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
SOCKET_PATH="/var/run/kompletekontrol-libusb.sock"
EXECUTABLE_PATH="$SCRIPT_DIR/.build/debug/ccd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "KompleteKontrol LibUSB Daemon Installer"
echo "======================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Check if executable exists
if [ ! -f "$EXECUTABLE_PATH" ]; then
    echo -e "${YELLOW}Warning: Executable not found at $EXECUTABLE_PATH${NC}"
    echo "Building the project first..."
    cd "$SCRIPT_DIR"
    swift build --product ccd
    if [ ! -f "$EXECUTABLE_PATH" ]; then
        echo -e "${RED}Error: Failed to build executable${NC}"
        exit 1
    fi
fi

# Stop any existing daemon
echo "Stopping any existing daemon..."
launchctl bootout system "$LAUNCHD_PLIST" 2>/dev/null || true
launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true

daemon_pids="$(pgrep -f "kk-libusb-daemon" || true)"
if [ -n "$daemon_pids" ]; then
    echo "$daemon_pids" | xargs kill 2>/dev/null || true
    for i in {1..20}; do
        daemon_pids="$(pgrep -f "kk-libusb-daemon" || true)"
        if [ -z "$daemon_pids" ]; then
            break
        fi
        sleep 0.1
    done
    daemon_pids="$(pgrep -f "kk-libusb-daemon" || true)"
    if [ -n "$daemon_pids" ]; then
        echo "$daemon_pids" | xargs kill -9 2>/dev/null || true
    fi
fi
rm -f "$SOCKET_PATH" /var/run/kompletekontrol-libusb.lock

# Copy executable to /usr/local/bin
echo "Installing ccd to /usr/local/bin..."
cp "$EXECUTABLE_PATH" /usr/local/bin/ccd
chmod +x /usr/local/bin/ccd

# Update plist with correct executable path
echo "Installing launchd plist..."
cp "$PLIST_FILE" "$LAUNCHD_PLIST"
chmod 644 "$LAUNCHD_PLIST"

# Load the daemon
echo "Loading daemon..."
launchctl bootstrap system "$LAUNCHD_PLIST" 2>/dev/null || launchctl load "$LAUNCHD_PLIST"
launchctl kickstart -k "system/$DAEMON_LABEL" 2>/dev/null || true

# Wait for socket to appear
echo "Waiting for daemon to start..."
for i in {1..10}; do
    if [ -S "$SOCKET_PATH" ]; then
        echo -e "${GREEN}Daemon started successfully!${NC}"
        echo "Socket: $SOCKET_PATH"
        echo "Log: /tmp/media.vanille.kompletekontrol-libusb.stdout.log"
        echo ""
        echo "To control the daemon:"
        echo "  Start:   sudo launchctl bootstrap system $LAUNCHD_PLIST"
        echo "  Stop:    sudo launchctl bootout system $LAUNCHD_PLIST"
        echo "  Restart: sudo launchctl kickstart -k system/$DAEMON_LABEL"
        echo "  Status:  sudo launchctl print system/$DAEMON_LABEL"
        exit 0
    fi
    sleep 0.5
done

echo -e "${RED}Error: Daemon failed to start within 5 seconds${NC}"
echo "Check logs: /tmp/media.vanille.kompletekontrol-libusb.stderr.log"
exit 1
