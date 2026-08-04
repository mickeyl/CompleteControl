#!/bin/bash
set -e

# KompleteKontrol LibUSB Daemon Installer
# This script installs the daemon as a launchd service, allowing it to start
# without requiring password prompts each time.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# One product-bound daemon per surface: the historical label keeps the KONTROL
# MK2 on the stock socket, a second label owns the MASCHINE MK3. The MASCHINE
# daemon is optional: pass KK_INSTALL_MASCHINE_DAEMON=0 to skip it.
DAEMON_LABELS=("media.vanille.kompletekontrol-libusb")
SOCKET_PATHS=("/var/run/kompletekontrol-libusb.sock")
INSTALL_MASCHINE="${KK_INSTALL_MASCHINE_DAEMON:-1}"
if [ "$INSTALL_MASCHINE" = "1" ]; then
    DAEMON_LABELS+=("media.vanille.kompletekontrol-maschine")
    SOCKET_PATHS+=("/var/run/kompletekontrol-maschine.sock")
fi
DEBUG_DAEMON="${KK_INSTALL_DEBUG_DAEMON:-0}"
ENABLE_AUTOMATION="${CCD_ENABLE_AUTOMATION:-0}"
BUILD_CONFIGURATION="${KK_INSTALL_DAEMON_CONFIGURATION:-release}"
EXECUTABLE_PATH="${KK_INSTALL_DAEMON_EXECUTABLE:-$SCRIPT_DIR/.build/release/ccd}"
RESOURCE_BUNDLE_NAME="CompleteControl_KompleteKontrol.bundle"
RESOURCE_BUNDLE_PATH="${KK_INSTALL_DAEMON_RESOURCE_BUNDLE:-$(dirname "$EXECUTABLE_PATH")/$RESOURCE_BUNDLE_NAME}"
INSTALLED_RESOURCE_BUNDLE="/usr/local/bin/$RESOURCE_BUNDLE_NAME"
DISPLAY_ENCODING="${KK_INSTALL_MK2_DISPLAY_ENCODING:-adaptive}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "KompleteKontrol LibUSB Daemon Installer"
echo "======================================"
if [ "$DEBUG_DAEMON" = "1" ]; then
    echo "Mode: debug daemon with trace logging"
else
    echo "Mode: normal release daemon"
fi
if [ "$ENABLE_AUTOMATION" = "1" ]; then
    echo "Automation input: enabled"
fi
echo "Executable: $EXECUTABLE_PATH"
echo "Resources: $RESOURCE_BUNDLE_PATH"
case "$DISPLAY_ENCODING" in
    legacy|adaptive) ;;
    *)
        echo "Warning: invalid MK2 display encoding '$DISPLAY_ENCODING'; using legacy." >&2
        DISPLAY_ENCODING="legacy"
        ;;
esac
echo "MK2 display encoding: $DISPLAY_ENCODING"

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
    swift build -c "$BUILD_CONFIGURATION" --product ccd
    if [ ! -f "$EXECUTABLE_PATH" ]; then
        echo -e "${RED}Error: Failed to build executable${NC}"
        exit 1
    fi
fi

if [ ! -d "$RESOURCE_BUNDLE_PATH" ]; then
    echo -e "${RED}Error: Resource bundle not found at $RESOURCE_BUNDLE_PATH${NC}"
    exit 1
fi

# Stop any existing daemons
echo "Stopping any existing daemons..."
for label in "${DAEMON_LABELS[@]}"; do
    launchctl bootout system "/Library/LaunchDaemons/$label.plist" 2>/dev/null || true
    launchctl unload "/Library/LaunchDaemons/$label.plist" 2>/dev/null || true
done

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
for socket_path in "${SOCKET_PATHS[@]}"; do
    rm -f "$socket_path" "${socket_path%.sock}.lock"
done

# Copy executable to /usr/local/bin
echo "Installing ccd to /usr/local/bin..."
cp "$EXECUTABLE_PATH" /usr/local/bin/ccd
chmod +x /usr/local/bin/ccd
echo "Installing ccd resources..."
ditto "$RESOURCE_BUNDLE_PATH" "$INSTALLED_RESOURCE_BUNDLE"
chmod -R a+rX "$INSTALLED_RESOURCE_BUNDLE"

# Update plists with the shared environment and load each daemon
for label in "${DAEMON_LABELS[@]}"; do
    plist_file="$SCRIPT_DIR/$label.plist"
    launchd_plist="/Library/LaunchDaemons/$label.plist"
    echo "Installing launchd plist $label..."
    cp "$plist_file" "$launchd_plist"
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "$launchd_plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$launchd_plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:KK_MK2_DISPLAY_ENCODING string $DISPLAY_ENCODING" "$launchd_plist"
    if [ "$DEBUG_DAEMON" = "1" ]; then
        /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:LOGLEVEL string TRACE" "$launchd_plist"
        /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:KK_DAEMON_DEBUG string 1" "$launchd_plist"
        /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:KK_USB_DEBUG string 1" "$launchd_plist"
        /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:KK_DAEMON_LOG string 1" "$launchd_plist"
    fi
    if [ "$ENABLE_AUTOMATION" = "1" ]; then
        /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CCD_ENABLE_AUTOMATION string 1" "$launchd_plist"
    fi
    chmod 644 "$launchd_plist"

    echo "Loading daemon $label..."
    launchctl bootstrap system "$launchd_plist" 2>/dev/null || launchctl load "$launchd_plist"
    launchctl kickstart -k "system/$label" 2>/dev/null || true
done

# Wait for every socket to appear
echo "Waiting for daemons to start..."
all_ready=0
for i in {1..10}; do
    all_ready=1
    for socket_path in "${SOCKET_PATHS[@]}"; do
        if [ ! -S "$socket_path" ]; then
            all_ready=0
        fi
    done
    if [ "$all_ready" = "1" ]; then
        break
    fi
    sleep 0.5
done

if [ "$all_ready" = "1" ]; then
    echo -e "${GREEN}Daemons started successfully!${NC}"
    for index in "${!DAEMON_LABELS[@]}"; do
        echo "  ${DAEMON_LABELS[$index]} -> ${SOCKET_PATHS[$index]}"
    done
    echo ""
    echo "To control a daemon (substitute its label):"
    echo "  Start:   sudo launchctl bootstrap system /Library/LaunchDaemons/<label>.plist"
    echo "  Stop:    sudo launchctl bootout system /Library/LaunchDaemons/<label>.plist"
    echo "  Restart: sudo launchctl kickstart -k system/<label>"
    echo "  Status:  sudo launchctl print system/<label>"
    exit 0
fi

echo -e "${RED}Error: Not every daemon socket appeared within 5 seconds${NC}"
for label in "${DAEMON_LABELS[@]}"; do
    echo "Check logs: /tmp/$label.stderr.log"
done
exit 1
