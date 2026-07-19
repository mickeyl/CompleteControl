import Foundation

/// The Foundation-only wire shared by a simulator host and `ccd`. Frames are
/// `[u8 type][u32be payload length][payload]`; the first simulator-to-daemon frame is a
/// versioned descriptor handshake.
public enum SimEndpoint {
    public static let defaultSocketPath = "/tmp/kontrol-simulator.sock"
}

public enum SimWireProtocol {
    public static let currentVersion: UInt16 = 2
    public static let maximumPayloadLength = 4 * 1024 * 1024
    static let descriptorMagic: [UInt8] = [0x4b, 0x53, 0x49, 0x4d] // KSIM
}

public struct SimFrameCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rawSurfaceInput = SimFrameCapabilities(rawValue: 1 << 0)
    public static let rawMIDIInput = SimFrameCapabilities(rawValue: 1 << 1)
    public static let displayBlits = SimFrameCapabilities(rawValue: 1 << 2)
    public static let displayPackets = SimFrameCapabilities(rawValue: 1 << 3)
    public static let outputReports = SimFrameCapabilities(rawValue: 1 << 4)
}

public struct SimulatorDeviceDescriptor: Sendable, Equatable {
    public var wireVersion: UInt16
    public var productID: UInt16
    public var keyCount: UInt8
    public var firmwareVersion: UInt16
    public var instanceID: String
    public var reportedName: String?
    public var capabilities: SimFrameCapabilities

    public init(
        wireVersion: UInt16 = SimWireProtocol.currentVersion,
        productID: UInt16,
        keyCount: UInt8,
        firmwareVersion: UInt16,
        instanceID: String,
        reportedName: String? = nil,
        capabilities: SimFrameCapabilities
    ) {
        self.wireVersion = wireVersion
        self.productID = productID
        self.keyCount = keyCount
        self.firmwareVersion = firmwareVersion
        self.instanceID = instanceID
        self.reportedName = reportedName
        self.capabilities = capabilities
    }

    public func encodedPayload() -> [UInt8] {
        let instance = Array(instanceID.utf8.prefix(255))
        let name = Array((reportedName ?? "").utf8.prefix(255))
        var bytes = SimWireProtocol.descriptorMagic
        bytes.append(contentsOf: Self.be(wireVersion))
        bytes.append(contentsOf: Self.be(productID))
        bytes.append(keyCount)
        bytes.append(contentsOf: Self.be(firmwareVersion))
        bytes.append(contentsOf: Self.be(capabilities.rawValue))
        bytes.append(UInt8(instance.count))
        bytes.append(contentsOf: instance)
        bytes.append(UInt8(name.count))
        bytes.append(contentsOf: name)
        return bytes
    }

    public init(payload: [UInt8]) throws {
        guard payload.count >= 16,
              Array(payload[0..<4]) == SimWireProtocol.descriptorMagic else {
            throw SimWireError.malformedDescriptor("missing KSIM descriptor header")
        }
        wireVersion = Self.u16(payload, 4)
        productID = Self.u16(payload, 6)
        keyCount = payload[8]
        firmwareVersion = Self.u16(payload, 9)
        capabilities = SimFrameCapabilities(rawValue: Self.u32(payload, 11))
        var offset = 15
        let instanceLength = Int(payload[offset])
        offset += 1
        guard payload.count >= offset + instanceLength + 1 else {
            throw SimWireError.malformedDescriptor("truncated instance ID")
        }
        instanceID = String(bytes: payload[offset..<(offset + instanceLength)], encoding: .utf8) ?? ""
        offset += instanceLength
        let nameLength = Int(payload[offset])
        offset += 1
        guard payload.count == offset + nameLength else {
            throw SimWireError.malformedDescriptor("truncated or trailing reported name")
        }
        let decodedName = String(bytes: payload[offset..<(offset + nameLength)], encoding: .utf8) ?? ""
        reportedName = decodedName.isEmpty ? nil : decodedName
        guard !instanceID.isEmpty else {
            throw SimWireError.malformedDescriptor("empty instance ID")
        }
    }

    private static func be(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    private static func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

public enum SimFrameType: UInt8, Sendable {
    // sim -> ccd
    case hello = 0x00
    case identity = 0x01
    case button = 0x10
    case encoder = 0x11
    case encoderTouch = 0x12
    case fourDWheel = 0x13
    case fourDState = 0x14
    case note = 0x15
    case midi = 0x16
    case strip = 0x17
    case surfaceInput = 0x18
    case midiInput = 0x19

    // ccd -> sim
    case displayBlit = 0x80
    case report = 0x81
    case displayPacket = 0x82
}

public struct SimFrame: Sendable, Equatable {
    public var type: SimFrameType
    public var payload: [UInt8]

    public init(type: SimFrameType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }
}

public enum SimWireError: Error, Equatable, CustomStringConvertible {
    case payloadTooLarge(Int)
    case malformedDescriptor(String)
    case versionMismatch(UInt16)

    public var description: String {
        switch self {
            case let .payloadTooLarge(length): "payload too large: \(length)"
            case let .malformedDescriptor(reason): "malformed descriptor: \(reason)"
            case let .versionMismatch(version): "unsupported simulator wire version \(version)"
        }
    }
}

public enum SimWireCodec {
    public static func encode(_ frame: SimFrame) -> [UInt8] {
        precondition(frame.payload.count <= SimWireProtocol.maximumPayloadLength)
        let length = UInt32(frame.payload.count)
        var out: [UInt8] = [
            frame.type.rawValue,
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ]
        out.append(contentsOf: frame.payload)
        return out
    }

    public static func decodeChecked(_ buffer: [UInt8]) throws -> (frames: [SimFrame], consumed: Int) {
        var frames: [SimFrame] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let typeByte = buffer[offset]
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16
                | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard length <= SimWireProtocol.maximumPayloadLength else {
                throw SimWireError.payloadTooLarge(length)
            }
            guard buffer.count - offset - 5 >= length else { break }
            if let type = SimFrameType(rawValue: typeByte) {
                frames.append(SimFrame(type: type, payload: Array(buffer[(offset + 5)..<(offset + 5 + length)])))
            }
            offset += 5 + length
        }
        return (frames, offset)
    }

    public static func decode(_ buffer: [UInt8]) -> (frames: [SimFrame], consumed: Int) {
        (try? decodeChecked(buffer)) ?? ([], 0)
    }
}

public extension SimFrame {
    static func hello(descriptor: SimulatorDeviceDescriptor) -> SimFrame {
        SimFrame(type: .hello, payload: descriptor.encodedPayload())
    }

    /// Legacy helper retained while the MK2 panel still uses semantic input frames.
    static func hello(productID: UInt16, keyCount: UInt8) -> SimFrame {
        SimFrame(type: .hello, payload: [UInt8(productID >> 8), UInt8(productID & 0xff), keyCount])
    }

    static func identity(firmwareVersion: UInt16, nameOverride: String) -> SimFrame {
        var payload: [UInt8] = [UInt8(firmwareVersion >> 8), UInt8(firmwareVersion & 0xff)]
        let nameBytes = Array(nameOverride.utf8.prefix(255))
        payload.append(UInt8(nameBytes.count))
        payload.append(contentsOf: nameBytes)
        return SimFrame(type: .identity, payload: payload)
    }

    static func surfaceInput(_ bytes: [UInt8]) -> SimFrame {
        SimFrame(type: .surfaceInput, payload: bytes)
    }

    static func midiInput(_ bytes: [UInt8]) -> SimFrame {
        SimFrame(type: .midiInput, payload: bytes)
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

    static func displayPacket(_ bytes: [UInt8]) -> SimFrame {
        SimFrame(type: .displayPacket, payload: bytes)
    }
}
