import Darwin
import Foundation

/// Minimal line client for the ccd daemon socket: serialized request/response plus
/// asynchronous surface/MIDI push delivery.
final class DaemonLink {
    var onSurfaceReport: (([UInt8]) -> Void)?
    var onMIDIPacket: (([UInt8]) -> Void)?
    var onDeviceEvent: ((String) -> Void)?

    private let fd: Int32
    private let responseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let requestLock = NSLock()
    private var pendingResponses: [String] = []
    fileprivate var lastTextLines = ["MK2 CALIBRATE", "", "", ""]

    init?(socketPath: String = "/var/run/kompletekontrol-libusb.sock") {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for index in 0..<min(pathBytes.count, raw.count - 1) {
                raw[index] = pathBytes[index]
            }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    func start() {
        Thread.detachNewThread { [self] in readLoop() }
    }

    @discardableResult
    func request(_ line: String, timeout: TimeInterval = 3.0) -> String? {
        requestLock.lock()
        defer { requestLock.unlock() }
        let bytes = Array((line + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            guard count > 0 else { return nil }
            written += count
        }
        guard responseSemaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return pendingResponses.isEmpty ? nil : pendingResponses.removeFirst()
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                dispatch(line)
            }
        }
    }

    private func dispatch(_ line: String) {
        if line.hasPrefix("in @") {
            onSurfaceReport?(Self.payloadBytes(line))
        } else if line.hasPrefix("midi @") {
            onMIDIPacket?(Self.payloadBytes(line))
        } else if line.hasPrefix("device ") {
            onDeviceEvent?(line)
        } else {
            lock.lock()
            pendingResponses.append(line)
            lock.unlock()
            responseSemaphore.signal()
        }
    }

    private static func payloadBytes(_ line: String) -> [UInt8] {
        line.split(separator: " ").dropFirst(2).compactMap { UInt8($0, radix: 16) }
    }
}

extension DaemonLink {
    @discardableResult
    func writeReport(_ reportID: UInt8, _ payload: [UInt8]) -> Bool {
        let line = (["write", Self.hex(reportID)] + payload.map(Self.hex)).joined(separator: " ")
        return request(line) == "ok"
    }

    /// Two lines per display; the daemon's 5x7 font covers 0-9 and A-Z minus J.
    @discardableResult
    func showText(_ line0a: String, _ line0b: String, _ line1a: String = "", _ line1b: String = "") -> Bool {
        lastTextLines = [line0a, line0b, line1a, line1b]
        let line = ["mk2text", Self.textToken(line0a), Self.textToken(line0b), Self.textToken(line1a), Self.textToken(line1b)].joined(separator: " ")
        return request(line) == "ok"
    }

    func reshowLastText() {
        let lines = lastTextLines
        showText(lines[0], lines[1], lines[2], lines[3])
    }

    static func hex(_ byte: UInt8) -> String {
        String(format: "%02x", byte)
    }

    private static func textToken(_ text: String) -> String {
        text.isEmpty ? "-" : text.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
