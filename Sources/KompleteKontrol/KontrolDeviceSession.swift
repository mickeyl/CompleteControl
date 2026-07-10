import Foundation
import KontrolUSB

/// The device seam. `DaemonHardware` reaches a device *only* through this protocol, so the
/// real libusb path and the simulator path are interchangeable and completely invisible to
/// the kqueue reactor, socket server, decoding, and reconnect logic layered above it — the
/// property of the design that makes simulation mode transparent to socket clients.
///
/// Class-bound on purpose: object identity (`===`) replaces the old
/// `libusbSession == session` staleness checks that guarded against writes racing a
/// reconnect.
protocol KontrolDeviceSession: AnyObject {
    var productID: UInt16 { get }
    var keyCount: UInt8 { get }
    var isDeviceLost: Bool { get }
    var status: KontrolUSBResult { get }
    var health: KontrolUSBResult { get }

    func write(reportID: UInt8, payload: [UInt8]) -> KontrolUSBResult
    func writeMK2DisplayBytes(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                              pixels: [UInt8], timeoutMs: UInt32) -> KontrolUSBResult
    /// Host-order RGB565 variant (the backend byte-swaps to wire order); used by the idle
    /// diagnostic which builds full frames as `[UInt16]`.
    func writeMK2DisplayPixels(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                               pixels: [UInt16], timeoutMs: UInt32) -> KontrolUSBResult
    func fillMK2Display(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                        rgb565: UInt16, timeoutMs: UInt32) -> KontrolUSBResult

    func read(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8])
    func readMIDI(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8])

    /// Begin async surface/MIDI input. The sink is invoked (off whatever thread the backend
    /// drives events on) with raw report bytes — byte-identical to the hardware, which is
    /// what keeps clients unable to tell the two apart.
    func startAsyncInput(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32
    func startAsyncMIDI(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32

    func pollFds() -> [KontrolUSBPollFd]
    func handleEvents(timeoutMs: Int)
    func close()
}

/// The real device: a thin wrapper over the opaque libusb session handle. Every method is
/// the matching `KontrolUSBLibUSBSession*` C call; behaviour is identical to before the
/// seam existed.
final class LibUSBDeviceSession: KontrolDeviceSession {
    private let ref: KontrolUSBLibUSBSessionRef
    private var inputSink: ((UnsafePointer<UInt8>, UInt32) -> Void)?
    private var midiSink: ((UnsafePointer<UInt8>, UInt32) -> Void)?

    private init(ref: KontrolUSBLibUSBSessionRef) { self.ref = ref }

    /// Open a real session, or nil with the failing result.
    static func open() -> (session: LibUSBDeviceSession?, result: KontrolUSBResult) {
        var raw: KontrolUSBLibUSBSessionRef?
        let result = KontrolUSBLibUSBSessionOpen(&raw)
        guard result.status == 0, let raw else { return (nil, result) }
        return (LibUSBDeviceSession(ref: raw), result)
    }

    var productID: UInt16 { KontrolUSBLibUSBSessionProductID(ref) }
    var keyCount: UInt8 { KontrolUSBLibUSBSessionKeyCount(ref) }
    var isDeviceLost: Bool { KontrolUSBLibUSBSessionDeviceLost(ref) != 0 }
    var status: KontrolUSBResult { KontrolUSBLibUSBSessionStatus(ref) }
    var health: KontrolUSBResult { KontrolUSBLibUSBSessionHealth(ref) }

    func write(reportID: UInt8, payload: [UInt8]) -> KontrolUSBResult {
        var bytes = payload
        return bytes.withUnsafeMutableBufferPointer { buffer in
            KontrolUSBLibUSBSessionWrite(ref, reportID, buffer.baseAddress, UInt32(buffer.count))
        }
    }

    func writeMK2DisplayBytes(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                              pixels: [UInt8], timeoutMs: UInt32) -> KontrolUSBResult {
        pixels.withUnsafeBufferPointer { buffer in
            KontrolUSBLibUSBSessionWriteMK2DisplayBytes(
                ref, screen, x, y, width, height, buffer.baseAddress, UInt32(buffer.count), timeoutMs)
        }
    }

    func writeMK2DisplayPixels(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                               pixels: [UInt16], timeoutMs: UInt32) -> KontrolUSBResult {
        pixels.withUnsafeBufferPointer { buffer in
            KontrolUSBLibUSBSessionWriteMK2Display(
                ref, screen, x, y, width, height, buffer.baseAddress, UInt32(buffer.count), timeoutMs)
        }
    }

    func fillMK2Display(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                        rgb565: UInt16, timeoutMs: UInt32) -> KontrolUSBResult {
        KontrolUSBLibUSBSessionFillMK2Display(ref, screen, x, y, width, height, rgb565, timeoutMs)
    }

    func read(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var transferred: UInt32 = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            KontrolUSBLibUSBSessionRead(ref, $0.baseAddress, UInt32($0.count), &transferred, timeoutMs)
        }
        return (result, Array(buffer.prefix(Int(transferred))))
    }

    func readMIDI(maxBytes: Int, timeoutMs: UInt32) -> (result: KontrolUSBResult, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var transferred: UInt32 = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            KontrolUSBLibUSBSessionReadMIDI(ref, $0.baseAddress, UInt32($0.count), &transferred, timeoutMs)
        }
        return (result, Array(buffer.prefix(Int(transferred))))
    }

    func startAsyncInput(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32 {
        inputSink = sink
        return KontrolUSBLibUSBSessionStartAsyncInput(
            ref, Self.inputTrampoline, Unmanaged.passUnretained(self).toOpaque())
    }

    func startAsyncMIDI(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Int32 {
        midiSink = sink
        return KontrolUSBLibUSBSessionStartAsyncMIDI(
            ref, Self.midiTrampoline, Unmanaged.passUnretained(self).toOpaque())
    }

    // The session outlives its async transfers (held by DaemonHardware.libusbSession), so an
    // unretained self pointer is safe as the callback context.
    private static let inputTrampoline: @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void = { data, length, userData in
        guard let data, let userData else { return }
        Unmanaged<LibUSBDeviceSession>.fromOpaque(userData).takeUnretainedValue().inputSink?(data, length)
    }

    private static let midiTrampoline: @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void = { data, length, userData in
        guard let data, let userData else { return }
        Unmanaged<LibUSBDeviceSession>.fromOpaque(userData).takeUnretainedValue().midiSink?(data, length)
    }

    func pollFds() -> [KontrolUSBPollFd] {
        var fds = [KontrolUSBPollFd](repeating: KontrolUSBPollFd(), count: 8)
        let count = fds.withUnsafeMutableBufferPointer {
            KontrolUSBLibUSBSessionGetPollFds(ref, $0.baseAddress, Int32($0.count))
        }
        return Array(fds.prefix(Int(max(0, count))))
    }

    func handleEvents(timeoutMs: Int) {
        KontrolUSBLibUSBHandleEventsTimeout(ref, Int32(timeoutMs))
    }

    func close() {
        KontrolUSBLibUSBSessionStopAsync(ref)
        KontrolUSBLibUSBSessionClose(ref)
    }
}
