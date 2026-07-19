import Foundation
import KompleteKontrol
import KontrolSimulatorWire

public struct SimulatorFramebufferSnapshot: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixelsBE: [UInt8]
}

public final class SimulatorFramebuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let lock = NSLock()
    private var pixelsBE: [UInt8]

    public init(width: Int = 480, height: Int = 272) {
        self.width = width
        self.height = height
        pixelsBE = [UInt8](repeating: 0, count: width * height * 2)
    }

    public func blit(x: Int, y: Int, width blitWidth: Int, height blitHeight: Int, pixels source: [UInt8]) {
        guard x >= 0, y >= 0, blitWidth > 0, blitHeight > 0,
              x + blitWidth <= width, y + blitHeight <= height,
              source.count == blitWidth * blitHeight * 2 else { return }
        lock.lock()
        for row in 0..<blitHeight {
            let sourceStart = row * blitWidth * 2
            let targetStart = ((y + row) * width + x) * 2
            pixelsBE.replaceSubrange(
                targetStart..<(targetStart + blitWidth * 2),
                with: source[sourceStart..<(sourceStart + blitWidth * 2)]
            )
        }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        pixelsBE = [UInt8](repeating: 0, count: pixelsBE.count)
        lock.unlock()
    }

    public func snapshot() -> SimulatorFramebufferSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SimulatorFramebufferSnapshot(width: width, height: height, pixelsBE: pixelsBE)
    }
}

public struct SimulatorLampSnapshot: Sendable, Equatable {
    public var buttonBytes: [UInt8]
    public var stripAndPadBytes: [UInt8]
    public var lightGuideBytes: [UInt8]
}

/// Reduces native daemon output into device-neutral display buffers plus native lamp bytes.
public final class SimulatorOutputState: @unchecked Sendable {
    public let definition: SimulatorDeviceDefinition
    public let screens = [SimulatorFramebuffer(), SimulatorFramebuffer()]

    private let lock = NSLock()
    private let packetDecoder = MK2DisplayPacketDecoder()
    private var buttonBytes: [UInt8]
    private var stripAndPadBytes: [UInt8]
    private var lightGuideBytes: [UInt8]

    public init(definition: SimulatorDeviceDefinition) {
        self.definition = definition
        switch definition.kind {
            case .maschineMK3:
                buttonBytes = MaschineMK3Protocol.clearedButtonLEDPayload()
                stripAndPadBytes = MaschineMK3Protocol.clearedStripLEDPayload()
                lightGuideBytes = []
            case .kompleteKontrolS61MK2:
                buttonBytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
                stripAndPadBytes = []
                lightGuideBytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        }
    }

    @discardableResult
    public func apply(_ frame: SimFrame) throws -> Bool {
        switch frame.type {
            case .displayBlit:
                guard frame.payload.count >= 9 else { return false }
                let screen = Int(frame.payload[0])
                let x = Self.u16(frame.payload, 1), y = Self.u16(frame.payload, 3)
                let width = Self.u16(frame.payload, 5), height = Self.u16(frame.payload, 7)
                guard screens.indices.contains(screen) else { return false }
                let pixels = Array(frame.payload.dropFirst(9))
                screens[screen].blit(x: x, y: y, width: width, height: height, pixels: pixels)
                packetDecoder.record(MK2DecodedDisplayBlit(
                    screen: UInt8(screen), x: UInt16(x), y: UInt16(y),
                    width: UInt16(width), height: UInt16(height), pixelsBE: pixels
                ))
                return true
            case .displayPacket:
                let blit = try packetDecoder.decodeAndApply(frame.payload)
                let screen = Int(blit.screen)
                guard screens.indices.contains(screen) else { return false }
                screens[screen].blit(
                    x: Int(blit.x), y: Int(blit.y), width: Int(blit.width),
                    height: Int(blit.height), pixels: blit.pixelsBE
                )
                return true
            case .report:
                guard let reportID = frame.payload.first else { return false }
                applyReport(reportID: reportID, bytes: Array(frame.payload.dropFirst()))
                return true
            default:
                return false
        }
    }

    public func clear() {
        for screen in screens { screen.clear() }
        lock.lock()
        buttonBytes.indices.forEach { buttonBytes[$0] = 0 }
        stripAndPadBytes.indices.forEach { stripAndPadBytes[$0] = 0 }
        lightGuideBytes.indices.forEach { lightGuideBytes[$0] = 0 }
        lock.unlock()
    }

    public func lampSnapshot() -> SimulatorLampSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SimulatorLampSnapshot(
            buttonBytes: buttonBytes,
            stripAndPadBytes: stripAndPadBytes,
            lightGuideBytes: lightGuideBytes
        )
    }

    private func applyReport(reportID: UInt8, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        switch definition.kind {
            case .maschineMK3:
                if reportID == MaschineMK3Protocol.buttonLEDReportID {
                    buttonBytes.replacePrefix(with: bytes)
                } else if reportID == MaschineMK3Protocol.stripLEDReportID {
                    stripAndPadBytes.replacePrefix(with: bytes)
                }
            case .kompleteKontrolS61MK2:
                if reportID == UInt8(KompleteKontrolMK2Protocol.buttonLEDReportID) {
                    buttonBytes.replacePrefix(with: bytes)
                } else if reportID == UInt8(KompleteKontrolMK2Protocol.lightGuideReportID) {
                    lightGuideBytes.replacePrefix(with: bytes)
                }
        }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
}

private extension Array where Element == UInt8 {
    mutating func replacePrefix(with source: [UInt8]) {
        for index in 0..<Swift.min(count, source.count) { self[index] = source[index] }
    }
}
