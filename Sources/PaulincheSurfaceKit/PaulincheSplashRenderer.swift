import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public struct MK2PaulincheSplashCredits: Sendable, Equatable {
    public var copyrightLine: String
    public var versionLine: String

    public init(copyrightLine: String, versionLine: String) {
        self.copyrightLine = copyrightLine
        self.versionLine = versionLine
    }
}

/// The splash pair shown while the app warms up: a single 960×272 artwork spread
/// pixel-for-pixel across the two 480-wide displays — the left screen shows its
/// first half, the right screen its second half, with the physical bezel falling
/// at the image's centre. Optional identity credits occupy the lower edge of the
/// right display. No input bindings — the caller installs its own so the hardware
/// is live even before the first real scene.
public enum MK2PaulincheSplashRenderer {
    public static func render(
        artwork: MK2PixelImage?,
        credits: MK2PaulincheSplashCredits? = nil,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: half(artwork, x: 0, credits: nil, renderer: renderer),
            right: half(
                artwork,
                x: MK2PixelFrame.width - (artwork?.width ?? 0),
                credits: credits,
                renderer: renderer
            )
        )
    }

    public static func surfaceScene(
        artwork: MK2PixelImage?,
        credits: MK2PaulincheSplashCredits? = nil,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(artwork: artwork, credits: credits, renderer: renderer).scene()
    }

    /// One display's worth of the artwork: `x` is the image origin, so 0 shows the
    /// first 480 columns and `480 − width` (−480 for a 960-wide image) shows the
    /// last 480.
    private static func half(
        _ artwork: MK2PixelImage?,
        x: Int,
        credits: MK2PaulincheSplashCredits?,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            if let artwork {
                MK2ImageElement(artwork, x: x)
            }
            if let credits {
                MK2ContentText(
                    credits.copyrightLine,
                    x: 8,
                    y: 234,
                    maxWidth: 464,
                    role: .custom(weight: .medium, pixelSize: 11),
                    color: MK2PaulincheRendererSupport.Palette.credit,
                    alignment: .center,
                    relativeToContent: false
                )
                MK2ContentText(
                    credits.versionLine,
                    x: 8,
                    y: 250,
                    maxWidth: 464,
                    role: .custom(weight: .regular, pixelSize: 11),
                    color: MK2PaulincheRendererSupport.Palette.creditDim,
                    alignment: .center,
                    relativeToContent: false
                )
            }
        }.build(renderer: renderer)
    }
}
