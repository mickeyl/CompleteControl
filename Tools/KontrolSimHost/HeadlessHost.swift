import CryptoKit
import Foundation
import KompleteKontrol
import KontrolSimulatorCore
import KontrolSimulatorWire

/// The headless counterpart of the AppKit simulator's AppController: owns the device link,
/// the gesture runtime, the reduced output state, and (optionally) a child ccd — but exposes
/// a JSON-Lines control plane instead of a window. All state is confined to the main queue,
/// which `DeviceLink`, `ControlPlane`, and the signal sources already target.
final class HeadlessHost: @unchecked Sendable {
    private let options: HostOptions
    private let lease: SimulatorInstanceLease
    private let definition: SimulatorDeviceDefinition
    private let link: DeviceLink
    private let runtime: SimulatorDeviceRuntime
    private let outputState: SimulatorOutputState
    private let daemonController = SimulatorDaemonController()
    private let controlPlane = ControlPlane()
    private var signalSources: [DispatchSourceSignal] = []
    private var daemonConnected = false
    private var announcedReady = false
    private var shuttingDown = false

    private var paths: SimulatorInstancePaths { lease.paths }
    private var automationSocketPath: String? {
        guard options.automationEnabled else { return nil }
        return KompleteKontrolLibUSBServer.daemonSocketPath(base: paths.daemonSocketPath, channel: .automation)
    }

    init(options: HostOptions, lease: SimulatorInstanceLease) {
        self.options = options
        self.lease = lease
        definition = SimulatorDeviceDefinition.definition(for: options.kind, instanceID: options.instanceID)
        link = DeviceLink(socketPath: lease.paths.deviceSocketPath, descriptor: definition.descriptor)
        runtime = SimulatorDeviceRuntime(definition: definition)
        outputState = SimulatorOutputState(definition: definition)
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        runtime.onInputFrame = { [weak self] frame in self?.link.send(frame) }
        link.onFrame = { [weak self] frame in self?.apply(frame) }
        link.onConnect = { [weak self] in self?.handleDaemonConnect() }
        link.onDisconnect = { [weak self] in self?.handleDaemonDisconnect() }
        link.onProtocolError = { [weak self] message in
            self?.controlPlane.emit(event: "protocolError", ["message": message])
        }
        guard link.start() else {
            FileHandle.standardError.write(Data("kontrol-sim-host: failed to bind \(paths.deviceSocketPath)\n".utf8))
            lease.releaseAndCleanUp()
            exitHost(.deviceSocketBindFailure)
        }
        installSignalHandlers()

        controlPlane.onCommand = { [weak self] command in
            self?.handle(command: command) ?? ["ok": false, "error": "host is shutting down"]
        }
        controlPlane.onEndOfInput = { [weak self] in self?.shutdown(.ok) }
        controlPlane.start()

        if options.ownsDaemon {
            startOwnedDaemon()
        } else {
            announceReadyIfNeeded()
        }
        dispatchMain()
    }

    // MARK: - Daemon lifecycle

    private func startOwnedDaemon() {
        daemonController.onTermination = { [weak self] status in
            guard let self, !self.shuttingDown else { return }
            self.controlPlane.emit(event: "daemonExited", ["status": Int(status)])
            self.shutdown(.daemonExitedUnexpectedly)
        }
        let ccdURL = options.ccdPath.map { URL(fileURLWithPath: $0) }
            ?? SimulatorDaemonController.defaultCCDURL()
        do {
            try daemonController.start(SimulatorDaemonController.Configuration(
                ccdURL: ccdURL,
                daemonSocketPath: paths.daemonSocketPath,
                deviceSocketPath: paths.deviceSocketPath,
                automationEnabled: options.automationEnabled,
                logPath: paths.daemonLogPath
            ))
        } catch {
            FileHandle.standardError.write(Data("kontrol-sim-host: \(error)\n".utf8))
            link.stop()
            lease.releaseAndCleanUp()
            exitHost(.daemonStartFailure)
        }
    }

    private func handleDaemonConnect() {
        daemonConnected = true
        sendIdentityIfOverridden()
        // With an owned daemon, readiness means the full chain stands: device socket bound,
        // daemon spawned, daemon sockets listening (ccd binds them before it dials the
        // device), and the device handshake completed.
        announceReadyIfNeeded()
        controlPlane.emit(event: "daemonConnected")
    }

    private func handleDaemonDisconnect() {
        daemonConnected = false
        outputState.clear()
        guard !shuttingDown else { return }
        controlPlane.emit(event: "daemonDisconnected")
    }

    private func sendIdentityIfOverridden() {
        guard options.firmwareOverride != nil || options.nameOverride != nil else { return }
        link.send(.identity(
            firmwareVersion: options.firmwareOverride ?? definition.descriptor.firmwareVersion,
            nameOverride: options.nameOverride ?? ""
        ))
    }

    private func announceReadyIfNeeded() {
        guard !announcedReady else { return }
        announcedReady = true
        controlPlane.emit(event: "ready", [
            "device": definition.kind.rawValue,
            "instance": options.instanceID,
            "deviceSocket": paths.deviceSocketPath,
            "daemonSocket": paths.daemonSocketPath,
            "automationSocket": automationSocketPath ?? NSNull(),
            "clientEnv": ["KK_DAEMON_SOCKET": paths.daemonSocketPath],
        ])
    }

    // MARK: - Shutdown

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown(.ok) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown(_ code: HostExitCode) -> Never {
        shuttingDown = true
        daemonController.stopAndWait()
        link.stop()
        lease.releaseAndCleanUp()
        exitHost(code)
    }

    // MARK: - Daemon output

    private func apply(_ frame: SimFrame) {
        do {
            try outputState.apply(frame)
        } catch {
            controlPlane.emit(event: "protocolError", ["message": "\(error)"])
        }
    }

    // MARK: - Commands

    private func handle(command: [String: Any]) -> [String: Any] {
        guard let name = command["cmd"] as? String else {
            return ["ok": false, "error": "missing 'cmd'"]
        }
        switch name {
            case "status":
                return [
                    "ok": true,
                    "device": definition.kind.rawValue,
                    "instance": options.instanceID,
                    "daemonConnected": daemonConnected,
                    "deviceSocket": paths.deviceSocketPath,
                    "daemonSocket": paths.daemonSocketPath,
                    "automationSocket": automationSocketPath ?? NSNull(),
                ]
            case "gesture":
                return handleGesture(command)
            case "lamps":
                let lamps = outputState.lampSnapshot()
                return [
                    "ok": true,
                    "buttons": hex(lamps.buttonBytes),
                    "stripAndPads": hex(lamps.stripAndPadBytes),
                    "lightGuide": hex(lamps.lightGuideBytes),
                ]
            case "framebuffer":
                return handleFramebuffer(command)
            case "identity":
                return handleIdentity(command)
            case "quit":
                DispatchQueue.main.async { [weak self] in self?.shutdown(.ok) }
                return ["ok": true]
            default:
                return ["ok": false, "error": "unknown command '\(name)'"]
        }
    }

    private func handleGesture(_ command: [String: Any]) -> [String: Any] {
        guard definition.kind == .maschineMK3 else {
            return [
                "ok": false,
                "error": "native gesture synthesis is MASCHINE MK3-only for now; "
                    + "drive KONTROL MK2 scenarios through the daemon automation socket",
            ]
        }
        guard let gesture = command["gesture"] as? String else {
            return ["ok": false, "error": "missing 'gesture'"]
        }
        switch gesture {
            case "button":
                guard let name = command["button"] as? String,
                      let button = MaschineMK3Button(rawValue: name) else {
                    return ["ok": false, "error": "unknown button '\(command["button"] ?? "")'"]
                }
                guard let pressed = command["pressed"] as? Bool else {
                    return ["ok": false, "error": "'pressed' must be true or false"]
                }
                runtime.setMaschineButton(button, pressed: pressed)
            case "encoder":
                guard let index = command["index"] as? Int, (0...8).contains(index) else {
                    return ["ok": false, "error": "'index' must be 0-8"]
                }
                guard let delta = command["delta"] as? Int, delta != 0 else {
                    return ["ok": false, "error": "'delta' must be a non-zero integer"]
                }
                runtime.turnMaschineEncoder(index, delta: delta)
            case "encoderTouch":
                guard let index = command["index"] as? Int, (0...8).contains(index) else {
                    return ["ok": false, "error": "'index' must be 0-8"]
                }
                guard let touched = command["touched"] as? Bool else {
                    return ["ok": false, "error": "'touched' must be true or false"]
                }
                runtime.setMaschineEncoderTouch(index, touched: touched)
            case "strip":
                guard let finger = command["finger"] as? Int, (1...2).contains(finger) else {
                    return ["ok": false, "error": "'finger' must be 1 or 2"]
                }
                let position = command["position"] as? Int
                runtime.setMaschineTouchStrip(finger: finger, position: position)
            case "padTouch", "padStrike", "padPressure", "padRelease":
                return handlePadGesture(gesture, command)
            case "releaseAll":
                runtime.releaseAllMaschineInputs()
            default:
                return ["ok": false, "error": "unknown gesture '\(gesture)'"]
        }
        return ["ok": true]
    }

    private func handlePadGesture(_ gesture: String, _ command: [String: Any]) -> [String: Any] {
        guard let pad = command["pad"] as? Int, (1...16).contains(pad) else {
            return ["ok": false, "error": "'pad' must be 1-16"]
        }
        switch gesture {
            case "padTouch":
                guard let pressure = command["pressure"] as? Int else {
                    return ["ok": false, "error": "'pressure' must be an integer"]
                }
                runtime.touchMaschinePad(physicalPad: pad, pressure: pressure)
            case "padStrike":
                guard let velocity = command["velocity"] as? Int else {
                    return ["ok": false, "error": "'velocity' must be an integer"]
                }
                runtime.strikeMaschinePad(physicalPad: pad, velocity: velocity)
            case "padPressure":
                guard let pressure = command["pressure"] as? Int else {
                    return ["ok": false, "error": "'pressure' must be an integer"]
                }
                runtime.pressureMaschinePad(physicalPad: pad, pressure: pressure)
            default:
                runtime.releaseMaschinePad(physicalPad: pad)
        }
        return ["ok": true]
    }

    private func handleFramebuffer(_ command: [String: Any]) -> [String: Any] {
        guard let display = command["display"] as? Int,
              outputState.screens.indices.contains(display) else {
            return ["ok": false, "error": "'display' must be 0 or 1"]
        }
        let snapshot = outputState.screens[display].snapshot()
        let digest = SHA256.hash(data: Data(snapshot.pixelsBE))
        var response: [String: Any] = [
            "ok": true,
            "width": snapshot.width,
            "height": snapshot.height,
            "sha256": digest.map { String(format: "%02x", $0) }.joined(),
        ]
        guard let path = command["path"] as? String else { return response }
        let format = command["format"] as? String ?? "png"
        do {
            switch format {
                case "png":
                    try FramebufferPNG.write(snapshot, to: path)
                case "rgb565":
                    try Data(snapshot.pixelsBE).write(to: URL(fileURLWithPath: path))
                default:
                    return ["ok": false, "error": "unknown format '\(format)'; use 'png' or 'rgb565'"]
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
        response["path"] = path
        return response
    }

    private func handleIdentity(_ command: [String: Any]) -> [String: Any] {
        var firmwareVersion = options.firmwareOverride ?? definition.descriptor.firmwareVersion
        if let firmware = command["firmware"] as? String {
            guard let parsed = KKDeviceInfo.parseBCDVersion(firmware) else {
                return ["ok": false, "error": "invalid firmware version '\(firmware)'; use major.minor.patch"]
            }
            firmwareVersion = parsed
        }
        let name = command["name"] as? String ?? options.nameOverride ?? ""
        link.send(.identity(firmwareVersion: firmwareVersion, nameOverride: name))
        return ["ok": true]
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
