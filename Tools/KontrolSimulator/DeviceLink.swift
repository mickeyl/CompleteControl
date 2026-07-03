import Foundation
import KompleteKontrol
#if canImport(Darwin)
import Darwin
#endif

/// The simulator's side of the device wire protocol: a Unix-socket *server* the daemon
/// connects to as its "virtual device". Accepts one `ccd` connection, decodes its output
/// frames (display blits, LED reports) onto the main queue, and sends the panel's semantic
/// input frames back.
final class DeviceLink {
    let socketPath: String

    var onFrame: ((SimFrame) -> Void)?   // delivered on the main queue
    var onConnect: (() -> Void)?         // main queue
    var onDisconnect: (() -> Void)?      // main queue

    private var listenFD: Int32 = -1
    private let clientLock = NSLock()
    private var clientFD: Int32 = -1

    init(socketPath: String) { self.socketPath = socketPath }

    func start() -> Bool {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { return false }
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
        guard bound == 0, listen(listenFD, 1) == 0 else { return false }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    var isConnected: Bool {
        clientLock.lock(); defer { clientLock.unlock() }
        return clientFD >= 0
    }

    func send(_ frame: SimFrame) {
        clientLock.lock(); let fd = clientFD; clientLock.unlock()
        guard fd >= 0 else { return }
        let bytes = SimWireCodec.encode(frame)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                break
            }
            clientLock.lock()
            if clientFD >= 0 { Darwin.close(clientFD) }
            clientFD = fd
            clientLock.unlock()

            DispatchQueue.main.async { [weak self] in self?.onConnect?() }
            send(.hello(productID: 0x1620, keyCount: 61))
            readLoop(fd: fd)

            clientLock.lock()
            if clientFD == fd { clientFD = -1 }
            Darwin.close(fd)
            clientLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
        }
    }

    private func readLoop(fd: Int32) {
        let capacity = 1 << 16
        var chunk = [UInt8](repeating: 0, count: capacity)
        var buffer: [UInt8] = []
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                let (frames, consumed) = SimWireCodec.decode(buffer)
                if consumed > 0 { buffer.removeFirst(consumed) }
                if !frames.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        for frame in frames { self?.onFrame?(frame) }
                    }
                }
            } else if n == 0 {
                return // ccd disconnected
            } else {
                if errno == EINTR { continue }
                return
            }
        }
    }
}
