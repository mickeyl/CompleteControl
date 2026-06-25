.DEFAULT_GOAL := help

SOCKET ?= /var/run/kompletekontrol-libusb.sock
PROBE := .build/debug/KontrolProbe

.PHONY: help build daemon-preflight daemon-debug install-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart run kk-ui kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk 'BEGIN { printf "KompleteKontrol-Swift developer targets\n\nUsage:\n  make <target>\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-18s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

build: ## Build KontrolProbe.
	swift build --product KontrolProbe

daemon-preflight: ## Refuse stale or duplicate daemon state.
	@pids="$$(ps -axo pid=,command= | awk '/--kk-libusb-daemon|--libusb-daemon/ { command = $$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); split(command, argv, /[[:space:]]+/); n = split(argv[1], path, "/"); executable = path[n]; if (executable != "sudo" && executable != "sh" && executable != "zsh" && executable != "bash" && executable != "make" && executable != "awk" && executable != "env") print $$1 }')"; \
	count="$$(printf '%s\n' "$$pids" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	if [ "$$count" -gt 1 ]; then \
		echo "Refusing to run: multiple KompleteKontrol daemons are active:" >&2; \
		for pid in $$pids; do ps -o pid,user,command -p "$$pid" >&2; done; \
		echo "Run: make install-daemon" >&2; \
		exit 1; \
	fi; \
	foreground_daemon=0; \
	for pid in $$pids; do \
		command="$$(ps -o command= -p "$$pid")"; \
		case "$$command" in \
			/usr/local/bin/KontrolProbe" "--kk-libusb-daemon*|/usr/local/bin/KontrolProbe" "--libusb-daemon*) ;; \
			*"/.build/debug/KontrolProbe "--kk-libusb-daemon*|*"/.build/debug/KontrolProbe "--libusb-daemon*) foreground_daemon=1 ;; \
			*) \
				echo "Refusing to run: unexpected KompleteKontrol daemon is active:" >&2; \
				ps -o pid,user,command -p "$$pid" >&2; \
				echo "Run: make install-daemon" >&2; \
				exit 1; \
				;; \
		esac; \
	done; \
	if [ "$$foreground_daemon" -ne 1 ] && [ -x /usr/local/bin/KontrolProbe ] && [ -x "$(PROBE)" ] && ! cmp -s "$(PROBE)" /usr/local/bin/KontrolProbe; then \
		echo "Refusing to run: /usr/local/bin/KontrolProbe is stale." >&2; \
		echo "Run: make install-daemon" >&2; \
		exit 1; \
	fi

daemon-debug: build ## Stop launchd daemon and run foreground daemon with structured stderr tracing.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon with structured stderr tracing. Press Ctrl-C to stop."
	sudo env KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE "$$(pwd)/$(PROBE)" --kk-libusb-daemon "$(SOCKET)"

install-daemon: build ## Install daemon as launchd service (requires sudo, one-time setup).
	sudo ./install-daemon.sh

uninstall-daemon: ## Uninstall daemon launchd service (requires sudo).
	@echo "Stopping and removing daemon service..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo rm -f /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist
	-sudo rm -f /usr/local/bin/KontrolProbe
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Daemon service uninstalled."

daemon-status: ## Show daemon status.
	@sudo launchctl list | grep kompletekontrol || echo "Daemon not running or not installed."

daemon-start: ## Start daemon via launchctl.
	@sudo launchctl bootstrap system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-stop: ## Stop daemon via launchctl.
	@sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-restart: ## Restart daemon via launchctl.
	@sudo launchctl kickstart -k system/media.vanille.kompletekontrol-libusb

run: build daemon-preflight ## Run KontrolProbe (daemon-client mode).
	$(PROBE)

kk-ui: build ## Run the KontrolProbe S25 photo-overlay test UI.
	$(PROBE) --test-ui

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop any foreground KK libusb daemon process.
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true

kk-clean-socket: ## Remove the daemon socket.
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock

kk-status: ## Show running SidStudio/KontrolProbe KK processes.
	@pgrep -fl 'SidStudio|KontrolProbe|--kk-libusb-daemon' || true
