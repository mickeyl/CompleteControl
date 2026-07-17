import Darwin
import Foundation

public enum KKDaemonBinaryChannel: UInt8, Sendable {
    case control = 1
    case event = 2
    case display = 3
    /// Test-automation input injection. Opt-in only (`CCD_ENABLE_AUTOMATION`) and absent from
    /// the daemon otherwise — see `KompleteKontrolLibUSBServer.runDaemon`.
    case automation = 4
}

public enum KKDaemonBinaryMessageType: UInt16, Sendable {
    case version = 1
    case register = 2
    case unregister = 3
    case writeReport = 4
    case displayBlit = 5
    case ack = 6
    /// Out-of-band read of the daemon's display shadow: never requires a
    /// registration and never touches the device, so it cannot disturb the
    /// connected client.
    case displaySnapshot = 7
    /// Connected-device identity (product id, key count), answered as an ack
    /// message ("product=0x1620 keys=61") like `version`.
    case deviceInfo = 8
    /// Wait until all display work queued before this request has completed and
    /// return cumulative physical transport counters in the ack message.
    case displayBarrier = 9
    case input = 16
    case midi = 17
    case device = 18
}

public struct MK2DisplayTransportMetrics: Sendable, Equatable {
    public var writeCount: UInt64
    public var byteCount: UInt64
    public var transportNanoseconds: UInt64
    public var failureCount: UInt64

    public init(
        writeCount: UInt64 = 0,
        byteCount: UInt64 = 0,
        transportNanoseconds: UInt64 = 0,
        failureCount: UInt64 = 0
    ) {
        self.writeCount = writeCount
        self.byteCount = byteCount
        self.transportNanoseconds = transportNanoseconds
        self.failureCount = failureCount
    }

    public func subtracting(_ earlier: Self) -> Self? {
        guard writeCount >= earlier.writeCount,
              byteCount >= earlier.byteCount,
              transportNanoseconds >= earlier.transportNanoseconds,
              failureCount >= earlier.failureCount else {
            return nil
        }
        return Self(
            writeCount: writeCount - earlier.writeCount,
            byteCount: byteCount - earlier.byteCount,
            transportNanoseconds: transportNanoseconds - earlier.transportNanoseconds,
            failureCount: failureCount - earlier.failureCount
        )
    }
}

public struct MK2DisplayTransportSnapshot: Sendable, Equatable {
    public var encoding: String
    public var metrics: MK2DisplayTransportMetrics

    public init(encoding: String, metrics: MK2DisplayTransportMetrics) {
        self.encoding = encoding
        self.metrics = metrics
    }

    public var barrierMessage: String {
        "display-drained encoding=\(encoding) writes=\(metrics.writeCount) bytes=\(metrics.byteCount) nanoseconds=\(metrics.transportNanoseconds) failures=\(metrics.failureCount)"
    }

    public static func parseBarrierMessage(_ message: String) -> Self? {
        var fields: [String: String] = [:]
        for token in message.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                fields[parts[0]] = parts[1]
            }
        }
        guard message.hasPrefix("display-drained "),
              let encoding = fields["encoding"],
              let writes = fields["writes"].flatMap(UInt64.init),
              let bytes = fields["bytes"].flatMap(UInt64.init),
              let nanoseconds = fields["nanoseconds"].flatMap(UInt64.init),
              let failures = fields["failures"].flatMap(UInt64.init) else {
            return nil
        }
        return Self(
            encoding: encoding,
            metrics: MK2DisplayTransportMetrics(
                writeCount: writes,
                byteCount: bytes,
                transportNanoseconds: nanoseconds,
                failureCount: failures
            )
        )
    }
}

/// Structured form of the `deviceInfo` ack message — the API a client (e.g. Paulinche's
/// about panel) uses to show which controller is connected and its firmware revision
/// without hand-parsing the wire string itself.
public struct KKDeviceInfo: Sendable, Equatable {
    public var productID: UInt16
    public var name: String
    public var family: KontrolDeviceFamily
    public var keyCount: Int
    public var padCount: Int
    public var screenCount: Int
    /// Raw `bcdDevice` from the USB device descriptor (BCD-encoded: high byte is major,
    /// low byte's nibbles are minor/patch) — the same field Native Instruments' own
    /// firmware updater reads via `IOUSBDeviceInterface.GetDeviceReleaseNumber` to show a
    /// "major.minor.patch" version string. No vendor-specific query is involved.
    public var firmwareVersionRaw: UInt16

    public init(
        productID: UInt16,
        name: String,
        family: KontrolDeviceFamily,
        keyCount: Int,
        padCount: Int,
        screenCount: Int,
        firmwareVersionRaw: UInt16
    ) {
        self.productID = productID
        self.name = name
        self.family = family
        self.keyCount = keyCount
        self.padCount = padCount
        self.screenCount = screenCount
        self.firmwareVersionRaw = firmwareVersionRaw
    }

    public var firmwareVersionString: String { Self.formatBCDVersion(firmwareVersionRaw) }

    public static func formatBCDVersion(_ value: UInt16) -> String {
        let major = (value >> 8) & 0xff
        let minor = (value & 0xf0) >> 4
        let patch = value & 0xf
        return "\(major).\(minor).\(patch)"
    }

    /// Inverse of `formatBCDVersion`: `"1.4.6"` → `0x0146`. `nil` for anything that
    /// wouldn't round-trip (wrong shape, or minor/patch outside the 0-15 nibble it encodes to).
    public static func parseBCDVersion(_ string: String) -> UInt16? {
        let parts = string.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let major = UInt16(parts[0]), major <= 0xff,
              let minor = UInt16(parts[1]), minor <= 0xf,
              let patch = UInt16(parts[2]), patch <= 0xf else {
            return nil
        }
        return (major << 8) | (minor << 4) | patch
    }

    /// Wire form of a `deviceInfo` ack message. Spaces in `name` are escaped as `_` since the
    /// message is a space-separated `key=value` list; device names never contain underscores.
    public var message: String {
        "product=0x\(String(productID, radix: 16)) name=\(name.replacingOccurrences(of: " ", with: "_")) model=\(family.rawValue) keys=\(keyCount) pads=\(padCount) screens=\(screenCount) firmware=\(firmwareVersionString)"
    }

    public static func parse(_ message: String) -> Self? {
        var fields: [String: String] = [:]
        for token in message.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                fields[parts[0]] = parts[1]
            }
        }
        guard let productHex = fields["product"], productHex.hasPrefix("0x"),
              let productID = UInt16(productHex.dropFirst(2), radix: 16),
              let name = fields["name"]?.replacingOccurrences(of: "_", with: " "),
              let familyRaw = fields["model"],
              let family = KontrolDeviceFamily(rawValue: familyRaw),
              let keyCount = fields["keys"].flatMap(Int.init),
              let padCount = fields["pads"].flatMap(Int.init),
              let screenCount = fields["screens"].flatMap(Int.init),
              let firmwareString = fields["firmware"],
              let firmwareVersionRaw = parseBCDVersion(firmwareString) else {
            return nil
        }
        return Self(
            productID: productID,
            name: name,
            family: family,
            keyCount: keyCount,
            padCount: padCount,
            screenCount: screenCount,
            firmwareVersionRaw: firmwareVersionRaw
        )
    }
}

public struct KKDaemonBinaryFrame: Sendable, Equatable {
    public static let magic: UInt32 = 0x00324b4b // "KK2\0", little endian in byte stream.
    public static let version: UInt8 = 1
    public static let headerByteCount = 20

    public var channel: KKDaemonBinaryChannel
    public var type: KKDaemonBinaryMessageType
    public var flags: UInt16
    public var sequence: UInt32
    public var payload: [UInt8]

    public init(
        channel: KKDaemonBinaryChannel,
        type: KKDaemonBinaryMessageType,
        flags: UInt16 = 0,
        sequence: UInt32,
        payload: [UInt8] = []
    ) {
        self.channel = channel
        self.type = type
        self.flags = flags
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.headerByteCount + payload.count)
        bytes.appendUInt32LE(Self.magic)
        bytes.append(Self.version)
        bytes.append(channel.rawValue)
        bytes.appendUInt16LE(type.rawValue)
        bytes.appendUInt16LE(flags)
        bytes.appendUInt16LE(0)
        bytes.appendUInt32LE(sequence)
        bytes.appendUInt32LE(UInt32(payload.count))
        bytes.append(contentsOf: payload)
        return bytes
    }
}

/// Reported to `decodeFrames`'s `onReject` closure so a caller can log which client/command
/// triggered a decode failure. The largest legitimate frame (a full-screen display blit) is
/// ~261 KB, so `maxPayloadByteCount` catches a corrupted/miscomputed length header without
/// risking real traffic — without a bound, a bad length wedges the connection forever: the
/// parser waits for bytes that will never complete the claimed frame, and every subsequent
/// byte the client sends gets appended behind it instead of being recognized as its own frame.
public enum KKDaemonBinaryDecodeRejection: Sendable {
    case malformedHeader(headBytes: [UInt8])
    case payloadTooLarge(channel: UInt8, type: UInt16, sequence: UInt32, payloadCount: Int)
}

public enum KKDaemonBinaryCodec {
    public static let maxPayloadByteCount = 1_048_576

    public static func decodeFrames(
        from buffer: inout [UInt8],
        onReject: ((KKDaemonBinaryDecodeRejection) -> Void)? = nil
    ) -> [KKDaemonBinaryFrame]? {
        var frames: [KKDaemonBinaryFrame] = []
        while buffer.count >= KKDaemonBinaryFrame.headerByteCount {
            guard buffer.readUInt32LE(at: 0) == KKDaemonBinaryFrame.magic,
                  buffer[4] == KKDaemonBinaryFrame.version,
                  let channel = KKDaemonBinaryChannel(rawValue: buffer[5]),
                  let type = KKDaemonBinaryMessageType(rawValue: buffer.readUInt16LE(at: 6)) else {
                onReject?(.malformedHeader(headBytes: Array(buffer.prefix(KKDaemonBinaryFrame.headerByteCount))))
                return nil
            }
            let flags = buffer.readUInt16LE(at: 8)
            let sequence = buffer.readUInt32LE(at: 12)
            let payloadCount = Int(buffer.readUInt32LE(at: 16))
            guard payloadCount <= maxPayloadByteCount else {
                onReject?(.payloadTooLarge(channel: buffer[5], type: buffer.readUInt16LE(at: 6), sequence: sequence, payloadCount: payloadCount))
                return nil
            }
            let total = KKDaemonBinaryFrame.headerByteCount + payloadCount
            guard buffer.count >= total else { break }
            let payload = Array(buffer[KKDaemonBinaryFrame.headerByteCount..<total])
            buffer.removeSubrange(0..<total)
            frames.append(KKDaemonBinaryFrame(channel: channel, type: type, flags: flags, sequence: sequence, payload: payload))
        }
        return frames
    }

    public static func registerPayload(pid: Int32, name: String) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendUInt32LE(UInt32(bitPattern: pid))
        let nameBytes = Array(name.utf8)
        payload.appendUInt16LE(UInt16(min(nameBytes.count, Int(UInt16.max))))
        payload.append(contentsOf: nameBytes.prefix(Int(UInt16.max)))
        return payload
    }

    public static func parseRegisterPayload(_ payload: [UInt8]) -> (pid: Int32, name: String)? {
        guard payload.count >= 6 else { return nil }
        let pid = Int32(bitPattern: payload.readUInt32LE(at: 0))
        let nameCount = Int(payload.readUInt16LE(at: 4))
        guard payload.count >= 6 + nameCount else { return nil }
        guard let name = String(bytes: payload[6..<(6 + nameCount)], encoding: .utf8), !name.isEmpty else { return nil }
        return (pid, name)
    }

    public static func ackPayload(status: Int32, message: String = "") -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendUInt32LE(UInt32(bitPattern: status))
        payload.append(contentsOf: message.utf8)
        return payload
    }

    public static func parseAckPayload(_ payload: [UInt8]) -> (status: Int32, message: String)? {
        guard payload.count >= 4 else { return nil }
        let status = Int32(bitPattern: payload.readUInt32LE(at: 0))
        let message = String(bytes: payload.dropFirst(4), encoding: .utf8) ?? ""
        return (status, message)
    }

    public static func writeReportPayload(reportID: UInt8, payload reportPayload: [UInt8]) -> [UInt8] {
        [reportID] + reportPayload
    }

    public static func parseWriteReportPayload(_ payload: [UInt8]) -> (reportID: UInt8, payload: [UInt8])? {
        guard let reportID = payload.first else { return nil }
        return (reportID, Array(payload.dropFirst()))
    }

    public static func displayBlitPayload(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        timeoutMs: UInt32,
        pixelsRGB565BE: [UInt8]
    ) -> [UInt8] {
        var payload: [UInt8] = [screen, 0]
        payload.appendUInt16LE(x)
        payload.appendUInt16LE(y)
        payload.appendUInt16LE(width)
        payload.appendUInt16LE(height)
        payload.appendUInt32LE(timeoutMs)
        payload.append(contentsOf: pixelsRGB565BE)
        return payload
    }

    public static func parseDisplayBlitPayload(_ payload: [UInt8]) -> (screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16, timeoutMs: UInt32, pixels: [UInt8])? {
        guard payload.count >= 14 else { return nil }
        let screen = payload[0]
        let x = payload.readUInt16LE(at: 2)
        let y = payload.readUInt16LE(at: 4)
        let width = payload.readUInt16LE(at: 6)
        let height = payload.readUInt16LE(at: 8)
        let timeoutMs = payload.readUInt32LE(at: 10)
        return (screen, x, y, width, height, timeoutMs, Array(payload.dropFirst(14)))
    }

    public static func displaySnapshotRequestPayload(screen: UInt8) -> [UInt8] {
        [screen]
    }

    public static func displaySnapshotResponsePayload(
        screen: UInt8,
        width: UInt16,
        height: UInt16,
        pixelsRGB565BE: [UInt8]
    ) -> [UInt8] {
        var payload: [UInt8] = [screen, 0]
        payload.appendUInt16LE(width)
        payload.appendUInt16LE(height)
        payload.append(contentsOf: pixelsRGB565BE)
        return payload
    }

    public static func parseDisplaySnapshotResponsePayload(
        _ payload: [UInt8]
    ) -> (screen: UInt8, width: UInt16, height: UInt16, pixelsRGB565BE: [UInt8])? {
        guard payload.count >= 6 else { return nil }
        let screen = payload[0]
        let width = payload.readUInt16LE(at: 2)
        let height = payload.readUInt16LE(at: 4)
        let pixels = Array(payload.dropFirst(6))
        guard pixels.count == Int(width) * Int(height) * 2 else { return nil }
        return (screen, width, height, pixels)
    }

    public static func eventPayload(timestamp: UInt64, bytes eventBytes: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendUInt64LE(timestamp)
        payload.append(contentsOf: eventBytes)
        return payload
    }

    public static func parseEventPayload(_ payload: [UInt8]) -> (timestamp: UInt64, bytes: [UInt8])? {
        guard payload.count >= 8 else { return nil }
        return (payload.readUInt64LE(at: 0), Array(payload.dropFirst(8)))
    }
}

/// The daemon owns exactly one surface, so exactly one client session may own it.
/// A session is every registered connection of one process (pid) across the three
/// channels; a registration from a new pid evicts all connections of other pids
/// ("last one wins" — the human who just launched an app is the authority).
public enum KKDaemonSessionPolicy {
    public static let evictionNotice = "evicted"

    public static func evictionVictims(
        registeredPIDs: [Int: Int32],
        newClientID: Int,
        newPID: Int32
    ) -> [Int] {
        registeredPIDs
            .filter { $0.key != newClientID && $0.value != newPID }
            .keys
            .sorted()
    }
}

extension Array where Element == UInt8 {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(value & 0xffff_ffff))
        appendUInt32LE(UInt32((value >> 32) & 0xffff_ffff))
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readUInt32LEIfAvailable(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return readUInt32LE(at: offset)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        UInt64(readUInt32LE(at: offset)) | (UInt64(readUInt32LE(at: offset + 4)) << 32)
    }
}

public enum KKDaemonBinaryReadResult: Sendable, Equatable {
    case frame(KKDaemonBinaryFrame)
    case timeout
    case disconnected
}

public final class KompleteKontrolDaemonBinaryClient: @unchecked Sendable {
    private let channel: KKDaemonBinaryChannel
    private let fd: Int32
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var nextSequence: UInt32 = 0
    private var desynced = false

    /// Set once a send times out after already writing some bytes to the socket: the frame
    /// boundary is corrupted for every send from that point on (this connection has no way
    /// to un-write what it already put on the wire), so a caller must close and reconnect
    /// rather than treat this like an ordinary slow-ack timeout.
    public var isDesynced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desynced
    }

    public init?(
        channel: KKDaemonBinaryChannel,
        socketPath: String = KompleteKontrolLibUSBServer.clientDaemonSocketPath()
    ) {
        let path = KompleteKontrolLibUSBServer.daemonSocketPath(base: socketPath, channel: channel)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard KompleteKontrolLibUSBServer.fillSunPath(&addr, socketPath: path) else {
            close(fd)
            return nil
        }

        let status = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, KompleteKontrolLibUSBServer.sockaddrLength(for: path))
            }
        }
        guard status == 0 else {
            close(fd)
            return nil
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        self.channel = channel
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    public func request(
        type: KKDaemonBinaryMessageType,
        payload: [UInt8] = [],
        timeoutUsec: useconds_t = 250_000
    ) -> (status: Int32, message: String)? {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        let sequence = nextSequence
        let frame = KKDaemonBinaryFrame(channel: channel, type: type, sequence: sequence, payload: payload)
        guard send(frame.encoded(), timeoutUsec: timeoutUsec) else { return nil }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            if let frame = readFrame(until: deadline) {
                guard frame.type == .ack, frame.sequence == sequence else { continue }
                return KKDaemonBinaryCodec.parseAckPayload(frame.payload)
            }
        }
        return nil
    }

    /// Identity and firmware revision of the currently connected controller — the API a host
    /// app (e.g. Paulinche's about panel) uses to show what it's talking to. `nil` when no
    /// device session is open or the daemon isn't reachable.
    public func deviceInfo(timeoutUsec: useconds_t = 250_000) -> KKDeviceInfo? {
        guard let response = request(type: .deviceInfo, timeoutUsec: timeoutUsec), response.status == 0 else {
            return nil
        }
        return KKDeviceInfo.parse(response.message)
    }

    public func sendDisplayBlit(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        timeoutMs: UInt32,
        pixelsRGB565BE: [UInt8],
        timeoutUsec: useconds_t = 50_000
    ) -> Bool {
        let payload = KKDaemonBinaryCodec.displayBlitPayload(
            screen: screen,
            x: x,
            y: y,
            width: width,
            height: height,
            timeoutMs: timeoutMs,
            pixelsRGB565BE: pixelsRGB565BE
        )
        guard let response = request(type: .displayBlit, payload: payload, timeoutUsec: timeoutUsec) else {
            return false
        }
        return response.status == 0
    }

    public func beginDisplayMeasurementSession(
        timeoutUsec: useconds_t = 2_000_000
    ) -> MK2DisplayTransportSnapshot? {
        displayBarrier(payload: [1], timeoutUsec: timeoutUsec)
    }

    public func waitForDisplayBarrier(
        timeoutUsec: useconds_t = 2_000_000
    ) -> MK2DisplayTransportSnapshot? {
        displayBarrier(payload: [], timeoutUsec: timeoutUsec)
    }

    public func endDisplayMeasurementSession(
        timeoutUsec: useconds_t = 2_000_000
    ) -> MK2DisplayTransportSnapshot? {
        displayBarrier(payload: [0], timeoutUsec: timeoutUsec)
    }

    private func displayBarrier(
        payload: [UInt8],
        timeoutUsec: useconds_t
    ) -> MK2DisplayTransportSnapshot? {
        guard let response = request(type: .displayBarrier, payload: payload, timeoutUsec: timeoutUsec),
              response.status == 0 else {
            return nil
        }
        return MK2DisplayTransportSnapshot.parseBarrierMessage(response.message)
    }

    public func readEvent(timeoutUsec: useconds_t = 1_000_000) -> KKDaemonBinaryFrame? {
        guard case let .frame(frame) = readEventResult(timeoutUsec: timeoutUsec) else { return nil }
        return frame
    }

    public func readEventResult(timeoutUsec: useconds_t = 1_000_000) -> KKDaemonBinaryReadResult {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            switch readFrameResult(until: deadline) {
                case let .frame(frame):
                    return .frame(frame)
                case .timeout:
                    return .timeout
                case .disconnected:
                    return .disconnected
            }
        }
        return .timeout
    }

    private func readFrame(until deadline: Date) -> KKDaemonBinaryFrame? {
        guard case let .frame(frame) = readFrameResult(until: deadline) else { return nil }
        return frame
    }

    private func readFrameResult(until deadline: Date) -> KKDaemonBinaryReadResult {
        while Date() < deadline {
            if buffer.count >= KKDaemonBinaryFrame.headerByteCount {
                guard let frames = KKDaemonBinaryCodec.decodeFrames(from: &buffer) else {
                    return .disconnected
                }
                if let frame = frames.first {
                    if frames.count > 1 {
                        let rest = frames.dropFirst().flatMap { $0.encoded() }
                        buffer.insert(contentsOf: rest, at: 0)
                    }
                    return .frame(frame)
                }
            }
            var scratch = [UInt8](repeating: 0, count: 64 * 1024)
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, scratchCount)
            }
            if count > 0 {
                buffer.append(contentsOf: scratch.prefix(count))
                continue
            }
            if count == 0 {
                return .disconnected
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForReadable(until: deadline) else { return .timeout }
                continue
            }
            if errno == EINTR {
                continue
            }
            return .disconnected
        }
        return .timeout
    }

    // Any early exit below with written > 0 but < bytes.count leaves a real prefix of this
    // frame already on the wire with no way to take it back — request()'s caller sees a
    // clean "false" and moves on to its next frame, so without desynced, that abandoned
    // prefix would silently corrupt every frame boundary from here on.
    private func send(_ bytes: [UInt8], timeoutUsec: useconds_t) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForWritable(until: deadline) else { break }
                continue
            }
            if errno == EINTR {
                continue
            }
            break
        }
        guard written == bytes.count else {
            if written > 0 { desynced = true }
            return false
        }
        return true
    }

    private func waitForReadable(until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000.0, Double(Int32.max)))))
        return result > 0 && (descriptor.revents & Int16(POLLIN | POLLERR | POLLHUP)) != 0
    }

    private func waitForWritable(until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000.0, Double(Int32.max)))))
        return result > 0 && (descriptor.revents & Int16(POLLOUT | POLLERR | POLLHUP)) != 0
    }
}
