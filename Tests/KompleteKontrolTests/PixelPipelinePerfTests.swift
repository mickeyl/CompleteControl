import Foundation
import Testing
@testable import KompleteKontrol
@testable import KontrolSurfaceKit2

// Not assertions — a measurement harness for the per-event pixel pipeline cost in
// whatever build configuration the tests run in. Prints stage timings.
@Suite("Pixel pipeline stage timings")
struct PixelPipelinePerfTests {
    private func measure(_ name: String, iterations: Int = 50, _ body: () -> Void) {
        // warmup
        body()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            body()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        let padded = name.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("PERF \(padded) " + String(format: "%8.3f ms/op", elapsed / Double(iterations)))
    }

    @Test("stage timings")
    func stageTimings() {
        measure("frame fill (construct)") {
            _ = MK2PixelFrame(fill: 0x0000)
        }

        var textFrame = MK2PixelFrame(fill: 0x0000)
        measure("drawText 60 chars scale 3") {
            for line in 0..<3 {
                textFrame.drawText("RIBBON LAB MODE ABSOLUTE", x: 20, y: 40 + line * 40, scale: 3)
            }
        }

        measure("typical page build (2 frames)") {
            var left = MK2PixelFrame(fill: 0x0000)
            left.drawText("RIBBON LAB", x: 20, y: 46, scale: 4)
            left.drawText("MODE ABSOLUTE", x: 20, y: 110, scale: 3)
            left.drawText("TOUCH STRIP STREAM", x: 20, y: 150, scale: 3)
            var right = MK2PixelFrame(fill: 0x0000)
            right.drawText("POSITION", x: 20, y: 46, scale: 4)
            right.horizontalBar(MK2PixelRect(x: 20, y: 120, width: 440, height: 40), value: 0.5, fill: 0x07e0, track: 0x2104)
            right.drawText("RIB 512 T 4459", x: 20, y: 190, scale: 3)
        }

        var reconciler = PixelDisplayReconciler2()
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, frame])
        var meter = 0.1
        measure("reconcile with 40-row change") {
            meter += 0.001
            frame.horizontalBar(MK2PixelRect(x: 20, y: 120, width: 440, height: 40), value: meter, fill: 0x07e0, track: 0x2104)
            _ = reconciler.reconcile(frames: [frame, nil])
        }

        let bandPixels = [UInt16](repeating: 0x1234, count: 480 * 40)
        measure("wire bytes 40-row band (memcpy)") {
            _ = bandPixels.withUnsafeBytes { Array($0) }
        }

        let fullPixels = [UInt16](repeating: 0x1234, count: 480 * 272)
        measure("wire bytes full frame (memcpy)") {
            _ = fullPixels.withUnsafeBytes { Array($0) }
        }

        // The overlay composite's blit step (memcpy), next to the
        // replaceSubrange loop it replaced for comparison.
        var blitFrame = MK2PixelFrame(fill: 0x0000)
        let blitSource = [UInt16](repeating: 0x1234, count: 464 * 57)
        let blitRect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)
        measure("overlay blit 464x57 (memcpy)") {
            blitFrame.blit(blitSource, into: blitRect)
        }
        var referencePixels = blitFrame.pixels
        measure("overlay blit 464x57 (replaceSubrange ref)") {
            for row in 0..<blitRect.height {
                let destination = (blitRect.y + row) * MK2PixelFrame.width + blitRect.x
                let source = row * blitRect.width
                referencePixels.replaceSubrange(destination..<(destination + blitRect.width), with: blitSource[source..<(source + blitRect.width)])
            }
        }

        // Steady-state tick with a held overlay: "fresh identity" replicates the
        // uncached path (a full CoW copy per tick plus a whole-frame dirty scan
        // that finds nothing); "cached identity" is the composite-cache tick.
        var holdReconciler = PixelDisplayReconciler2()
        let holdBase = MK2PixelFrame(fill: 0x0000)
        _ = holdReconciler.reconcile(frames: [holdBase, nil])
        measure("held-overlay tick (fresh identity)") {
            var fresh = holdBase
            fresh[0, 0] = fresh[0, 0]
            _ = holdReconciler.reconcile(frames: [fresh, nil])
        }
        let heldFrame = holdBase
        _ = holdReconciler.reconcile(frames: [heldFrame, nil])
        measure("held-overlay tick (cached identity)") {
            _ = holdReconciler.reconcile(frames: [heldFrame, nil])
        }

        // Full-frame replay payload assembly, with and without the up-front
        // capacity reservation.
        let fullFrameBE = [UInt8](repeating: 0x12, count: 480 * 272 * 2)
        measure("display payload full frame (reserved)") {
            _ = KKDaemonBinaryCodec.displayBlitPayload(
                screen: 0, x: 0, y: 0, width: 480, height: 272, timeoutMs: 1000, pixelsRGB565BE: fullFrameBE
            )
        }
        measure("display payload full frame (unreserved ref)") {
            var payload: [UInt8] = [0, 0]
            payload.appendUInt16LE(0)
            payload.appendUInt16LE(0)
            payload.appendUInt16LE(480)
            payload.appendUInt16LE(272)
            payload.appendUInt32LE(1000)
            payload.append(contentsOf: fullFrameBE)
            _ = payload
        }

        // The light-guide page's extra work per change: 88 HSV key colours (demo side)
        // and 88 nearest-palette searches + payload build (kit side).
        var hue = 0.0
        measure("HSV key colours x88 (demo)") {
            hue += 1
            for key in 0..<88 {
                let keyHue = fmod(hue + Double(key) * 4, 360) / 60
                let sector = Int(keyHue)
                let fraction = keyHue - Double(sector)
                let q = UInt8((1 - fraction) * 255)
                let t = UInt8(fraction * 255)
                switch sector % 6 {
                    case 0: _ = KKRGB(red: 255, green: t, blue: 0)
                    case 1: _ = KKRGB(red: q, green: 255, blue: 0)
                    case 2: _ = KKRGB(red: 0, green: 255, blue: t)
                    case 3: _ = KKRGB(red: 0, green: q, blue: 255)
                    case 4: _ = KKRGB(red: t, green: 0, blue: 255)
                    default: _ = KKRGB(red: 255, green: 0, blue: q)
                }
            }
        }

        var keyColors: [KKRGB] = []
        for index in 0..<88 {
            let red = UInt8((index * 3) % 256)
            let green = UInt8((index * 7) % 256)
            let blue = UInt8((index * 11) % 256)
            keyColors.append(KKRGB(red: red, green: green, blue: blue))
        }
        measure("palette map x88 + payload (kit)") {
            var payload = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
            for (index, color) in keyColors.enumerated() {
                payload[index] = KompleteKontrolSSeriesMK2.paletteCode(for: color)
            }
        }
    }
}
