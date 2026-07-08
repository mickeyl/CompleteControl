import Foundation
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche splash renderer")
struct PaulincheSplashRendererTests {
    @Test("Splash renders artwork behind a centered identity block")
    func splashRendersArtworkAndIdentity() throws {
        var art = MK2PixelFrame(fill: 0xffff)
        art.fill(MK2PixelRect(x: 0, y: 0, width: 480, height: 40), 0xf800)
        let artwork = try #require(MK2PixelImage(data: PixelSnapshot.pngData(art)))

        let scene = MK2PaulincheSplashScene(
            title: "PAULINCHE",
            subtitle: "AMIGA MOD TRACKER",
            version: "VERSION 0.1 (1)",
            detail: "WARMING UP …",
            artwork: artwork
        )
        let rendered = MK2PaulincheSplashRenderer.render(scene, renderer: try? FreeTypeTextRenderer())

        #expect(rendered.left.screen.kind == .fullScreen)
        #expect(rendered.right.screen.kind == .fullScreen)

        // The artwork fills the left screen at 40% brightness (dithered quantization),
        // the right echo at 20%.
        let left = rendered.left.screen.frame
        #expect(left[10, 200] == MK2OrderedDither.scaled(0xffff, by: 0.4, x: 10, y: 200))
        let right = rendered.right.screen.frame
        #expect(right[10, 200] == MK2OrderedDither.scaled(0xffff, by: 0.2, x: 10, y: 200))

        // The title ink sits horizontally centered over the artwork.
        var minX = MK2PixelFrame.width, maxX = 0
        for y in 92..<130 {
            for x in 0..<MK2PixelFrame.width where left[x, y] == 0xffff {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        #expect(maxX > minX)
        #expect(abs((minX + maxX) / 2 - 240) < 12)

        // No input bindings — the splash leaves the hardware to the caller.
        let surfaceScene = MK2PaulincheSplashRenderer.surfaceScene(scene)
        #expect(surfaceScene.bindings.encoder.isEmpty)
        #expect(surfaceScene.bindings.buttonDown.isEmpty)
    }

    @Test("Default splash spans the wave panorama continuously across both screens")
    func panoramaSpansBothScreens() throws {
        let scene = MK2PaulincheSplashScene(
            title: "PAULINCHE",
            subtitle: "AMIGA MOD TRACKER",
            version: "VERSION 0.1 (1)"
        )
        let rendered = MK2PaulincheSplashRenderer.render(scene)
        let left = rendered.left.screen.frame
        let right = rendered.right.screen.frame

        let panorama = MK2PaulincheSplashArtwork.panorama()
        #expect(panorama.width == 2 * 480 + MK2PaulincheSplashArtwork.defaultBezelGapColumns)

        // Both screens sample the same panorama at the same brightness (dithered at
        // frame coordinates): the left screen shows its first columns, the right
        // screen its last ones. Row 10 and 220 are pure gradient, row 60 crosses the
        // wave crests; all three stay clear of the label rows on the left screen.
        let rightStart = panorama.width - 480
        for y in [10, 60, 220] {
            for x in [0, 200, 479] {
                #expect(left[x, y] == MK2OrderedDither.scaled(panorama.pixels[y * panorama.width + x], by: 0.45, x: x, y: y))
                #expect(right[x, y] == MK2OrderedDither.scaled(panorama.pixels[y * panorama.width + rightStart + x], by: 0.45, x: x, y: y))
            }
        }
    }

    @Test("Splash can be captured as a two-screen snapshot")
    func splashSnapshotSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        let artwork = environment["PAULINCHE_SPLASH_ARTWORK"]
            .flatMap { MK2PixelImage(contentsOf: URL(fileURLWithPath: $0)) }
        let scene = MK2PaulincheSplashScene(
            title: "PAULINCHE",
            subtitle: "AMIGA MOD TRACKER",
            version: "VERSION 0.1 (1)",
            detail: "WARMING UP …",
            artwork: artwork
        )
        let rendered = MK2PaulincheSplashRenderer.render(scene, renderer: try? FreeTypeTextRenderer())
        let png = PixelSnapshot.pngData(frames: [rendered.left.screen.frame, rendered.right.screen.frame])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        if let dir = environment["PAULINCHE_SNAPSHOT_DIR"] {
            try PixelSnapshot.write(
                [rendered.left.screen.frame, rendered.right.screen.frame],
                to: "\(dir)/paulinche-splash.png"
            )
        }
    }
}
