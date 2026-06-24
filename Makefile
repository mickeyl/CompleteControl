.DEFAULT_GOAL := help

SOCKET ?= /var/run/kompletekontrol-libusb.sock
PROBE := .build/debug/KontrolProbe

.PHONY: help build install-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart run kk-ui kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk 'BEGIN { printf "KompleteKontrol-Swift developer targets\n\nUsage:\n  make <target>\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-18s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

build: ## Build KontrolProbe.
	swift build --product KontrolProbe

install-daemon: ## Install daemon as launchd service (requires sudo, one-time setup).
	sudo ./install-daemon.sh

uninstall-daemon: ## Uninstall daemon launchd service (requires sudo).
	@echo "Stopping and removing daemon service..."
	-sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo rm -f /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist
	-sudo rm -f /usr/local/bin/KontrolProbe
	-sudo pkill -f -- '--kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET)
	@echo "Daemon service uninstalled."

daemon-status: ## Show daemon status.
	@sudo launchctl list | grep kompletekontrol || echo "Daemon not running or not installed."

daemon-start: ## Start daemon via launchctl.
	@sudo launchctl load /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-stop: ## Stop daemon via launchctl.
	@sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-restart: ## Restart daemon via launchctl.
	@sudo launchctl kickstart -k system/media.vanille.kompletekontrol-libusb

run: build ## Run KontrolProbe (daemon-client mode).
	$(PROBE)

kk-ui: build ## Run the KontrolProbe S25 photo-overlay test UI.
	$(PROBE) --test-ui

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop any foreground KK libusb daemon process.
	-sudo pkill -f -- '--kk-libusb-daemon' 2>/dev/null || true

kk-clean-socket: ## Remove the daemon socket.
	-sudo rm -f $(SOCKET)

kk-status: ## Show running SidStudio/KontrolProbe KK processes.
	@pgrep -fl 'SidStudio|KontrolProbe|--kk-libusb-daemon' || true
