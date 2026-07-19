import Foundation
import KontrolSimulatorWire
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// App-side virtual-device server. It accepts one daemon, presents the immutable v2 device
/// descriptor, forwards native input reports, and publishes daemon output frames.
public final class DeviceLink: @unchecked Sendable {
    public let socketPath: String
    public let descriptor: SimulatorDeviceDescriptor

    public var onFrame: ((SimFrame) -> Void)?
    public var onConnect: (() -> Void)?
    public var onDisconnect: (() -> Void)?
    public var onProtocolError: ((String) -> Void)?

    private var listenFD: Int32 = -1
    private let clientLock = NSLock()
    private var clientFD: Int32 = -1
    private var stopped = false

    public init(socketPath: String, descriptor: SimulatorDeviceDescriptor) {
        self.socketPath = socketPath
        self.descriptor = descriptor
    }

    deinit { stop() }

    public func start() -> Bool {
        guard !socketPath.isEmpty else { return false }
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }
        var noPipe: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { stop(); return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                socketPath.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { stop(); return false }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    public func stop() {
        clientLock.lock()
        stopped = true
        let activeClient = clientFD
        clientFD = -1
        let listener = listenFD
        listenFD = -1
        clientLock.unlock()
        if activeClient >= 0 { shutdown(activeClient, SHUT_RDWR); close(activeClient) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
        unlink(socketPath)
    }

    public var isConnected: Bool {
        clientLock.lock(); defer { clientLock.unlock() }
        return clientFD >= 0
    }

    public func send(_ frame: SimFrame) {
        clientLock.lock()
        defer { clientLock.unlock() }
        guard clientFD >= 0 else { return }
        guard write(frame, to: clientFD) else {
            onProtocolError?("virtual-device socket write failed")
            return
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
            clientLock.lock()
            if stopped { clientLock.unlock(); close(fd); return }
            if clientFD >= 0 { close(clientFD) }
            clientFD = fd
            clientLock.unlock()

            guard write(.hello(descriptor: descriptor), to: fd) else {
                closeClient(fd)
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.onConnect?() }
            readLoop(fd: fd)
            closeClient(fd)
            DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
        }
    }

    private func closeClient(_ fd: Int32) {
        clientLock.lock()
        let ownsDescriptor = clientFD == fd
        if ownsDescriptor { clientFD = -1 }
        clientLock.unlock()
        // `stop()` closes and relinquishes the descriptor itself. Avoid a second close here:
        // the OS may already have recycled the integer for an unrelated descriptor.
        if ownsDescriptor { close(fd) }
    }

    private func readLoop(fd: Int32) {
        let capacity = 1 << 16
        var chunk = [UInt8](repeating: 0, count: capacity)
        var buffer: [UInt8] = []
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                do {
                    let (frames, consumed) = try SimWireCodec.decodeChecked(buffer)
                    if consumed > 0 { buffer.removeFirst(consumed) }
                    if !frames.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            for frame in frames { self?.onFrame?(frame) }
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in self?.onProtocolError?(String(describing: error)) }
                    return
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                return
            }
        }
    }

    private func write(_ frame: SimFrame, to fd: Int32) -> Bool {
        let bytes = SimWireCodec.encode(frame)
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }
}
