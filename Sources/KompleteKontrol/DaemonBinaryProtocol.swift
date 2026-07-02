import Foundation

public enum KKDaemonBinaryChannel: UInt8, Sendable {
    case control = 1
    case event = 2
    case display = 3
}

public enum KKDaemonBinaryMessageType: UInt16, Sendable {
    case version = 1
    case register = 2
    case unregister = 3
    case writeReport = 4
    case displayBlit = 5
    case ack = 6
    case input = 16
    case midi = 17
    case device = 18
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

public enum KKDaemonBinaryCodec {
    public static func decodeFrames(from buffer: inout [UInt8]) -> [KKDaemonBinaryFrame]? {
        var frames: [KKDaemonBinaryFrame] = []
        while buffer.count >= KKDaemonBinaryFrame.headerByteCount {
            guard buffer.readUInt32LE(at: 0) == KKDaemonBinaryFrame.magic,
                  buffer[4] == KKDaemonBinaryFrame.version,
                  let channel = KKDaemonBinaryChannel(rawValue: buffer[5]),
                  let type = KKDaemonBinaryMessageType(rawValue: buffer.readUInt16LE(at: 6)) else {
                return nil
            }
            let flags = buffer.readUInt16LE(at: 8)
            let sequence = buffer.readUInt32LE(at: 12)
            let payloadCount = Int(buffer.readUInt32LE(at: 16))
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

public final class KompleteKontrolDaemonBinaryClient: @unchecked Sendable {
    private let channel: KKDaemonBinaryChannel
    private let fd: Int32
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var nextSequence: UInt32 = 0

    public init?(
        channel: KKDaemonBinaryChannel,
        socketPath: String = KompleteKontrolLibUSBServer.defaultDaemonSocketPath
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

    public func readEvent(timeoutUsec: useconds_t = 1_000_000) -> KKDaemonBinaryFrame? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            if let frame = readFrame(until: deadline) {
                return frame
            }
        }
        return nil
    }

    private func readFrame(until deadline: Date) -> KKDaemonBinaryFrame? {
        while Date() < deadline {
            if buffer.count >= KKDaemonBinaryFrame.headerByteCount {
                guard let frames = KKDaemonBinaryCodec.decodeFrames(from: &buffer) else {
                    return nil
                }
                if let frame = frames.first {
                    if frames.count > 1 {
                        let rest = frames.dropFirst().flatMap { $0.encoded() }
                        buffer.insert(contentsOf: rest, at: 0)
                    }
                    return frame
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
                return nil
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForReadable(until: deadline) else { return nil }
                continue
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
        return nil
    }

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
            if count == 0 {
                return false
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForWritable(until: deadline) else { return false }
                continue
            }
            if errno == EINTR {
                continue
            }
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
