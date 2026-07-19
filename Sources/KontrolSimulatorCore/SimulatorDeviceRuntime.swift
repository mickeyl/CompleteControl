import Foundation
import KompleteKontrol
import KontrolSimulatorWire

/// Headless gesture-to-native-report runtime used by the visual simulator and tests.
public final class SimulatorDeviceRuntime: @unchecked Sendable {
    public let definition: SimulatorDeviceDefinition
    public var onInputFrame: ((SimFrame) -> Void)?

    private let lock = NSLock()
    private var maschineBuilder = MaschineMK3InputReportBuilder()

    public init(definition: SimulatorDeviceDefinition) {
        self.definition = definition
    }

    public func setMaschineButton(_ button: MaschineMK3Button, pressed: Bool) {
        guard definition.kind == .maschineMK3 else { return }
        emitSurface { $0.setButton(button, pressed: pressed) }
    }

    public func turnMaschineEncoder(_ index: Int, delta: Int) {
        guard definition.kind == .maschineMK3, delta != 0 else { return }
        emitSurface { _ = $0.turnEncoder(index, delta: delta) }
    }

    public func setMaschineEncoderTouch(_ index: Int, touched: Bool) {
        guard definition.kind == .maschineMK3 else { return }
        emitSurface { $0.setEncoderTouch(index, touched: touched) }
    }

    public func setMaschineTouchStrip(finger: Int, position: Int?) {
        guard definition.kind == .maschineMK3 else { return }
        emitSurface { $0.setTouchStrip(finger: finger, position: position) }
    }

    public func touchMaschinePad(physicalPad: Int, pressure: Int) {
        emitPad(physicalPad: physicalPad) { $0.padTouch(hardwareIndex: $1, pressure: pressure) }
    }

    public func strikeMaschinePad(physicalPad: Int, velocity: Int) {
        emitPad(physicalPad: physicalPad) { $0.padStrike(hardwareIndex: $1, velocity: velocity) }
    }

    public func pressureMaschinePad(physicalPad: Int, pressure: Int) {
        emitPad(physicalPad: physicalPad) { $0.padPressure(hardwareIndex: $1, pressure: pressure) }
    }

    public func releaseMaschinePad(physicalPad: Int) {
        emitPad(physicalPad: physicalPad) { $0.padRelease(hardwareIndex: $1) }
    }

    public func releaseAllMaschineInputs() {
        guard definition.kind == .maschineMK3 else { return }
        lock.lock()
        let held = maschineBuilder.heldPads.enumerated().compactMap { $0.element ? $0.offset : nil }
        var reports: [[UInt8]] = []
        for index in held {
            if let report = maschineBuilder.padRelease(hardwareIndex: index) { reports.append(report) }
        }
        for button in MaschineMK3Button.allCases {
            maschineBuilder.setButton(button, pressed: false)
        }
        for index in 0...8 { maschineBuilder.setEncoderTouch(index, touched: false) }
        maschineBuilder.setTouchStrip(finger: 1, position: nil)
        maschineBuilder.setTouchStrip(finger: 2, position: nil)
        let surface = maschineBuilder.surfaceBytes
        lock.unlock()
        onInputFrame?(.surfaceInput(surface))
        for report in reports { onInputFrame?(.surfaceInput(report)) }
    }

    private func emitSurface(_ change: (inout MaschineMK3InputReportBuilder) -> Void) {
        lock.lock()
        change(&maschineBuilder)
        let bytes = maschineBuilder.surfaceBytes
        lock.unlock()
        onInputFrame?(.surfaceInput(bytes))
    }

    private func emitPad(
        physicalPad: Int,
        change: (inout MaschineMK3InputReportBuilder, Int) -> [UInt8]?
    ) {
        guard definition.kind == .maschineMK3,
              let hardwareIndex = MaschineMK3InputReportBuilder.hardwareIndex(forPhysicalPadNumber: physicalPad) else { return }
        lock.lock()
        let bytes = change(&maschineBuilder, hardwareIndex)
        lock.unlock()
        if let bytes { onInputFrame?(.surfaceInput(bytes)) }
    }
}
