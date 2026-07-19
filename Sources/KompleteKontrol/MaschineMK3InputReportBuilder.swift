import Foundation

/// Stateful producer for byte-identical MASCHINE MK3 input reports. All surface layout
/// constants are shared with `MaschineMK3InputReportDecoder`; simulator gestures therefore
/// exercise the same native report path as USB hardware.
public struct MaschineMK3InputReportBuilder: Sendable {
    public private(set) var surfaceBytes: [UInt8]
    public private(set) var heldPads: [Bool]

    public init() {
        surfaceBytes = [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize)
        surfaceBytes[0] = MaschineMK3Protocol.surfaceReportID
        heldPads = [Bool](repeating: false, count: 16)
    }

    public mutating func setButton(_ button: MaschineMK3Button, pressed: Bool) {
        guard let bit = MaschineMK3InputReportLayout.buttonBits.first(where: { $0.button == button }) else { return }
        if pressed {
            surfaceBytes[bit.byte] |= bit.mask
        } else {
            surfaceBytes[bit.byte] &= ~bit.mask
        }
    }

    /// Encoder 0 is the main encoder (modulo 16); 1...8 are the display encoders
    /// (modulo 1000), matching the native decoder.
    @discardableResult
    public mutating func turnEncoder(_ index: Int, delta: Int) -> Int {
        if index == 0 {
            var value = Int(surfaceBytes[11] & 0x0f)
            value = Self.wrapped(value + delta, modulo: 16)
            surfaceBytes[11] = (surfaceBytes[11] & 0xf0) | UInt8(value)
            return value
        }
        guard (1...8).contains(index) else { return 0 }
        let offset = 12 + (index - 1) * 2
        var value = Int(surfaceBytes[offset]) | Int(surfaceBytes[offset + 1] & 0x03) << 8
        value = Self.wrapped(value + delta, modulo: 1000)
        surfaceBytes[offset] = UInt8(value & 0xff)
        surfaceBytes[offset + 1] = (surfaceBytes[offset + 1] & 0xfc) | UInt8((value >> 8) & 0x03)
        return value
    }

    public mutating func setEncoderTouch(_ index: Int, touched: Bool) {
        if index == 0 {
            if touched { surfaceBytes[9] |= 0x80 } else { surfaceBytes[9] &= 0x7f }
            return
        }
        guard (1...8).contains(index) else { return }
        let mask = UInt8(0x80 >> (index - 1))
        if touched { surfaceBytes[10] |= mask } else { surfaceBytes[10] &= ~mask }
    }

    public mutating func setTouchStrip(finger: Int, position: Int?) {
        guard (1...2).contains(finger) else { return }
        setWord(offset: 30 + (finger - 1) * 4, value: max(0, min(1023, position ?? 0)), highMask: 0x03)
    }

    public mutating func setAnalog(_ control: MaschineMK3AnalogControl, value: Int) {
        let offset: Int
        switch control {
            case .microphoneGain: offset = 36
            case .headphoneVolume: offset = 38
            case .masterVolume: offset = 40
        }
        setWord(offset: offset, value: max(0, min(0xffff, value)), highMask: 0xff)
    }

    public mutating func padTouch(hardwareIndex: Int, pressure: Int) -> [UInt8]? {
        guard heldPads.indices.contains(hardwareIndex) else { return nil }
        heldPads[hardwareIndex] = true
        return padReport(hardwareIndex: hardwareIndex, encodedValue: max(0, min(0x0fff, pressure)))
    }

    public mutating func padStrike(hardwareIndex: Int, velocity: Int) -> [UInt8]? {
        guard heldPads.indices.contains(hardwareIndex) else { return nil }
        heldPads[hardwareIndex] = true
        return padReport(hardwareIndex: hardwareIndex, encodedValue: 0x1000 | max(0, min(0x0fff, velocity)))
    }

    public mutating func padPressure(hardwareIndex: Int, pressure: Int) -> [UInt8]? {
        guard heldPads.indices.contains(hardwareIndex), heldPads[hardwareIndex] else { return nil }
        return padReport(hardwareIndex: hardwareIndex, encodedValue: 0x4000 | max(0, min(0x0fff, pressure)))
    }

    public mutating func padRelease(hardwareIndex: Int) -> [UInt8]? {
        guard heldPads.indices.contains(hardwareIndex), heldPads[hardwareIndex] else { return nil }
        heldPads[hardwareIndex] = false
        return padReport(hardwareIndex: hardwareIndex, encodedValue: 0x3000)
    }

    public static func hardwareIndex(forPhysicalPadNumber pad: Int) -> Int? {
        guard (1...16).contains(pad) else { return nil }
        let zeroBased = pad - 1
        return (3 - zeroBased / 4) * 4 + zeroBased % 4
    }

    private func padReport(hardwareIndex: Int, encodedValue: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        bytes[0] = MaschineMK3Protocol.padReportID
        bytes[1] = UInt8(hardwareIndex)
        bytes[2] = UInt8((encodedValue >> 8) & 0xff)
        bytes[3] = UInt8(encodedValue & 0xff)
        return bytes
    }

    private mutating func setWord(offset: Int, value: Int, highMask: UInt8) {
        surfaceBytes[offset] = UInt8(value & 0xff)
        surfaceBytes[offset + 1] = (surfaceBytes[offset + 1] & ~highMask) | UInt8((value >> 8) & Int(highMask))
    }

    private static func wrapped(_ value: Int, modulo: Int) -> Int {
        (value % modulo + modulo) % modulo
    }
}
