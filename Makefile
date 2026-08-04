.DEFAULT_GOAL := help

KONTROL_SOCKET := /var/run/kompletekontrol-libusb.sock
MASCHINE_SOCKET := /var/run/kompletekontrol-maschine.sock
KONTROL_LABEL := media.vanille.kompletekontrol-libusb
MASCHINE_LABEL := media.vanille.kompletekontrol-maschine

# DEVICE selects which product-bound daemon a target addresses:
#   DEVICE=kontrol | DEVICE=maschine — that daemon only
#   DEVICE unset — lifecycle targets (daemon-start/stop/restart/status,
#   kk-stop, kk-clean-socket, kk-reset) address BOTH daemons; the
#   single-process foreground targets (daemon, daemon-debug,
#   daemon-debug-trace, daemon-simulate) take over only the KONTROL endpoint
#   and bind no product (historical behavior). With DEVICE set they derive
#   socket and --product automatically, e.g. make daemon-debug DEVICE=maschine.
DEVICE ?=
ifeq ($(DEVICE),maschine)
SOCKET ?= $(MASCHINE_SOCKET)
DAEMON_PRODUCT ?= maschine-mk3
else ifeq ($(DEVICE),kontrol)
SOCKET ?= $(KONTROL_SOCKET)
DAEMON_PRODUCT ?= kontrol-mk2
else ifeq ($(DEVICE),)
SOCKET ?= $(KONTROL_SOCKET)
DAEMON_PRODUCT ?=
else
$(error Invalid DEVICE='$(DEVICE)'; use kontrol or maschine)
endif
SOCKET_LOCK = $(SOCKET:.sock=.lock)
DAEMON_PRODUCT_ARGS = $(if $(DAEMON_PRODUCT),--product $(DAEMON_PRODUCT),)
# The launchd label that owns the selected socket, so the foreground takeover
# targets never touch the other product-bound daemon.
LAUNCHD_LABEL = $(if $(filter $(SOCKET),$(MASCHINE_SOCKET)),$(MASCHINE_LABEL),$(KONTROL_LABEL))
# Labels and sockets the lifecycle targets iterate: the selected device, or
# both when DEVICE is unset.
LIFECYCLE_LABELS = $(if $(filter maschine,$(DEVICE)),$(MASCHINE_LABEL),$(if $(filter kontrol,$(DEVICE)),$(KONTROL_LABEL),$(KONTROL_LABEL) $(MASCHINE_LABEL)))
LIFECYCLE_SOCKETS = $(if $(filter maschine,$(DEVICE)),$(MASCHINE_SOCKET),$(if $(filter kontrol,$(DEVICE)),$(KONTROL_SOCKET),$(KONTROL_SOCKET) $(MASCHINE_SOCKET)))
MK2_DISPLAY_ENCODING ?= adaptive
ifeq ($(MK2_DISPLAY_ENCODING),legacy)
else ifeq ($(MK2_DISPLAY_ENCODING),adaptive)
else
$(warning Invalid MK2_DISPLAY_ENCODING='$(MK2_DISPLAY_ENCODING)'; using legacy)
override MK2_DISPLAY_ENCODING := legacy
endif
DAEMON := .build/debug/ccd
DAEMON_RELEASE := .build/release/ccd
DAEMON_TRACE_LOG ?= /tmp/ccd-trace.log
DAEMON_RING_KEEP ?= 30
DAEMON_LOG_RING_ENV =
MK2_SURFACE_DEMO := .build/debug/MK2SurfaceDemo
MK2_SURFACE_DEMO_RELEASE := .build/release/MK2SurfaceDemo
WIDGET_LAB := .build/debug/widget-lab
WIDGET_LAB_RELEASE := .build/release/widget-lab
MK2_USB_SPY := .build/debug/MK2USBSpy
MK2_USB_SPY_SECONDS ?= 0
MK2_USB_SPY_PID ?=
MK2_USB_SPY_ARGS = $(if $(MK2_USB_SPY_PID),--pid $(MK2_USB_SPY_PID),) $(if $(filter-out 0,$(MK2_USB_SPY_SECONDS)),--seconds $(MK2_USB_SPY_SECONDS),)
MASCHINE_MK3_INPUT_SPY_SECONDS ?= 10
WIDGET_LAB_TEST_SOCKET ?= /tmp/kontrol-simulator-daemon.sock
WIDGET_LAB_STRESS_DURATION ?= 15m
WIDGET_LAB_SOAK_DURATION ?= 8h
WIDGET_LAB_TEST_ARGS ?=
ADAPTIVE_REPORT ?=
LEGACY_REPORT ?=

.PHONY: help vendor-init clean build build-release display-codec-benchmark mk2-surface-demo-build mk2-surface-demo-build-release mk2-surface-demo mk2-surface-demo-release widget-lab-build widget-lab-build-release widget-lab widget-lab-sim widget-lab-release widget-lab-test-validate widget-lab-smoke widget-lab-stress widget-lab-soak widget-lab-compare daemon-build daemon-build-release mk2-usb-spy-build mk2-usb-spy mk2-usb-spy-display-repl maschine-mk3-probe maschine-mk3-input-spy daemon-preflight daemon daemon-debug daemon-debug-trace daemon-release run-simulator run-mk3-simulator sim-host-build sim-host daemon-simulate install-daemon install-debug-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart kk-input kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk -v encoding="$(MK2_DISPLAY_ENCODING)" -v traceLog="$(DAEMON_TRACE_LOG)" -v testSocket="$(WIDGET_LAB_TEST_SOCKET)" -v stress="$(WIDGET_LAB_STRESS_DURATION)" -v soak="$(WIDGET_LAB_SOAK_DURATION)" 'BEGIN { printf "CompleteControl developer targets\n\nUsage:\n  make <target>\n\nConfiguration:\n  DEVICE=kontrol|maschine  narrow daemon targets to one product-bound daemon\n                           (lifecycle targets default to both; foreground\n                           targets default to the KONTROL endpoint)\n  MK2_DISPLAY_ENCODING=%s  adaptive (default) or legacy (fail-safe)\n  DAEMON_TRACE_LOG=%s\n  WIDGET_LAB_TEST_SOCKET=%s\n  WIDGET_LAB_STRESS_DURATION=%s  WIDGET_LAB_SOAK_DURATION=%s\n  WIDGET_LAB_TEST_ARGS=...  additional widget-lab-test options\n\nTargets:\n", encoding, traceLog, testSocket, stress, soak } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-24s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

vendor-init: ## Initialize pinned vendored dependencies.
	git submodule update --init --recursive Vendor/libusb

clean: ## Remove SwiftPM build artifacts.
	swift package clean

build: vendor-init ## Build all CompleteControl libraries and tools.
	swift build

build-release: vendor-init ## Build all CompleteControl libraries and tools optimized.
	swift build -c release

display-codec-benchmark: ## Run the deterministic adaptive display-codec cost replay.
	swift test -c release --filter MK2DisplayPacketCodecTests.representativeCostReport

mk2-surface-demo-build: vendor-init ## Build the MK2 hardware-only SurfaceKit2 feature demo.
	swift build --product MK2SurfaceDemo

mk2-surface-demo-build-release: vendor-init ## Build optimized MK2 hardware-only SurfaceKit2 feature demo.
	swift build -c release --product MK2SurfaceDemo

widget-lab-build: vendor-init ## Build the device-independent Widget Lab.
	swift build --product widget-lab

widget-lab-build-release: vendor-init ## Build the optimized device-independent Widget Lab.
	swift build -c release --product widget-lab

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
	pids="$$(ps -axo pid=,command= | awk -v sock="$$target_socket" '/--kk-libusb-daemon|--libusb-daemon/ { if (index($$0, "kontrol-simulator-daemon.sock") > 0) next; if (index($$0, sock) == 0) next; command = $$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); split(command, argv, /[[:space:]]+/); n = split(argv[1], path, "/"); executable = path[n]; if (executable != "sudo" && executable != "sh" && executable != "zsh" && executable != "bash" && executable != "make" && executable != "awk" && executable != "env") print $$1 }')"; \
	count="$$(printf '%s\n' "$$pids" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	if [ "$$count" -gt 1 ]; then \
		echo "Refusing to run: multiple KompleteKontrol daemons own $$target_socket:" >&2; \
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

daemon-debug: daemon-build ## Run one foreground debug daemon with tracing and automation input (endpoint via DEVICE=kontrol|maschine).
	@echo "Stopping the daemon that owns $(SOCKET)..."
	-sudo launchctl bootout system /Library/LaunchDaemons/$(LAUNCHD_LABEL).plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon $(SOCKET)' 2>/dev/null || true
	-sudo rm -f $(SOCKET) $(SOCKET_LOCK)
	@echo "Starting foreground daemon with structured stderr tracing. Press Ctrl-C to stop."
	@echo "MK2 display encoding: $(MK2_DISPLAY_ENCODING)"
	sudo env $(DAEMON_LOG_RING_ENV) KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) CCD_ENABLE_AUTOMATION=1 KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)" $(DAEMON_PRODUCT_ARGS)

daemon-debug-trace: ## Run the debug daemon as a flight recorder: trace output buffers in RAM; flush the last DAEMON_RING_KEEP seconds into DAEMON_TRACE_LOG via SIGUSR1 (DAEMON_RING_KEEP=0: live logging).
	@rm -f "$(DAEMON_TRACE_LOG)"
	@if [ "$(DAEMON_RING_KEEP)" = "0" ]; then \
		echo "Starting traced foreground daemon; output is written only to $(DAEMON_TRACE_LOG). Press Ctrl-C to stop."; \
	else \
		echo "Starting traced foreground daemon as flight recorder (last $(DAEMON_RING_KEEP)s buffer in RAM, no log I/O)."; \
		echo "Flush into $(DAEMON_TRACE_LOG) with:  sudo pkill -USR1 -f kk-libusb-daemon"; \
		echo "An error-level line flushes automatically. Press Ctrl-C to stop."; \
	fi
	@$(MAKE) --no-print-directory daemon-debug DAEMON_LOG_RING_ENV="KK_LOG_RING=$(DAEMON_RING_KEEP)" >"$(DAEMON_TRACE_LOG)" 2>&1

daemon: daemon-build-release ## Stop one launchd daemon and run the quiet optimized foreground daemon in its place (DEVICE=kontrol|maschine).
	@echo "Stopping the daemon that owns $(SOCKET)..."
	-sudo launchctl bootout system /Library/LaunchDaemons/$(LAUNCHD_LABEL).plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon $(SOCKET)' 2>/dev/null || true
	-sudo rm -f $(SOCKET) $(SOCKET_LOCK)
	@echo "Starting quiet optimized foreground daemon. Press Ctrl-C to stop."
	@echo "MK2 display encoding: $(MK2_DISPLAY_ENCODING)"
	@sudo env KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) "$$(pwd)/$(DAEMON_RELEASE)" --kk-libusb-daemon "$(SOCKET)" $(DAEMON_PRODUCT_ARGS)

SIM_SOCKET := /tmp/kontrol-simulator.sock

run-simulator: daemon-build ## Build and run the KontrolSimulator panel app (virtual MK2 for hardware-free testing).
	swift build --product KontrolSimulator
	@echo "Launching the simulator window. The built-in Daemon menu will use the freshly built debug ccd."
	KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) .build/debug/KontrolSimulator

run-mk3-simulator: daemon-build ## Build and run the MASCHINE MK3 simulator (single simulated device).
	swift build --product KontrolSimulator
	@echo "Launching MASCHINE MK3. Start its user-level ccd from the Daemon menu."
	KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) .build/debug/KontrolSimulator --device maschine-mk3

sim-host-build: daemon-build ## Build the headless simulator host and its ccd.
	swift build --product kontrol-sim-host

sim-host: sim-host-build ## Build and run the headless simulator host (MK3, own daemon, automation socket).
	.build/debug/kontrol-sim-host --device maschine-mk3 --automation

daemon-simulate: daemon-build ## Stop launchd daemon and run the foreground daemon in simulation mode (needs run-simulator).
	@echo "Stopping the daemon that owns $(SOCKET)..."
	-sudo launchctl bootout system /Library/LaunchDaemons/$(LAUNCHD_LABEL).plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon $(SOCKET)' 2>/dev/null || true
	-sudo rm -f $(SOCKET) $(SOCKET_LOCK)
	@echo "Starting foreground daemon in SIMULATION mode (device = $(SIM_SOCKET)). Launch 'make run-simulator' first. Ctrl-C to stop."
	sudo env KK_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) CCD_SIMULATE=$(SIM_SOCKET) KK_DAEMON_DEBUG=1 LOGLEVEL=INFO "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon-release: daemon ## Alias for daemon.

install-daemon: daemon-build-release ## Install optimized daemon as launchd service (requires sudo).
	sudo env KK_INSTALL_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON_RELEASE)" KK_INSTALL_DAEMON_CONFIGURATION=release ./install-daemon.sh

install-debug-daemon: daemon-build ## Install debug daemon with tracing and automation input enabled.
	sudo env KK_INSTALL_MK2_DISPLAY_ENCODING=$(MK2_DISPLAY_ENCODING) KK_INSTALL_DEBUG_DAEMON=1 CCD_ENABLE_AUTOMATION=1 KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON)" KK_INSTALL_DAEMON_CONFIGURATION=debug ./install-daemon.sh

uninstall-daemon: ## Uninstall both daemon launchd services (requires sudo).
	@echo "Stopping and removing daemon services..."
	@for label in media.vanille.kompletekontrol-libusb media.vanille.kompletekontrol-maschine; do \
		sudo launchctl bootout system /Library/LaunchDaemons/$$label.plist 2>/dev/null || true; \
		sudo launchctl unload /Library/LaunchDaemons/$$label.plist 2>/dev/null || true; \
		sudo rm -f /Library/LaunchDaemons/$$label.plist; \
		sudo rm -f /tmp/$$label.stdout.log /tmp/$$label.stderr.log; \
	done
	-sudo rm -f /usr/local/bin/ccd
	-sudo rm -rf /usr/local/bin/CompleteControl_KompleteKontrol.bundle
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) $(SOCKET_LOCK) $(MASCHINE_SOCKET) $(MASCHINE_SOCKET:.sock=.lock)
	@echo "Daemon services uninstalled."

daemon-status: ## Show status of both daemons (narrow with DEVICE=kontrol|maschine).
	@sudo launchctl list | grep kompletekontrol || echo "No daemon running or installed."
	@for label in $(LIFECYCLE_LABELS); do \
		mode="$$(sudo /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:KK_MK2_DISPLAY_ENCODING' /Library/LaunchDaemons/$$label.plist 2>/dev/null || true)"; \
		if [ -n "$$mode" ]; then echo "$$label: display encoding $$mode"; else echo "$$label: not installed or default encoding"; fi; \
	done

daemon-start: ## Start both daemons via launchctl (narrow with DEVICE=kontrol|maschine).
	@for label in $(LIFECYCLE_LABELS); do \
		echo "starting $$label"; \
		sudo launchctl bootstrap system /Library/LaunchDaemons/$$label.plist || echo "  $$label: start failed (already running or not installed?)"; \
	done

daemon-stop: ## Stop both daemons via launchctl (narrow with DEVICE=kontrol|maschine).
	@for label in $(LIFECYCLE_LABELS); do \
		echo "stopping $$label"; \
		sudo launchctl bootout system /Library/LaunchDaemons/$$label.plist || echo "  $$label: stop failed (not running or not installed?)"; \
	done

daemon-restart: ## Restart both daemons via launchctl (narrow with DEVICE=kontrol|maschine).
	@for label in $(LIFECYCLE_LABELS); do \
		echo "restarting $$label"; \
		sudo launchctl kickstart -k system/$$label || echo "  $$label: restart failed (not running or not installed?)"; \
	done

mk2-surface-demo: mk2-surface-demo-build ## Run the MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO)

mk2-surface-demo-release: mk2-surface-demo-build-release ## Run optimized MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO_RELEASE)

widget-lab: widget-lab-build ## Run Widget Lab against the normal daemon endpoint.
	@$(MAKE) daemon-preflight
	$(WIDGET_LAB)

widget-lab-sim: widget-lab-build ## Run the same Widget Lab against the simulator daemon endpoint.
	KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock $(WIDGET_LAB)

widget-lab-release: widget-lab-build-release ## Run optimized Widget Lab against the normal daemon endpoint.
	@$(MAKE) daemon-preflight
	$(WIDGET_LAB_RELEASE)

widget-lab-test-validate: widget-lab-build ## Validate that every Widget Lab demo has a smoke scenario.
	Scripts/widget-lab-test.py validate

widget-lab-smoke: widget-lab-build ## Run the complete Widget Lab smoke suite against the configured daemon endpoint.
	Scripts/widget-lab-test.py smoke --socket $(WIDGET_LAB_TEST_SOCKET) $(WIDGET_LAB_TEST_ARGS)

widget-lab-stress: widget-lab-build ## Stress every Widget Lab demo (default: 15m; override WIDGET_LAB_STRESS_DURATION).
	Scripts/widget-lab-test.py stress --socket $(WIDGET_LAB_TEST_SOCKET) --duration $(WIDGET_LAB_STRESS_DURATION) $(WIDGET_LAB_TEST_ARGS)

widget-lab-soak: widget-lab-build ## Soak every Widget Lab demo (default: 8h; override WIDGET_LAB_SOAK_DURATION).
	Scripts/widget-lab-test.py soak --socket $(WIDGET_LAB_TEST_SOCKET) --duration $(WIDGET_LAB_SOAK_DURATION) $(WIDGET_LAB_TEST_ARGS)

widget-lab-compare: ## Compare adaptive and legacy reports (set ADAPTIVE_REPORT and LEGACY_REPORT).
	@test -n "$(ADAPTIVE_REPORT)" -a -n "$(LEGACY_REPORT)" || { echo "Set ADAPTIVE_REPORT and LEGACY_REPORT to report.json paths." >&2; exit 2; }
	Scripts/widget-lab-test.py compare --adaptive-report "$(ADAPTIVE_REPORT)" --legacy-report "$(LEGACY_REPORT)"

kk-input: ## Open the interactive automation-input REPL with automatic socket discovery.
	Scripts/kk-input.py

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop foreground daemons on both sockets (narrow with DEVICE=kontrol|maschine).
	@for socket in $(LIFECYCLE_SOCKETS); do \
		sudo pkill -f "kk-libusb-daemon $$socket" 2>/dev/null || true; \
	done

kk-clean-socket: ## Remove both daemon sockets (narrow with DEVICE=kontrol|maschine).
	@for socket in $(LIFECYCLE_SOCKETS); do \
		sudo rm -f "$$socket" "$${socket%.sock}.lock"; \
	done

kk-status: ## Show running CompleteControl daemon processes.
	@pgrep -fl 'ccd|--kk-libusb-daemon' || true
