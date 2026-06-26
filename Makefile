.DEFAULT_GOAL := help

SOCKET ?= /var/run/kompletekontrol-libusb.sock
DAEMON := .build/debug/ccd
DAEMON_RELEASE := .build/release/ccd
PROBE := .build/debug/KontrolProbe
PROBE_RELEASE := .build/release/KontrolProbe
SURFACE_DEMO := .build/debug/SurfaceDemo
SURFACE_DEMO_RELEASE := .build/release/SurfaceDemo

.PHONY: help build build-release surface surface-release SurfaceDemo daemon-build daemon-build-release probe-build probe-build-release daemon-preflight daemon-debug daemon-release install-daemon install-debug-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart run run-release probe-run probe-run-release probe-ui kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk 'BEGIN { printf "KompleteKontrol-Swift developer targets\n\nUsage:\n  make <target>\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-24s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

build: ## Build the middleware SurfaceDemo.
	swift build --product SurfaceDemo

build-release: ## Build optimized middleware SurfaceDemo.
	swift build -c release --product SurfaceDemo

SurfaceDemo: build ## Build the middleware SurfaceDemo product.

surface: run ## Run the middleware SurfaceDemo.

surface-release: run-release ## Run optimized middleware SurfaceDemo.

daemon-build: ## Build the CompleteControl daemon.
	swift build -c debug --product ccd

daemon-build-release: ## Build optimized CompleteControl daemon.
	swift build -c release --product ccd

probe-build: ## Build the old KontrolProbe baseline.
	swift build --product KontrolProbe

probe-build-release: ## Build optimized old KontrolProbe baseline.
	swift build -c release --product KontrolProbe

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
			/usr/local/bin/ccd" "--kk-libusb-daemon*|/usr/local/bin/ccd" "--libusb-daemon*) ;; \
			/usr/local/bin/KontrolProbe" "--kk-libusb-daemon*|/usr/local/bin/KontrolProbe" "--libusb-daemon*) ;; \
			*"/.build/debug/ccd "--kk-libusb-daemon*|*"/.build/debug/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/release/ccd "--kk-libusb-daemon*|*"/.build/release/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/debug/KontrolProbe "--kk-libusb-daemon*|*"/.build/debug/KontrolProbe "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/release/KontrolProbe "--kk-libusb-daemon*|*"/.build/release/KontrolProbe "--libusb-daemon*) foreground_daemon=1 ;; \
			*) \
				echo "Refusing to run: unexpected KompleteKontrol daemon is active:" >&2; \
				ps -o pid,user,command -p "$$pid" >&2; \
				echo "Run: make install-daemon" >&2; \
				exit 1; \
				;; \
		esac; \
	done; \
	daemon_path="$${DAEMON_PREFLIGHT:-$(DAEMON)}"; \
	if [ "$${CHECK_DAEMON_BINARY:-1}" != 0 ] && [ "$$foreground_daemon" -ne 1 ] && [ -x /usr/local/bin/ccd ] && [ -x "$$daemon_path" ] && ! cmp -s "$$daemon_path" /usr/local/bin/ccd; then \
		echo "Refusing to run: /usr/local/bin/ccd is stale." >&2; \
		echo "Run: make install-daemon" >&2; \
		exit 1; \
	fi

daemon-debug: daemon-build ## Stop launchd daemon and run foreground daemon with structured stderr tracing.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon with structured stderr tracing. Press Ctrl-C to stop."
	sudo env KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon-release: daemon-build-release ## Stop launchd daemon and run quiet optimized foreground daemon.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting quiet optimized foreground daemon. Press Ctrl-C to stop."
	@sudo "$$(pwd)/$(DAEMON_RELEASE)" --kk-libusb-daemon "$(SOCKET)"

install-daemon: daemon-build-release ## Install optimized daemon as launchd service (requires sudo).
	sudo env KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON_RELEASE)" KK_INSTALL_DAEMON_CONFIGURATION=release ./install-daemon.sh

install-debug-daemon: daemon-build ## Install daemon as launchd service with trace logging enabled.
	sudo env KK_INSTALL_DEBUG_DAEMON=1 KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON)" KK_INSTALL_DAEMON_CONFIGURATION=debug ./install-daemon.sh

uninstall-daemon: ## Uninstall daemon launchd service (requires sudo).
	@echo "Stopping and removing daemon service..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo rm -f /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist
	-sudo rm -f /usr/local/bin/ccd
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

run: build daemon-build probe-build ## Run the middleware SurfaceDemo.
	@$(MAKE) daemon-preflight
	$(SURFACE_DEMO)

run-release: build-release daemon-build-release probe-build-release ## Run optimized middleware SurfaceDemo.
	@$(MAKE) daemon-preflight DAEMON_PREFLIGHT="$(DAEMON_RELEASE)"
	$(SURFACE_DEMO_RELEASE)

probe-run: daemon-build probe-build daemon-preflight ## Run the old KontrolProbe REPL baseline.
	$(PROBE)

probe-run-release: daemon-build-release probe-build-release ## Run optimized old KontrolProbe for benchmarks.
	@$(MAKE) daemon-preflight DAEMON_PREFLIGHT="$(DAEMON_RELEASE)"
	$(PROBE_RELEASE)

probe-ui: probe-build ## Run the old KontrolProbe S25 photo-overlay test UI.
	$(PROBE) --test-ui

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop any foreground KK libusb daemon process.
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true

kk-clean-socket: ## Remove the daemon socket.
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock

kk-status: ## Show running SidStudio/KontrolProbe KK processes.
	@pgrep -fl 'SidStudio|KontrolProbe|ccd|--kk-libusb-daemon' || true
