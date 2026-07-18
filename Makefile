.DEFAULT_GOAL := help

SOCKET ?= /var/run/kompletekontrol-libusb.sock
MK2_DISPLAY_ENCODING ?= adaptive
ifeq ($(MK2_DISPLAY_ENCODING),legacy)
else ifeq ($(MK2_DISPLAY_ENCODING),adaptive)
else
$(warning Invalid MK2_DISPLAY_ENCODING='$(MK2_DISPLAY_ENCODING)'; using legacy)
override MK2_DISPLAY_ENCODING := legacy
endif
DAEMON := .build/debug/ccd
DAEMON_RELEASE := .build/release/ccd
MK2_SURFACE_DEMO := .build/debug/MK2SurfaceDemo
MK2_SURFACE_DEMO_RELEASE := .build/release/MK2SurfaceDemo
MK2_WIDGET_LAB_DEMO := .build/debug/MK2WidgetLabDemo
MK2_WIDGET_LAB_DEMO_RELEASE := .build/release/MK2WidgetLabDemo
MK2_USB_SPY := .build/debug/MK2USBSpy
MK2_USB_SPY_SECONDS ?= 0
MK2_USB_SPY_PID ?=
MK2_USB_SPY_ARGS = $(if $(MK2_USB_SPY_PID),--pid $(MK2_USB_SPY_PID),) $(if $(filter-out 0,$(MK2_USB_SPY_SECONDS)),--seconds $(MK2_USB_SPY_SECONDS),)
MASCHINE_MK3_INPUT_SPY_SECONDS ?= 10
WIDGETLAB_TEST_SOCKET ?= /tmp/kontrol-simulator-daemon.sock
WIDGETLAB_STRESS_DURATION ?= 15m
WIDGETLAB_SOAK_DURATION ?= 8h
WIDGETLAB_TEST_ARGS ?=
ADAPTIVE_REPORT ?=
LEGACY_REPORT ?=

.PHONY: help vendor-init clean build build-release display-codec-benchmark mk2-surface-demo-build mk2-surface-demo-build-release mk2-surface-demo mk2-surface-demo-release mk2-widget-lab-demo-build mk2-widget-lab-demo-build-release mk2-widget-lab-demo mk2-widget-lab-demo-sim mk2-widget-lab-demo-release mk2-widget-lab-test-validate mk2-widget-lab-smoke mk2-widget-lab-stress mk2-widget-lab-soak mk2-widget-lab-compare daemon-build daemon-build-release mk2-usb-spy-build mk2-usb-spy mk2-usb-spy-display-repl maschine-mk3-probe maschine-mk3-input-spy daemon-preflight daemon daemon-debug daemon-release run-simulator daemon-simulate install-daemon install-debug-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart kk-input kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk -v encoding="$(MK2_DISPLAY_ENCODING)" -v testSocket="$(WIDGETLAB_TEST_SOCKET)" -v stress="$(WIDGETLAB_STRESS_DURATION)" -v soak="$(WIDGETLAB_SOAK_DURATION)" 'BEGIN { printf "CompleteControl developer targets\n\nUsage:\n  make <target>\n\nConfiguration:\n  MK2_DISPLAY_ENCODING=%s  adaptive (default) or legacy (fail-safe)\n  WIDGETLAB_TEST_SOCKET=%s\n  WIDGETLAB_STRESS_DURATION=%s  WIDGETLAB_SOAK_DURATION=%s\n  WIDGETLAB_TEST_ARGS=...  additional kk-widgetlab-test options\n\nTargets:\n", encoding, testSocket, stress, soak } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-24s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

vendor-init: ## Initialize pinned vendored dependencies.
	git submodule update --init --recursive Vendor/libusb

clean: ## Remove SwiftPM build artifacts.
	swift package clean

build: vendor-init ## Build all MK2 libraries and tools.
	swift build

build-release: vendor-init ## Build all MK2 libraries and tools optimized.
	swift build -c release

display-codec-benchmark: ## Run the deterministic adaptive display-codec cost replay.
	swift test -c release --filter MK2DisplayPacketCodecTests.representativeCostReport

mk2-surface-demo-build: vendor-init ## Build the MK2 hardware-only SurfaceKit2 feature demo.
	swift build --product MK2SurfaceDemo

mk2-surface-demo-build-release: vendor-init ## Build optimized MK2 hardware-only SurfaceKit2 feature demo.
	swift build -c release --product MK2SurfaceDemo

mk2-widget-lab-demo-build: vendor-init ## Build the MK2 Widget Lab demo.
	swift build --product MK2WidgetLabDemo

mk2-widget-lab-demo-build-release: vendor-init ## Build optimized MK2 Widget Lab demo.
	swift build -c release --product MK2WidgetLabDemo

daemon-build: vendor-init ## Build the CompleteControl daemon.
	swift build -c debug --product ccd

daemon-build-release: vendor-init ## Build optimized CompleteControl daemon.
	swift build -c release --product ccd

mk2-usb-spy-build: vendor-init ## Build the MK2 low-level USB descriptor/input spy.
	swift build --product MK2USBSpy

mk2-usb-spy: mk2-usb-spy-build ## Stop daemon and run MK2 USB descriptor/input spy (requires sudo).
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting MK2 USB spy. Press Ctrl-C to stop."
	sudo "$$(pwd)/$(MK2_USB_SPY)" $(MK2_USB_SPY_ARGS)

mk2-usb-spy-display-repl: MK2_USB_SPY_ARGS += --display-repl
mk2-usb-spy-display-repl: mk2-usb-spy ## Stop daemon and run the interactive MK2 display-command verifier.

maschine-mk3-probe: mk2-usb-spy-build ## Print read-only MASCHINE MK3 USB descriptors without claiming interfaces.
	"$$(pwd)/$(MK2_USB_SPY)" --pid 0x1600 --describe

maschine-mk3-input-spy: MK2_USB_SPY_PID = 0x1600
maschine-mk3-input-spy: MK2_USB_SPY_SECONDS = $(MASCHINE_MK3_INPUT_SPY_SECONDS)
maschine-mk3-input-spy: MK2_USB_SPY_ARGS += --interfaces 4
maschine-mk3-input-spy: mk2-usb-spy ## Capture only the MASCHINE MK3 HID interface 4 (requires sudo).

daemon-preflight: ## Refuse stale or duplicate daemon state (queries the installed daemon's embedded revision; no local build needed). Caveat: two dirty builds of the same commit compare equal.
	@simulator_socket="/tmp/kontrol-simulator-daemon.sock"; \
	target_socket="$${KK_DAEMON_SOCKET:-$(SOCKET)}"; \
	simulator_pids="$$(ps -axo pid=,command= | awk '/--kk-libusb-daemon|--libusb-daemon/ { if (index($$0, "kontrol-simulator-daemon.sock") == 0) next; command = $$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); split(command, argv, /[[:space:]]+/); n = split(argv[1], path, "/"); executable = path[n]; if (executable != "sudo" && executable != "sh" && executable != "zsh" && executable != "bash" && executable != "make" && executable != "awk" && executable != "env") print $$1 }')"; \
	simulator_count="$$(printf '%s\n' "$$simulator_pids" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	pids="$$(ps -axo pid=,command= | awk '/--kk-libusb-daemon|--libusb-daemon/ { if (index($$0, "kontrol-simulator-daemon.sock") > 0) next; command = $$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); split(command, argv, /[[:space:]]+/); n = split(argv[1], path, "/"); executable = path[n]; if (executable != "sudo" && executable != "sh" && executable != "zsh" && executable != "bash" && executable != "make" && executable != "awk" && executable != "env") print $$1 }')"; \
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
			*"/.build/debug/ccd "--kk-libusb-daemon*|*"/.build/debug/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/release/ccd "--kk-libusb-daemon*|*"/.build/release/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*) \
				echo "Refusing to run: unexpected KompleteKontrol daemon is active:" >&2; \
				ps -o pid,user,command -p "$$pid" >&2; \
				echo "Run: make install-daemon" >&2; \
				exit 1; \
				;; \
		esac; \
	done; \
	uses_simulator_daemon=0; \
	if [ "$$target_socket" = "$$simulator_socket" ] || { [ "$$count" -eq 0 ] && [ "$$simulator_count" -gt 0 ]; }; then \
		uses_simulator_daemon=1; \
	fi; \
	if [ "$${CHECK_DAEMON_BINARY:-1}" != 0 ] && [ "$$foreground_daemon" -ne 1 ] && [ "$$uses_simulator_daemon" -ne 1 ] && [ -x /usr/local/bin/ccd ]; then \
		installed_rev="$$(/usr/local/bin/ccd --revision 2>/dev/null || true)"; \
		workspace_count="$$(git rev-list --count HEAD 2>/dev/null || printf '0')"; \
		if ! git diff --quiet HEAD -- 2>/dev/null; then workspace_count="$$workspace_count+"; fi; \
		workspace_rev="$$workspace_count $$(git rev-parse --short HEAD 2>/dev/null || printf 'NO GIT')"; \
		if [ -z "$$installed_rev" ]; then \
			echo "Refusing to run: /usr/local/bin/ccd predates the --revision flag." >&2; \
			echo "Run: make install-daemon" >&2; \
			exit 1; \
		fi; \
		if [ "$$installed_rev" != "$$workspace_rev" ]; then \
			echo "Refusing to run: /usr/local/bin/ccd is stale (installed $$installed_rev, workspace $$workspace_rev)." >&2; \
			echo "Run: make install-daemon" >&2; \
			exit 1; \
		fi; \
	fi

daemon-debug: daemon-build ## Stop launchd daemon and run foreground daemon with structured stderr tracing.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon with structured stderr tracing. Press Ctrl-C to stop."
	@echo "MK2 display encoding: $(MK2_DISPLAY_ENCODING)"
	sudo env KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon: daemon-build-release ## Stop launchd daemon and run quiet optimized foreground daemon.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting quiet optimized foreground daemon. Press Ctrl-C to stop."
	@echo "MK2 display encoding: $(MK2_DISPLAY_ENCODING)"
	@sudo env KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) "$$(pwd)/$(DAEMON_RELEASE)" --kk-libusb-daemon "$(SOCKET)"

SIM_SOCKET := /tmp/kontrol-simulator.sock

run-simulator: daemon-build ## Build and run the KontrolSimulator panel app (virtual MK2 for hardware-free testing).
	swift build --product KontrolSimulator
	@echo "Launching the simulator window. The built-in Daemon menu will use the freshly built debug ccd."
	KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) .build/debug/KontrolSimulator

daemon-simulate: daemon-build ## Stop launchd daemon and run the foreground daemon in simulation mode (needs run-simulator).
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon in SIMULATION mode (device = $(SIM_SOCKET)). Launch 'make run-simulator' first. Ctrl-C to stop."
	sudo env KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) CCD_SIMULATE=$(SIM_SOCKET) KK_DAEMON_DEBUG=1 LOGLEVEL=INFO "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon-release: daemon ## Alias for daemon.

install-daemon: daemon-build-release ## Install optimized daemon as launchd service (requires sudo).
	sudo env KK_INSTALL_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON_RELEASE)" KK_INSTALL_DAEMON_CONFIGURATION=release ./install-daemon.sh

install-debug-daemon: daemon-build ## Install daemon as launchd service with trace logging enabled.
	sudo env KK_INSTALL_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) KK_INSTALL_DEBUG_DAEMON=1 KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON)" KK_INSTALL_DAEMON_CONFIGURATION=debug ./install-daemon.sh

uninstall-daemon: ## Uninstall daemon launchd service (requires sudo).
	@echo "Stopping and removing daemon service..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo rm -f /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist
	-sudo rm -f /usr/local/bin/ccd
	-sudo rm -rf /usr/local/bin/CompleteControl_KompleteKontrol.bundle
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	-sudo rm -f /tmp/media.vanille.kompletekontrol-libusb.stdout.log /tmp/media.vanille.kompletekontrol-libusb.stderr.log
	@echo "Daemon service uninstalled."

daemon-status: ## Show daemon status.
	@sudo launchctl list | grep kompletekontrol || echo "Daemon not running or not installed."
	@mode="$$(sudo /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:KK_MK2_DISPLAY_ENCODING' /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true)"; \
	if [ -n "$$mode" ]; then echo "MK2 display encoding: $$mode"; else echo "MK2 display encoding: adaptive (default)"; fi

daemon-start: ## Start daemon via launchctl.
	@sudo launchctl bootstrap system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-stop: ## Stop daemon via launchctl.
	@sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-restart: ## Restart daemon via launchctl.
	@sudo launchctl kickstart -k system/media.vanille.kompletekontrol-libusb

mk2-surface-demo: mk2-surface-demo-build ## Run the MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO)

mk2-surface-demo-release: mk2-surface-demo-build-release ## Run optimized MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO_RELEASE)

mk2-widget-lab-demo: mk2-widget-lab-demo-build ## Run the MK2 Widget Lab demo.
	@$(MAKE) daemon-preflight
	$(MK2_WIDGET_LAB_DEMO)

mk2-widget-lab-demo-sim: mk2-widget-lab-demo-build ## Run the MK2 Widget Lab demo against the simulator daemon (start it from the KontrolSimulator Daemon menu; no sudo).
	KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock $(MK2_WIDGET_LAB_DEMO)

mk2-widget-lab-demo-release: mk2-widget-lab-demo-build-release ## Run optimized MK2 Widget Lab demo.
	@$(MAKE) daemon-preflight
	$(MK2_WIDGET_LAB_DEMO_RELEASE)

mk2-widget-lab-test-validate: mk2-widget-lab-demo-build ## Validate that every Widget Lab demo has a smoke scenario.
	Scripts/kk-widgetlab-test.py validate

mk2-widget-lab-smoke: mk2-widget-lab-demo-build ## Run the complete Widget Lab smoke suite against the simulator daemon.
	Scripts/kk-widgetlab-test.py smoke --socket $(WIDGETLAB_TEST_SOCKET) $(WIDGETLAB_TEST_ARGS)

mk2-widget-lab-stress: mk2-widget-lab-demo-build ## Stress every Widget Lab demo (default: 15m; override WIDGETLAB_STRESS_DURATION).
	Scripts/kk-widgetlab-test.py stress --socket $(WIDGETLAB_TEST_SOCKET) --duration $(WIDGETLAB_STRESS_DURATION) $(WIDGETLAB_TEST_ARGS)

mk2-widget-lab-soak: mk2-widget-lab-demo-build ## Soak every Widget Lab demo (default: 8h; override WIDGETLAB_SOAK_DURATION).
	Scripts/kk-widgetlab-test.py soak --socket $(WIDGETLAB_TEST_SOCKET) --duration $(WIDGETLAB_SOAK_DURATION) $(WIDGETLAB_TEST_ARGS)

mk2-widget-lab-compare: ## Compare adaptive and legacy reports (set ADAPTIVE_REPORT and LEGACY_REPORT).
	@test -n "$(ADAPTIVE_REPORT)" -a -n "$(LEGACY_REPORT)" || { echo "Set ADAPTIVE_REPORT and LEGACY_REPORT to report.json paths." >&2; exit 2; }
	Scripts/kk-widgetlab-test.py compare --adaptive-report "$(ADAPTIVE_REPORT)" --legacy-report "$(LEGACY_REPORT)"

kk-input: ## Open the interactive automation-input REPL with automatic socket discovery.
	Scripts/kk-input.py

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop any foreground KK libusb daemon process.
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true

kk-clean-socket: ## Remove the daemon socket.
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock

kk-status: ## Show running CompleteControl daemon processes.
	@pgrep -fl 'ccd|--kk-libusb-daemon' || true
