import Foundation

/// Synthesizes raw MK2 `0x01` surface-input reports from semantic edits. This is the
/// transparency linchpin of simulation mode: the simulator sends semantic events, this
/// builder turns them into the exact bytes the firmware would stream, and the daemon ships
/// those bytes verbatim so the client's decoder cannot tell simulator from hardware.
///
/// It writes through the *same* layout `KKMK2InputReportDecoder` reads
/// (`buttonBits`, `knobBaseOffset`, `encoderTouchOffset`, `jogStates`) — one source of
/// truth, verified by the round-trip tests.
public struct MK2InputReportBuilder {
    /// Covers every byte the decoder reads (max index 30) with headroom to match the real
    /// device's `0x01` report size. Held constant across reports so the decoder's
    /// previous/current length check always holds.
    public static let reportLength = 42

    public private(set) var bytes: [UInt8]

    public init() {
        bytes = [UInt8](repeating: 0, count: Self.reportLength)
        bytes[0] = UInt8(KompleteKontrolMK2Protocol.inputReportID)
    }

    /// Set/clear a button bit. Unknown LEDs (e.g. the light-guide strip, which is not a
    /// surface button) are silently ignored.
    public mutating func setButton(_ led: KKMK2ButtonLED, pressed: Bool) {
        guard let bit = KKMK2InputReportDecoder.buttonBits.first(where: { $0.led == led }) else { return }
        if pressed { bytes[bit.byte] |= bit.mask } else { bytes[bit.byte] &= ~bit.mask }
    }

    /// Advance a rotary encoder (index 1…8) by a signed delta; counters wrap 0…999 like the
    /// hardware. Returns the new absolute value.
    @discardableResult
    public mutating func turnEncoder(_ index: Int, delta: Int) -> Int {
        let offset = KKMK2InputReportDecoder.knobBaseOffset + (index - 1) * 2
        var value = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        value = ((value + delta) % 1000 + 1000) % 1000
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        return value
    }

    /// Encoder cap touch (index 1…8). Touch bit is `0x80 >> (index-1)` in the touch byte.
    public mutating func setEncoderTouch(_ index: Int, touched: Bool) {
        let mask = UInt8(0x80) >> (index - 1)
        let offset = KKMK2InputReportDecoder.encoderTouchOffset
        if touched { bytes[offset] |= mask } else { bytes[offset] &= ~mask }
    }

    /// Rotate the 4-D wheel by a signed delta; the low nibble of byte 30 wraps 0…15.
    @discardableResult
    public mutating func turnFourDWheel(delta: Int) -> Int {
        var value = Int(bytes[30] & 0x0f)
        value = ((value + delta) % 16 + 16) % 16
        bytes[30] = (bytes[30] & 0xf0) | UInt8(value)
        return value
    }

    /// The 4-D directional/click/touch state lives entirely in byte 6. The push values
    /// already carry the touch bit (`0x04`), matching the decoder's `jogStates` table.
    public enum FourDState: UInt8 {
        case released = 0x00
        case touched = 0x04
        case click = 0x0c
        case pushLeft = 0x14
        case pushUp = 0x24
        case pushDown = 0x44
        case pushRight = 0x84
    }

    public mutating func setFourD(_ state: FourDState) {
        bytes[6] = state.rawValue
    }
}
