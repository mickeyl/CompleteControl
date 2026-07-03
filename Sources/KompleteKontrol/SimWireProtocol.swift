import Foundation

/// The device-side wire protocol between `ccd` (in simulation mode) and the
/// `KontrolSimulator` app — the "virtual USB". Length-prefixed binary frames:
/// `[u8 type][u32be length][payload]`. Shared by both sides so there is exactly one codec
/// and one message vocabulary.
///
/// ccd→sim carries output (display blits, LED/guide reports); sim→ccd carries the
/// simulator's semantic input, which `SimulatorDeviceSession` lowers into raw reports via
/// `MK2InputReportBuilder`.
/// The default endpoint both sides agree on: the daemon (simulator backend) connects, the
/// `KontrolSimulator` app listens. Overridable via `CCD_SIMULATE` on the daemon side.
public enum SimEndpoint {
    public static let defaultSocketPath = "/tmp/kontrol-simulator.sock"
}

public enum SimFrameType: UInt8, Sendable {
    // sim → ccd
    case hello = 0x00           // {u16be productID, u8 keyCount}
    case button = 0x10          // {u8 buttonLEDRawValue, u8 pressed}
    case encoder = 0x11         // {u8 index 1…8, i8 delta}
    case encoderTouch = 0x12    // {u8 index 1…8, u8 touched}
    case fourDWheel = 0x13      // {i8 delta}
    case fourDState = 0x14      // {u8 FourDState raw}
    case note = 0x15            // reserved for V2: {u8 note, u8 velocity, u8 on}

    // ccd → sim
    case displayBlit = 0x80     // {u8 screen, u16be x, u16be y, u16be w, u16be h, rgb565be…}
    case report = 0x81          // {u8 reportID, payload…}
}

public struct SimFrame: Sendable, Equatable {
    public var type: SimFrameType
    public var payload: [UInt8]

    public init(type: SimFrameType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }
}

public enum SimWireCodec {
    public static func encode(_ frame: SimFrame) -> [UInt8] {
        let length = UInt32(frame.payload.count)
        var out: [UInt8] = [
            frame.type.rawValue,
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ]
        out.append(contentsOf: frame.payload)
        return out
    }

    /// Decode as many complete frames as `buffer` holds. Returns the frames plus the number
    /// of bytes consumed; the caller keeps the unconsumed tail for the next read. An unknown
    /// type byte is skipped (still consuming its framed length) so one bad frame can't wedge
    /// the stream.
    public static func decode(_ buffer: [UInt8]) -> (frames: [SimFrame], consumed: Int) {
        var frames: [SimFrame] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let typeByte = buffer[offset]
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16
                | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard buffer.count - offset - 5 >= length else { break }
            if let type = SimFrameType(rawValue: typeByte) {
                frames.append(SimFrame(type: type, payload: Array(buffer[(offset + 5)..<(offset + 5 + length)])))
            }
            offset += 5 + length
        }
        return (frames, offset)
    }
}

// MARK: - Typed payload helpers

public extension SimFrame {
    static func hello(productID: UInt16, keyCount: UInt8) -> SimFrame {
        SimFrame(type: .hello, payload: [UInt8(productID >> 8), UInt8(productID & 0xff), keyCount])
    }

    static func button(led: KKMK2ButtonLED, pressed: Bool) -> SimFrame {
        SimFrame(type: .button, payload: [UInt8(led.rawValue & 0xff), pressed ? 1 : 0])
    }

    static func encoder(index: Int, delta: Int) -> SimFrame {
        SimFrame(type: .encoder, payload: [UInt8(index & 0xff), UInt8(bitPattern: Int8(clamping: delta))])
    }

    static func encoderTouch(index: Int, touched: Bool) -> SimFrame {
        SimFrame(type: .encoderTouch, payload: [UInt8(index & 0xff), touched ? 1 : 0])
    }

    static func fourDWheel(delta: Int) -> SimFrame {
        SimFrame(type: .fourDWheel, payload: [UInt8(bitPattern: Int8(clamping: delta))])
    }

    static func fourDState(_ raw: UInt8) -> SimFrame {
        SimFrame(type: .fourDState, payload: [raw])
    }

    static func displayBlit(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16, pixelsBE: [UInt8]) -> SimFrame {
        var payload: [UInt8] = [
            screen,
            UInt8(x >> 8), UInt8(x & 0xff), UInt8(y >> 8), UInt8(y & 0xff),
            UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff),
        ]
        payload.append(contentsOf: pixelsBE)
        return SimFrame(type: .displayBlit, payload: payload)
    }

    static func report(reportID: UInt8, bytes: [UInt8]) -> SimFrame {
        SimFrame(type: .report, payload: [reportID] + bytes)
    }
}
