import Foundation
import KontrolUSB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A `KontrolDeviceSession` backed by a Unix-socket connection to the `KontrolSimulator`
/// app instead of a real USB device. Output (display blits, LED/guide reports) is forwarded
/// as wire frames; version-2 input is already native report data, so the daemon — and every
/// socket client above it — behaves exactly as with hardware. Legacy semantic MK2 frames are
/// temporarily retained for the existing KONTROL panel.
///
/// The connection's fd participates in the daemon's kqueue reactor exactly where libusb
/// pollfds do (`pollFds()`), and a closed socket surfaces as device-loss, so unplugging the
/// simulator (closing its window) drives the same reconnect path as a real unplug.
final class SimulatorDeviceSession: KontrolDeviceSession {
    static let defaultSocketPath = SimEndpoint.defaultSocketPath

    static let defaultDescriptor = SimulatorDeviceDescriptor(
        productID: 0x1620,
        keyCount: 61,
        firmwareVersion: 0x0060,
        instanceID: "tests",
        capabilities: [.rawSurfaceInput, .rawMIDIInput, .displayBlits, .displayPackets, .outputReports]
    )

    private let fd: Int32
    private let descriptor: SimulatorDeviceDescriptor
    private let displayPacketEncoder: MK2DisplayPacketEncoder?
    private let lock = NSLock()          // guards `lost` and the identity override below
    private let sendLock = NSLock()      // serializes frames from display/state queues
    private let displayPacketLock = NSLock()
    private var lostFlag = false

    // Overridden by an `.identity` frame from the simulator's "Device Identity…" settings
    // dialog. Defaults to the bench-verified S61 MK2 bcdDevice 0x0060 (firmware 0.6.0; see
    // Docs/Komplete-Kontrol-Protocol-Guide.md) until overridden.
    private var firmwareVersionOverride: UInt16
    private var nameOverride: String?

    // Reactor-thread only (handleEvents): the running input state + partial read buffer.
    private var builder = MK2InputReportBuilder()
    private var readBuffer: [UInt8] = []
    private var inputSink: ((UnsafePointer<UInt8>, UInt32) -> Void)?
    private var midiSink: ((UnsafePointer<UInt8>, UInt32) -> Void)?

    // Internal (not private) so tests can drive a session over a socketpair without a
    // listening simulator.
    init(
        fd: Int32,
        descriptor: SimulatorDeviceDescriptor = SimulatorDeviceSession.defaultDescriptor,
        initialReadBuffer: [UInt8] = [],
        displayEncodingSelection: MK2DisplayEncodingSelection = .resolve()
    ) {
        self.fd = fd
        self.descriptor = descriptor
        firmwareVersionOverride = descriptor.firmwareVersion
        nameOverride = descriptor.reportedName
        readBuffer = initialReadBuffer
        displayPacketEncoder = displayEncodingSelection.mode == .adaptive ? MK2DisplayPacketEncoder() : nil
    }

    static func open(socketPath: String) -> (session: SimulatorDeviceSession?, result: KontrolUSBResult) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, makeResult(status: -1, "sim socket() failed errno=\(errno)")) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            Darwin.close(fd)
            return (nil, makeResult(status: -1, "sim socket path too long"))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                socketPath.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            // Not present yet (simulator app not running) → the daemon retries, same as an
            // unplugged device.
            return (nil, makeResult(status: -4, "simulator not present at \(socketPath) errno=\(errno)"))
        }
        let handshake: SimulatorDeviceDescriptor
        let trailingBytes: [UInt8]
        do {
            (handshake, trailingBytes) = try receiveHandshake(fd: fd, timeoutMs: 1500)
            guard handshake.wireVersion == SimWireProtocol.currentVersion else {
                throw SimWireError.versionMismatch(handshake.wireVersion)
            }
            guard KontrolDeviceProfile.productID(
                handshake.productID,
                reportedKeyCount: handshake.keyCount
            ) != nil else {
                throw HandshakeError.unsupportedProduct(handshake.productID)
            }
            guard handshake.capabilities.contains(.rawSurfaceInput) else {
                throw HandshakeError.missingRawSurfaceInput
            }
        } catch {
            Darwin.close(fd)
            return (nil, makeResult(status: -2, "simulator handshake rejected: \(error)"))
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return (
            SimulatorDeviceSession(fd: fd, descriptor: handshake, initialReadBuffer: trailingBytes),
            makeResult(status: 0, "simulator connected at \(socketPath) product=0x\(String(handshake.productID, radix: 16))")
        )
    }

    // MARK: Metadata

    var productID: UInt16 { descriptor.productID }
    var keyCount: UInt8 { descriptor.keyCount }
    var firmwareVersion: UInt16 { lock.lock(); defer { lock.unlock() }; return firmwareVersionOverride }
    var deviceProfile: KontrolDeviceProfile {
        var profile = KontrolDeviceProfile.productID(productID, reportedKeyCount: keyCount)!
        lock.lock(); let override = nameOverride; lock.unlock()
        if let override { profile.name = override }
        return profile
    }
    var isDeviceLost: Bool { lock.lock(); defer { lock.unlock() }; return lostFlag }
    var status: KontrolUSBResult { Self.makeResult(status: isDeviceLost ? -4 : 0, "simulator") }
    var health: KontrolUSBResult { status }

    private func markLost() {
        lock.lock(); lostFlag = true; lock.unlock()
    }

    // MARK: Output

    func write(reportID: UInt8, payload: [UInt8]) -> KontrolUSBResult {
        send(.report(reportID: reportID, bytes: payload))
    }

    func writeMK2DisplayBytes(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                              pixels: [UInt8], timeoutMs: UInt32) -> KontrolUSBResult {
        var result: KontrolUSBResult
        if let displayPacketEncoder {
            displayPacketLock.lock()
            defer { displayPacketLock.unlock() }
            guard let packet = displayPacketEncoder.encode(
                screen: screen,
                x: x,
                y: y,
                width: width,
                height: height,
                pixelsBE: pixels
            ) else {
                return Self.makeResult(status: -2, "invalid adaptive MK2 display rectangle")
            }
            result = send(.displayPacket(packet.bytes))
            if result.status == 0 {
                displayPacketEncoder.commit(packet)
                result.transferredBytes = UInt32(packet.bytes.count)
            }
        } else {
            result = send(.displayBlit(
                screen: screen,
                x: x,
                y: y,
                width: width,
                height: height,
                pixelsBE: pixels
            ))
            if result.status == 0 {
                result.transferredBytes = UInt32(pixels.count + 36)
            }
        }
        if result.status == 0 {
            MK2DisplayShadow.shared.recordBytes(screen: screen, x: x, y: y, width: width, height: height, pixelsBE: pixels)
        }
        return result
    }

    func writeMK2DisplayPixels(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                               pixels: [UInt16], timeoutMs: UInt32) -> KontrolUSBResult {
        var be = [UInt8]()
        be.reserveCapacity(pixels.count * 2)
        for pixel in pixels {
            be.append(UInt8(pixel >> 8))
            be.append(UInt8(pixel & 0xff))
        }
        return writeMK2DisplayBytes(screen: screen, x: x, y: y, width: width, height: height, pixels: be, timeoutMs: timeoutMs)
    }

    func fillMK2Display(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                        rgb565: UInt16, timeoutMs: UInt32) -> KontrolUSBResult {
        let count = Int(width) * Int(height)
        var be = [UInt8]()
        be.reserveCapacity(count * 2)
        let hi = UInt8(rgb565 >> 8), lo = UInt8(rgb565 & 0xff)
        for _ in 0..<count { be.append(hi); be.append(lo) }
        return writeMK2DisplayBytes(screen: screen, x: x, y: y, width: width, height: height, pixels: be, timeoutMs: timeoutMs)
    }

    // The synchronous diagnostic reads have no simulator analogue; report timeout.
    func read(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8]) {
        (Self.makeResult(status: -7, "sim timeout"), [])
    }

    func readMIDI(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8]) {
        (Self.makeResult(status: -7, "sim timeout"), [])
    }

    // MARK: Async input

    func startAsyncInput(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32 {
        inputSink = sink
        return 0
    }

    func startAsyncMIDI(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32 {
        midiSink = sink
        return 0
    }

    // MARK: Reactor

    func pollFds() -> [KontrolUSBPollFd] {
        [KontrolUSBPollFd(fd: fd, events: UInt16(POLLIN))]
    }

    func handleEvents(timeoutMs: Int) {
        drainSocket()
        do {
            let (frames, consumed) = try SimWireCodec.decodeChecked(readBuffer)
            if consumed > 0 { readBuffer.removeFirst(consumed) }
            for frame in frames { apply(frame) }
        } catch {
            readBuffer.removeAll(keepingCapacity: false)
            markLost()
        }
    }

    @discardableResult
    func cancelPendingOutput() -> Int32 { 0 }

    func close() {
        Darwin.close(fd)
    }

    // MARK: - Internals

    private func drainSocket() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
            if n > 0 {
                readBuffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                markLost() // EOF: simulator window closed → device-loss
                return
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { markLost() }
                return
            }
        }
    }

    // Lower one semantic input frame into a state change and emit the updated raw report.
    // The actual byte-level lowering is shared with the daemon's automation-socket handler —
    // see MK2InputFrameLowering. `.identity` is session-local state (what deviceInfo reports),
    // not an input gesture, so it's handled here rather than in the shared lowering.
    private func apply(_ frame: SimFrame) {
        if frame.type == .identity {
            applyIdentity(frame.payload)
            return
        }
        if frame.type == .surfaceInput {
            emit(frame.payload, to: inputSink)
            return
        }
        if frame.type == .midiInput {
            guard descriptor.capabilities.contains(.rawMIDIInput) else { return }
            emit(frame.payload, to: midiSink)
            return
        }
        guard deviceProfile.family == .kompleteKontrolMK2 else { return }
        MK2InputFrameLowering.apply(
            frame,
            builder: &builder,
            emitInput: { data, length in self.inputSink?(data, length) },
            emitMIDI: { data, length in self.midiSink?(data, length) }
        )
    }

    private func applyIdentity(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        let firmwareVersion = (UInt16(payload[0]) << 8) | UInt16(payload[1])
        let nameLength = Int(payload[2])
        guard payload.count >= 3 + nameLength else { return }
        let name = String(bytes: payload[3..<(3 + nameLength)], encoding: .utf8) ?? ""
        lock.lock()
        firmwareVersionOverride = firmwareVersion
        nameOverride = name.isEmpty ? nil : name
        lock.unlock()
    }

    private func emit(
        _ bytes: [UInt8],
        to sink: ((UnsafePointer<UInt8>, UInt32) -> Void)?
    ) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            sink?(baseAddress, UInt32(buffer.count))
        }
    }

    private enum HandshakeError: Error, CustomStringConvertible {
        case timeout
        case disconnected
        case firstFrameWasNotHello
        case unsupportedProduct(UInt16)
        case missingRawSurfaceInput

        var description: String {
            switch self {
                case .timeout: "timeout"
                case .disconnected: "disconnected"
                case .firstFrameWasNotHello: "first frame was not hello"
                case let .unsupportedProduct(productID): "unsupported product 0x\(String(productID, radix: 16))"
                case .missingRawSurfaceInput: "raw surface-input capability missing"
            }
        }
    }

    private static func receiveHandshake(
        fd: Int32,
        timeoutMs: Int32
    ) throws -> (descriptor: SimulatorDeviceDescriptor, trailingBytes: [UInt8]) {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1000
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 {
                if errno == EINTR { continue }
                throw HandshakeError.disconnected
            }
            if ready == 0 { continue }
            let chunkCapacity = chunk.count
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunkCapacity) }
            if count == 0 { throw HandshakeError.disconnected }
            if count < 0 {
                if errno == EINTR { continue }
                throw HandshakeError.disconnected
            }
            buffer.append(contentsOf: chunk[0..<count])
            let decoded = try SimWireCodec.decodeChecked(buffer)
            guard let frame = decoded.frames.first else { continue }
            guard frame.type == .hello else { throw HandshakeError.firstFrameWasNotHello }
            let frameLength = 5 + frame.payload.count
            return (
                try SimulatorDeviceDescriptor(payload: frame.payload),
                Array(buffer.dropFirst(frameLength))
            )
        }
        throw HandshakeError.timeout
    }

    @discardableResult
    private func send(_ frame: SimFrame) -> KontrolUSBResult {
        let bytes = SimWireCodec.encode(frame)
        sendLock.lock()
        defer { sendLock.unlock() }
        var offset = 0
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            while offset < bytes.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Socket buffer full (large blit): wait for writability rather than spin.
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !ok {
            markLost()
            return Self.makeResult(status: -1, "simulator send failed")
        }
        return Self.makeResult(status: 0, "ok")
    }

    private static func makeResult(status: Int32, _ message: String) -> KontrolUSBResult {
        var result = KontrolUSBResult()
        result.status = status
        withUnsafeMutableBytes(of: &result.message) { raw in
            let bytes = Array(message.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return result
    }
}
