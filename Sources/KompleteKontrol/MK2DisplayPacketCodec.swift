import Foundation

enum MK2DisplayEncodingMode: String, Sendable {
    case legacy
    case adaptive
}

struct MK2DisplayEncodingSelection: Sendable, Equatable {
    static let environmentKey = "KK_MK2_DISPLAY_ENCODING"

    let mode: MK2DisplayEncodingMode
    let requestedValue: String?
    let fellBackToLegacy: Bool

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let requested = environment[environmentKey], !requested.isEmpty else {
            return Self(mode: .legacy, requestedValue: nil, fellBackToLegacy: false)
        }
        guard let mode = MK2DisplayEncodingMode(rawValue: requested.lowercased()) else {
            return Self(mode: .legacy, requestedValue: requested, fellBackToLegacy: true)
        }
        return Self(mode: mode, requestedValue: requested, fellBackToLegacy: false)
    }
}

struct MK2DisplayPacketMetrics: Sendable, Equatable {
    static let fixedTransferMilliseconds = 0.44
    static let millisecondsPerByte = 0.000_063_4

    let legacyBytes: Int
    let encodedBytes: Int
    let literalPairs: Int
    let repeatPairs: Int
    let skippedPairs: Int
    let segmentCount: Int
    let usedAdaptiveEncoding: Bool

    var savedBytes: Int { legacyBytes - encodedBytes }
    var estimatedLegacyMilliseconds: Double {
        Self.fixedTransferMilliseconds + Double(legacyBytes) * Self.millisecondsPerByte
    }
    var estimatedEncodedMilliseconds: Double {
        Self.fixedTransferMilliseconds + Double(encodedBytes) * Self.millisecondsPerByte
    }
    var estimatedSavedMilliseconds: Double {
        estimatedLegacyMilliseconds - estimatedEncodedMilliseconds
    }
}

struct MK2EncodedDisplayPacket: Sendable, Equatable {
    let screen: UInt8
    let x: UInt16
    let y: UInt16
    let width: UInt16
    let height: UInt16
    let pixelsBE: [UInt8]
    let bytes: [UInt8]
    let metrics: MK2DisplayPacketMetrics
}

/// Stateful adaptive packet builder for one physical device session. Encoding is pure with
/// respect to the shadow; callers commit only after the complete transport write succeeds.
final class MK2DisplayPacketEncoder {
    private enum Segment {
        case literal(startPair: Int, count: Int)
        case repeated(startPair: Int, count: Int)
        case skipped(count: Int)

        var count: Int {
            switch self {
                case let .literal(_, count), let .repeated(_, count), let .skipped(count): count
            }
        }
    }

    private static let screenCount = 2
    private static let displayWidth = KompleteKontrolMK2Protocol.displayWidth
    private static let displayHeight = KompleteKontrolMK2Protocol.displayHeight
    private static let frameByteCount = displayWidth * displayHeight * 2
    private static let legacyOverheadBytes = 36

    private var frames = Array(
        repeating: [UInt8](repeating: 0, count: frameByteCount),
        count: screenCount
    )
    private var hasFrame = Array(repeating: false, count: screenCount)

    func encode(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        pixelsBE: [UInt8]
    ) -> MK2EncodedDisplayPacket? {
        let screenIndex = Int(screen)
        let rectX = Int(x), rectY = Int(y), rectWidth = Int(width), rectHeight = Int(height)
        let pixelCount = rectWidth * rectHeight
        guard screenIndex >= 0, screenIndex < Self.screenCount,
              rectWidth > 0, rectHeight > 0,
              rectX >= 0, rectY >= 0,
              rectX + rectWidth <= Self.displayWidth,
              rectY + rectHeight <= Self.displayHeight,
              pixelCount.isMultiple(of: 2), pixelCount / 2 <= Int(UInt16.max),
              pixelsBE.count == pixelCount * 2 else {
            return nil
        }

        let pairCount = pixelCount / 2
        let canSkip = hasFrame[screenIndex]
        var segments: [Segment] = []
        segments.reserveCapacity(16)
        var pair = 0

        while pair < pairCount {
            if canSkip && pairMatchesShadow(
                pair,
                screen: screenIndex,
                x: rectX,
                y: rectY,
                width: rectWidth,
                pixelsBE: pixelsBE
            ) {
                let start = pair
                pair += 1
                while pair < pairCount,
                      pairMatchesShadow(
                          pair,
                          screen: screenIndex,
                          x: rectX,
                          y: rectY,
                          width: rectWidth,
                          pixelsBE: pixelsBE
                      ) {
                    pair += 1
                }
                segments.append(.skipped(count: pair - start))
                continue
            }

            if pair + 1 < pairCount && inputPairsEqual(pair, pair + 1, pixelsBE: pixelsBE) {
                let start = pair
                pair += 2
                while pair < pairCount && inputPairsEqual(start, pair, pixelsBE: pixelsBE) {
                    pair += 1
                }
                segments.append(.repeated(startPair: start, count: pair - start))
                continue
            }

            let start = pair
            pair += 1
            while pair < pairCount {
                if canSkip && pairMatchesShadow(
                    pair,
                    screen: screenIndex,
                    x: rectX,
                    y: rectY,
                    width: rectWidth,
                    pixelsBE: pixelsBE
                ) {
                    break
                }
                if pair + 1 < pairCount && inputPairsEqual(pair, pair + 1, pixelsBE: pixelsBE) {
                    break
                }
                pair += 1
            }
            segments.append(.literal(startPair: start, count: pair - start))
        }

        var literalPairs = 0
        var repeatPairs = 0
        var skippedPairs = 0
        var adaptiveByteCount = 16 + 12
        for segment in segments {
            switch segment {
                case let .literal(_, count):
                    literalPairs += count
                    adaptiveByteCount += 4 + count * 4
                case let .repeated(_, count):
                    repeatPairs += count
                    adaptiveByteCount += 8
                case let .skipped(count):
                    skippedPairs += count
                    adaptiveByteCount += 4
            }
        }
        let legacyByteCount = Self.legacyOverheadBytes + pixelsBE.count
        let useAdaptive = adaptiveByteCount < legacyByteCount
        let chosenBytes: [UInt8]
        if useAdaptive {
            chosenBytes = buildPacket(
                screen: screen,
                x: x,
                y: y,
                width: width,
                height: height,
                pixelsBE: pixelsBE,
                segments: segments,
                byteCount: adaptiveByteCount
            )
        } else {
            chosenBytes = buildLegacyPacket(
                screen: screen,
                x: x,
                y: y,
                width: width,
                height: height,
                pixelsBE: pixelsBE
            )
        }
        let metrics = MK2DisplayPacketMetrics(
            legacyBytes: legacyByteCount,
            encodedBytes: chosenBytes.count,
            literalPairs: useAdaptive ? literalPairs : pairCount,
            repeatPairs: useAdaptive ? repeatPairs : 0,
            skippedPairs: useAdaptive ? skippedPairs : 0,
            segmentCount: useAdaptive ? segments.count : 1,
            usedAdaptiveEncoding: useAdaptive
        )
        return MK2EncodedDisplayPacket(
            screen: screen,
            x: x,
            y: y,
            width: width,
            height: height,
            pixelsBE: pixelsBE,
            bytes: chosenBytes,
            metrics: metrics
        )
    }

    func commit(_ packet: MK2EncodedDisplayPacket) {
        record(
            screen: packet.screen,
            x: packet.x,
            y: packet.y,
            width: packet.width,
            height: packet.height,
            pixelsBE: packet.pixelsBE
        )
    }

    private func pairMatchesShadow(
        _ pair: Int,
        screen: Int,
        x: Int,
        y: Int,
        width: Int,
        pixelsBE: [UInt8]
    ) -> Bool {
        let firstPixel = pair * 2
        for pixelOffset in 0..<2 {
            let rectPixel = firstPixel + pixelOffset
            let row = rectPixel / width
            let column = rectPixel % width
            let source = rectPixel * 2
            let destination = ((y + row) * Self.displayWidth + x + column) * 2
            if pixelsBE[source] != frames[screen][destination]
                || pixelsBE[source + 1] != frames[screen][destination + 1] {
                return false
            }
        }
        return true
    }

    private func inputPairsEqual(_ lhs: Int, _ rhs: Int, pixelsBE: [UInt8]) -> Bool {
        let left = lhs * 4
        let right = rhs * 4
        return pixelsBE[left] == pixelsBE[right]
            && pixelsBE[left + 1] == pixelsBE[right + 1]
            && pixelsBE[left + 2] == pixelsBE[right + 2]
            && pixelsBE[left + 3] == pixelsBE[right + 3]
    }

    private func buildPacket(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        pixelsBE: [UInt8],
        segments: [Segment],
        byteCount: Int
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        appendHeader(to: &bytes, screen: screen, x: x, y: y, width: width, height: height)
        for segment in segments {
            switch segment {
                case let .literal(startPair, count):
                    appendToken(to: &bytes, opcode: 0x00, pairCount: count)
                    let start = startPair * 4
                    bytes.append(contentsOf: pixelsBE[start..<(start + count * 4)])
                case let .repeated(startPair, count):
                    appendToken(to: &bytes, opcode: 0x01, pairCount: count)
                    let start = startPair * 4
                    bytes.append(contentsOf: pixelsBE[start..<(start + 4)])
                case let .skipped(count):
                    appendToken(to: &bytes, opcode: 0x02, pairCount: count)
            }
        }
        appendFooter(to: &bytes)
        return bytes
    }

    /// Reproduces the pre-adaptive packet byte-for-byte, including its leading zero skip.
    private func buildLegacyPacket(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        pixelsBE: [UInt8]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.legacyOverheadBytes + pixelsBE.count)
        appendHeader(to: &bytes, screen: screen, x: x, y: y, width: width, height: height)
        appendToken(to: &bytes, opcode: 0x02, pairCount: 0)
        appendToken(to: &bytes, opcode: 0x00, pairCount: pixelsBE.count / 4)
        bytes.append(contentsOf: pixelsBE)
        appendFooter(to: &bytes)
        return bytes
    }

    private func appendHeader(
        to bytes: inout [UInt8],
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        bytes.append(contentsOf: [0x84, 0x00, screen, 0x60, 0x00, 0x00, 0x00, 0x00])
        appendBE16(x, to: &bytes)
        appendBE16(y, to: &bytes)
        appendBE16(width, to: &bytes)
        appendBE16(height, to: &bytes)
    }

    private func appendFooter(to bytes: inout [UInt8]) {
        appendToken(to: &bytes, opcode: 0x02, pairCount: 0)
        appendToken(to: &bytes, opcode: 0x03, pairCount: 0)
        appendToken(to: &bytes, opcode: 0x40, pairCount: 0)
    }

    private func appendToken(to bytes: inout [UInt8], opcode: UInt8, pairCount: Int) {
        bytes.append(opcode)
        bytes.append(UInt8((pairCount >> 16) & 0xff))
        bytes.append(UInt8((pairCount >> 8) & 0xff))
        bytes.append(UInt8(pairCount & 0xff))
    }

    private func appendBE16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private func record(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        pixelsBE: [UInt8]
    ) {
        let screenIndex = Int(screen)
        let rectX = Int(x), rectY = Int(y), rectWidth = Int(width), rectHeight = Int(height)
        guard screenIndex >= 0, screenIndex < Self.screenCount else { return }
        frames[screenIndex].withUnsafeMutableBufferPointer { destination in
            pixelsBE.withUnsafeBufferPointer { source in
                for row in 0..<rectHeight {
                    let destinationStart = destination.baseAddress!
                        + ((rectY + row) * Self.displayWidth + rectX) * 2
                    destinationStart.update(
                        from: source.baseAddress! + row * rectWidth * 2,
                        count: rectWidth * 2
                    )
                }
            }
        }
        hasFrame[screenIndex] = true
    }
}

public struct MK2DecodedDisplayBlit: Sendable, Equatable {
    public let screen: UInt8
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16
    public let pixelsBE: [UInt8]

    public init(
        screen: UInt8,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        pixelsBE: [UInt8]
    ) {
        self.screen = screen
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelsBE = pixelsBE
    }
}

public enum MK2DisplayPacketDecodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
            case let .malformed(message): message
        }
    }
}

/// Independent strict reference decoder used by the simulator and protocol tests. It owns
/// its own framebuffer so `skip` retains exactly the pixels a device would already show.
public final class MK2DisplayPacketDecoder: @unchecked Sendable {
    private static let screenCount = 2
    private static let displayWidth = KompleteKontrolMK2Protocol.displayWidth
    private static let displayHeight = KompleteKontrolMK2Protocol.displayHeight
    private static let footer: [UInt8] = [
        0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00,
    ]

    private let lock = NSLock()
    private var frames = Array(
        repeating: [UInt8](repeating: 0, count: displayWidth * displayHeight * 2),
        count: screenCount
    )

    public init() {}

    public func decodeAndApply(_ packet: [UInt8]) throws -> MK2DecodedDisplayBlit {
        lock.lock()
        defer { lock.unlock() }
        guard packet.count >= 28,
              packet[0] == 0x84, packet[1] == 0x00,
              packet[3] == 0x60,
              packet[4...7].allSatisfy({ $0 == 0 }) else {
            throw MK2DisplayPacketDecodeError.malformed("invalid MK2 display header")
        }
        let screen = Int(packet[2])
        let x = readBE16(packet, at: 8)
        let y = readBE16(packet, at: 10)
        let width = readBE16(packet, at: 12)
        let height = readBE16(packet, at: 14)
        let pixelCount = width * height
        guard screen >= 0, screen < Self.screenCount,
              width > 0, height > 0,
              x + width <= Self.displayWidth,
              y + height <= Self.displayHeight,
              pixelCount.isMultiple(of: 2) else {
            throw MK2DisplayPacketDecodeError.malformed("invalid MK2 display rectangle")
        }

        var rectPixels = readRect(screen: screen, x: x, y: y, width: width, height: height)
        var offset = 16
        var pixelCursor = 0
        var foundFooter = false
        while offset < packet.count {
            if packet.count - offset == Self.footer.count,
               Array(packet[offset...]) == Self.footer {
                foundFooter = true
                offset = packet.count
                break
            }
            guard packet.count - offset >= 4 else {
                throw MK2DisplayPacketDecodeError.malformed("truncated MK2 display token")
            }
            let opcode = packet[offset]
            let pairCount = Int(packet[offset + 1]) << 16
                | Int(packet[offset + 2]) << 8
                | Int(packet[offset + 3])
            offset += 4
            let tokenPixels = pairCount * 2
            guard pixelCursor + tokenPixels <= pixelCount else {
                throw MK2DisplayPacketDecodeError.malformed("display token exceeds its rectangle")
            }
            switch opcode {
                case 0x00:
                    guard pairCount > 0, packet.count - offset >= pairCount * 4 else {
                        throw MK2DisplayPacketDecodeError.malformed("invalid literal display token")
                    }
                    let byteStart = pixelCursor * 2
                    rectPixels.replaceSubrange(
                        byteStart..<(byteStart + pairCount * 4),
                        with: packet[offset..<(offset + pairCount * 4)]
                    )
                    offset += pairCount * 4
                    pixelCursor += tokenPixels
                case 0x01:
                    guard pairCount > 0, packet.count - offset >= 4 else {
                        throw MK2DisplayPacketDecodeError.malformed("invalid repeat display token")
                    }
                    let repeatedPair = Array(packet[offset..<(offset + 4)])
                    offset += 4
                    for _ in 0..<pairCount {
                        let byteStart = pixelCursor * 2
                        rectPixels[byteStart] = repeatedPair[0]
                        rectPixels[byteStart + 1] = repeatedPair[1]
                        rectPixels[byteStart + 2] = repeatedPair[2]
                        rectPixels[byteStart + 3] = repeatedPair[3]
                        pixelCursor += 2
                    }
                case 0x02:
                    pixelCursor += tokenPixels
                default:
                    throw MK2DisplayPacketDecodeError.malformed(
                        String(format: "unsupported display opcode 0x%02x", opcode)
                    )
            }
        }
        guard foundFooter else {
            throw MK2DisplayPacketDecodeError.malformed("missing MK2 display footer")
        }
        guard pixelCursor == pixelCount else {
            throw MK2DisplayPacketDecodeError.malformed("display packet does not cover its rectangle")
        }
        recordRect(screen: screen, x: x, y: y, width: width, height: height, pixelsBE: rectPixels)
        return MK2DecodedDisplayBlit(
            screen: UInt8(screen),
            x: UInt16(x),
            y: UInt16(y),
            width: UInt16(width),
            height: UInt16(height),
            pixelsBE: rectPixels
        )
    }

    public func record(_ blit: MK2DecodedDisplayBlit) {
        lock.lock()
        defer { lock.unlock() }
        let screen = Int(blit.screen)
        let x = Int(blit.x), y = Int(blit.y), width = Int(blit.width), height = Int(blit.height)
        guard screen >= 0, screen < Self.screenCount,
              width > 0, height > 0,
              x >= 0, y >= 0,
              x + width <= Self.displayWidth,
              y + height <= Self.displayHeight,
              blit.pixelsBE.count == width * height * 2 else {
            return
        }
        recordRect(
            screen: screen,
            x: x,
            y: y,
            width: width,
            height: height,
            pixelsBE: blit.pixelsBE
        )
    }

    private func readRect(screen: Int, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 2)
        result.withUnsafeMutableBufferPointer { destination in
            frames[screen].withUnsafeBufferPointer { source in
                for row in 0..<height {
                    let sourceStart = source.baseAddress! + ((y + row) * Self.displayWidth + x) * 2
                    (destination.baseAddress! + row * width * 2).update(
                        from: sourceStart,
                        count: width * 2
                    )
                }
            }
        }
        return result
    }

    private func recordRect(
        screen: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        pixelsBE: [UInt8]
    ) {
        frames[screen].withUnsafeMutableBufferPointer { destination in
            pixelsBE.withUnsafeBufferPointer { source in
                for row in 0..<height {
                    let destinationStart = destination.baseAddress!
                        + ((y + row) * Self.displayWidth + x) * 2
                    destinationStart.update(
                        from: source.baseAddress! + row * width * 2,
                        count: width * 2
                    )
                }
            }
        }
    }

    private func readBE16(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
}
