import Foundation
import Testing
@testable import KompleteKontrol

@Suite("MK2 display packet codec")
struct MK2DisplayPacketCodecTests {
    @Test("Legacy is the fail-safe default and invalid values fall back to it")
    func configurationFallback() {
        let defaultSelection = MK2DisplayEncodingSelection.resolve(environment: [:])
        #expect(defaultSelection.mode == .legacy)
        #expect(!defaultSelection.fellBackToLegacy)

        let adaptive = MK2DisplayEncodingSelection.resolve(environment: [
            MK2DisplayEncodingSelection.environmentKey: "ADAPTIVE",
        ])
        #expect(adaptive.mode == .adaptive)
        #expect(!adaptive.fellBackToLegacy)

        let invalid = MK2DisplayEncodingSelection.resolve(environment: [
            MK2DisplayEncodingSelection.environmentKey: "fastest",
        ])
        #expect(invalid.mode == .legacy)
        #expect(invalid.fellBackToLegacy)
        #expect(invalid.requestedValue == "fastest")
    }

    @Test("A literal packet matches the hardware-verified chain encoding")
    func literalGoldenPacket() throws {
        let encoder = MK2DisplayPacketEncoder()
        let pixels: [UInt8] = [0xf8, 0x00, 0x00, 0x1f]
        let packet = try #require(encoder.encode(
            screen: 1, x: 4, y: 5, width: 2, height: 1, pixelsBE: pixels
        ))
        #expect(packet.bytes == [
            0x84, 0x00, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x04, 0x00, 0x05, 0x00, 0x02, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0xf8, 0x00, 0x00, 0x1f,
            0x02, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
            0x40, 0x00, 0x00, 0x00,
        ])
        #expect(packet.metrics.legacyBytes == 40)
        #expect(packet.metrics.encodedBytes == 36)

        let decoded = try MK2DisplayPacketDecoder().decodeAndApply(packet.bytes)
        #expect(decoded.pixelsBE == pixels)
    }

    @Test("Repeated pairs use opcode 0x01 and round-trip exactly")
    func repeatedPairs() throws {
        let encoder = MK2DisplayPacketEncoder()
        let pair: [UInt8] = [0x12, 0x34, 0xab, 0xcd]
        let pixels = pair + pair + pair
        let packet = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 6, height: 1, pixelsBE: pixels
        ))
        #expect(packet.metrics.repeatPairs == 3)
        #expect(packet.metrics.literalPairs == 0)
        #expect(packet.bytes[16] == 0x01)
        #expect(packet.bytes[19] == 0x03)

        let decoded = try MK2DisplayPacketDecoder().decodeAndApply(packet.bytes)
        #expect(decoded.pixelsBE == pixels)
    }

    @Test("Committed shadows produce chained skips; uncommitted packets do not")
    func skipRequiresCommit() throws {
        let encoder = MK2DisplayPacketEncoder()
        let baseline: [UInt8] = [
            0x00, 0x01, 0x00, 0x02,
            0x00, 0x03, 0x00, 0x04,
            0x00, 0x05, 0x00, 0x06,
            0x00, 0x07, 0x00, 0x08,
        ]
        let first = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 8, height: 1, pixelsBE: baseline
        ))
        let beforeCommit = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 8, height: 1, pixelsBE: baseline
        ))
        #expect(beforeCommit.metrics.skippedPairs == 0)
        encoder.commit(first)

        var changed = baseline
        changed.replaceSubrange(4..<8, with: [0xf8, 0x00, 0x07, 0xe0])
        let update = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 8, height: 1, pixelsBE: changed
        ))
        #expect(update.metrics.skippedPairs == 3)
        #expect(update.metrics.literalPairs == 1)
        #expect(update.metrics.segmentCount == 3)

        let decoder = MK2DisplayPacketDecoder()
        _ = try decoder.decodeAndApply(first.bytes)
        let decoded = try decoder.decodeAndApply(update.bytes)
        #expect(decoded.pixelsBE == changed)
    }

    @Test("Fragmentation that cannot save bytes falls back to the legacy packet")
    func fragmentedFallback() throws {
        let encoder = MK2DisplayPacketEncoder()
        let baseline: [UInt8] = [
            0x00, 0x01, 0x00, 0x02,
            0x00, 0x03, 0x00, 0x04,
            0x00, 0x05, 0x00, 0x06,
            0x00, 0x07, 0x00, 0x08,
        ]
        let first = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 8, height: 1, pixelsBE: baseline
        ))
        encoder.commit(first)
        var fragmented = baseline
        fragmented.replaceSubrange(4..<8, with: [0xf8, 0x00, 0x07, 0xe0])
        fragmented.replaceSubrange(12..<16, with: [0x00, 0x1f, 0xff, 0xff])

        let packet = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 8, height: 1, pixelsBE: fragmented
        ))
        #expect(!packet.metrics.usedAdaptiveEncoding)
        #expect(packet.metrics.encodedBytes == packet.metrics.legacyBytes)
        #expect(Array(packet.bytes[16..<20]) == [0x02, 0x00, 0x00, 0x00])
        #expect(Array(packet.bytes[20..<24]) == [0x00, 0x00, 0x00, 0x04])
        #expect(Array(packet.bytes[24..<40]) == fragmented)
    }

    @Test("Malformed or incomplete packets are rejected without changing the decoder")
    func strictDecoder() throws {
        let encoder = MK2DisplayPacketEncoder()
        let packet = try #require(encoder.encode(
            screen: 0,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            pixelsBE: [0xff, 0xff, 0x00, 0x00]
        ))
        let decoder = MK2DisplayPacketDecoder()
        var truncated = packet.bytes
        truncated.removeLast()
        #expect(throws: MK2DisplayPacketDecodeError.self) {
            _ = try decoder.decodeAndApply(truncated)
        }
        let decoded = try decoder.decodeAndApply(packet.bytes)
        #expect(decoded.pixelsBE == [0xff, 0xff, 0x00, 0x00])
    }

    @Test("A deterministic mixed update sequence remains pixel-exact")
    func mixedSequenceRoundTrip() throws {
        let encoder = MK2DisplayPacketEncoder()
        let decoder = MK2DisplayPacketDecoder()
        var frame = deterministicFrame()
        let first = try #require(encoder.encode(
            screen: 1, x: 0, y: 0, width: 480, height: 272, pixelsBE: frame
        ))
        #expect(try decoder.decodeAndApply(first.bytes).pixelsBE == frame)
        encoder.commit(first)

        var state: UInt64 = 0x4d4b_3250_4452_3201
        for updateIndex in 0..<64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let startRow = Int((state >> 32) % 264)
            let height = 2 + Int((state >> 16) % 9)
            let clampedHeight = min(height, 272 - startRow)
            let changedRow = startRow + updateIndex % clampedHeight
            for column in 0..<480 where (column + updateIndex).isMultiple(of: 3) {
                let offset = (changedRow * 480 + column) * 2
                frame[offset] ^= UInt8(truncatingIfNeeded: updateIndex &* 17 &+ column)
                frame[offset + 1] ^= UInt8(truncatingIfNeeded: updateIndex &* 29 &+ column / 2)
            }
            let band = pixels(
                inX: 0,
                y: startRow,
                width: 480,
                height: clampedHeight,
                frame: frame
            )
            let packet = try #require(encoder.encode(
                screen: 1,
                x: 0,
                y: UInt16(startRow),
                width: 480,
                height: UInt16(clampedHeight),
                pixelsBE: band
            ))
            let decoded = try decoder.decodeAndApply(packet.bytes)
            #expect(decoded.pixelsBE == band)
            encoder.commit(packet)
        }
    }

    @Test("Representative replay reports deterministic byte and wire-time savings")
    func representativeCostReport() throws {
        let encoder = MK2DisplayPacketEncoder()
        var frame = deterministicFrame()
        let baselineStart = DispatchTime.now().uptimeNanoseconds
        let baseline = try #require(encoder.encode(
            screen: 0, x: 0, y: 0, width: 480, height: 272, pixelsBE: frame
        ))
        let baselineNanoseconds = DispatchTime.now().uptimeNanoseconds - baselineStart
        encoder.commit(baseline)

        for row in 40..<48 {
            mutateRow(row, salt: 0x31, frame: &frame)
        }
        for row in 192..<200 {
            mutateRow(row, salt: 0xa7, frame: &frame)
        }
        let band = pixels(inX: 0, y: 40, width: 480, height: 160, frame: frame)
        let gappedUpdate = try #require(encoder.encode(
            screen: 0, x: 0, y: 40, width: 480, height: 160, pixelsBE: band
        ))
        #expect(gappedUpdate.metrics.skippedPairs == 480 * 144 / 2)
        #expect(gappedUpdate.metrics.savedBytes > 100_000)
        #expect(gappedUpdate.metrics.estimatedSavedMilliseconds > 8)

        var encodeDurations: [UInt64] = []
        var consumedBytes = 0
        for _ in 0..<25 {
            let start = DispatchTime.now().uptimeNanoseconds
            let replay = try #require(encoder.encode(
                screen: 0, x: 0, y: 40, width: 480, height: 160, pixelsBE: band
            ))
            encodeDurations.append(DispatchTime.now().uptimeNanoseconds - start)
            consumedBytes += replay.bytes.count
        }
        encodeDurations.sort()
        let medianMilliseconds = Double(encodeDurations[encodeDurations.count / 2]) / 1_000_000
        let p90Milliseconds = Double(encodeDurations[Int(Double(encodeDurations.count - 1) * 0.9)]) / 1_000_000

        for row in 216..<224 {
            mutateRow(row, salt: 0x5d, frame: &frame)
        }
        let localizedBand = pixels(inX: 0, y: 216, width: 480, height: 8, frame: frame)
        var localizedDurations: [UInt64] = []
        var localizedUpdate: MK2EncodedDisplayPacket?
        for _ in 0..<25 {
            let start = DispatchTime.now().uptimeNanoseconds
            localizedUpdate = encoder.encode(
                screen: 0, x: 0, y: 216, width: 480, height: 8, pixelsBE: localizedBand
            )
            localizedDurations.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        let localized = try #require(localizedUpdate)
        localizedDurations.sort()
        let localizedMedianMilliseconds = Double(
            localizedDurations[localizedDurations.count / 2]
        ) / 1_000_000
        #expect(localized.metrics.skippedPairs == 0)
        #expect(localized.metrics.repeatPairs == 0)
        #expect(localized.metrics.savedBytes == 4)

        let summary = String(
            format: "PERF display-codec legacy=%d encoded=%d saved=%d estimated=%.3fms segments=%d firstFull=%.3fms encodeMedian=%.3fms encodeP90=%.3fms checksum=%d",
            gappedUpdate.metrics.legacyBytes,
            gappedUpdate.metrics.encodedBytes,
            gappedUpdate.metrics.savedBytes,
            gappedUpdate.metrics.estimatedSavedMilliseconds,
            gappedUpdate.metrics.segmentCount,
            Double(baselineNanoseconds) / 1_000_000,
            medianMilliseconds,
            p90Milliseconds,
            consumedBytes
        )
        print(summary)
        print(String(
            format: "PERF display-codec-localized legacy=%d encoded=%d saved=%d estimated=%.6fms encodeMedian=%.3fms",
            localized.metrics.legacyBytes,
            localized.metrics.encodedBytes,
            localized.metrics.savedBytes,
            localized.metrics.estimatedSavedMilliseconds,
            localizedMedianMilliseconds
        ))
    }

    private func deterministicFrame() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 480 * 272 * 2)
        for pixel in 0..<(480 * 272) {
            let value = UInt16(truncatingIfNeeded: pixel &* 73 &+ pixel / 480 &* 977)
            frame[pixel * 2] = UInt8(value >> 8)
            frame[pixel * 2 + 1] = UInt8(value & 0xff)
        }
        return frame
    }

    private func mutateRow(_ row: Int, salt: UInt8, frame: inout [UInt8]) {
        for column in 0..<480 {
            let offset = (row * 480 + column) * 2
            frame[offset] ^= salt
            frame[offset + 1] ^= UInt8(truncatingIfNeeded: Int(salt) + column &* 13)
        }
    }

    private func pixels(
        inX x: Int,
        y: Int,
        width: Int,
        height: Int,
        frame: [UInt8]
    ) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(width * height * 2)
        for row in 0..<height {
            let start = ((y + row) * 480 + x) * 2
            result.append(contentsOf: frame[start..<(start + width * 2)])
        }
        return result
    }
}
