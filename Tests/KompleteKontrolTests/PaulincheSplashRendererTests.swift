import Foundation
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche splash renderer")
struct PaulincheSplashRendererTests {
    private static let credits = MK2PaulincheSplashCredits(
        copyrightLine: "© Dr. Michael 'Mickey' Lauer aka Lord Performer Artworx",
        versionLine: "Version 0.8.0 (230) b1ae309"
    )

    /// A 960×272 panorama: red left half, blue right half, so the split is verifiable.
    private static func panoramaArtwork() -> MK2PixelImage {
        let width = MK2PixelFrame.width * 2
        let pixels = (0..<MK2PixelFrame.height).flatMap { _ in
            (0..<width).map { x in x < MK2PixelFrame.width ? UInt16(0xf800) : UInt16(0x001f) }
        }
        return MK2PixelImage(width: width, height: MK2PixelFrame.height, pixels: pixels)
    }

    @Test("A 960×272 panorama splits pixel-for-pixel across the two screens")
    func panoramaSplitsAcrossScreens() {
        let rendered = MK2PaulincheSplashRenderer.render(artwork: Self.panoramaArtwork())
        #expect(rendered.left.screen.kind == .fullScreen)
        #expect(rendered.right.screen.kind == .fullScreen)

        let left = rendered.left.screen.frame
        let right = rendered.right.screen.frame
        // Full brightness, no scaling: the left screen shows the red first half, the
        // right screen the blue second half — edge to edge.
        #expect(left[10, 100] == 0xf800)
        #expect(left[470, 100] == 0xf800)
        #expect(right[10, 100] == 0x001f)
        #expect(right[470, 100] == 0x001f)
    }

    @Test("No artwork leaves the background and installs no bindings")
    func noArtwork() {
        let rendered = MK2PaulincheSplashRenderer.surfaceScene(artwork: nil)
        #expect(rendered.displays[0] != nil)
        #expect(rendered.displays[1] != nil)
        #expect(rendered.bindings.encoder.isEmpty)
        #expect(rendered.bindings.buttonDown.isEmpty)
    }

    @Test("Credits render only at the bottom of the right display")
    func creditsRenderOnRightDisplay() throws {
        let renderer = try FreeTypeTextRenderer()
        let plain = MK2PaulincheSplashRenderer.render(artwork: Self.panoramaArtwork(), renderer: renderer)
        let credited = MK2PaulincheSplashRenderer.render(
            artwork: Self.panoramaArtwork(),
            credits: Self.credits,
            renderer: renderer
        )

        #expect(credited.left.screen.frame == plain.left.screen.frame)
        #expect(credited.right.screen.frame != plain.right.screen.frame)
        #expect((0..<234).allSatisfy { y in
            (0..<MK2PixelFrame.width).allSatisfy { x in
                credited.right.screen.frame[x, y] == plain.right.screen.frame[x, y]
            }
        })
    }

    @Test("Splash can be captured as a two-screen snapshot")
    func splashSnapshotSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        let artwork = environment["PAULINCHE_SPLASH_ARTWORK"].flatMap {
            MK2PixelImage(contentsOf: URL(fileURLWithPath: $0), width: MK2PixelFrame.width * 2, height: MK2PixelFrame.height)
        } ?? Self.panoramaArtwork()
        let rendered = MK2PaulincheSplashRenderer.render(
            artwork: artwork,
            credits: Self.credits,
            renderer: try? FreeTypeTextRenderer()
        )
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
