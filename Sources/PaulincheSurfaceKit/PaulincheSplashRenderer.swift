import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public struct MK2PaulincheSplashScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var version: String
    public var detail: String?
    public var artwork: MK2PixelImage?

    public init(
        title: String,
        subtitle: String,
        version: String,
        detail: String? = nil,
        artwork: MK2PixelImage? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.version = version
        self.detail = detail
        self.artwork = artwork
    }
}

/// The splash/about pair shown while the app is still warming up. Without explicit
/// artwork it renders the generated wave panorama (`MK2PaulincheSplashArtwork`)
/// continuously across both displays at uniform brightness, with the identity block
/// (title, subtitle, version) on the left screen and an optional status line on the
/// right. A single-screen artwork instead repeats as a darker echo on the right.
/// No input bindings — the caller installs its own (transport, encoders) so the
/// hardware is live even before the first real scene.
public enum MK2PaulincheSplashRenderer {
    public static func render(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        let artwork = scene.artwork ?? MK2PaulincheSplashArtwork.panorama()
        return MK2DoubleScreenDSL(
            left: identityScreen(scene, artwork: artwork, renderer: renderer),
            right: detailScreen(scene, artwork: artwork, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, renderer: renderer).scene()
    }

    // The look signed off in the widget lab: the wave colors soften to pastel and
    // the gradient recedes far enough for white labels to sit on top.
    private static let panoramaBrightness = 0.45

    /// A panorama is any artwork wider than one display: the left screen shows its
    /// first columns, the right screen the last ones — columns in between fall into
    /// the physical bezel gap.
    private static func isPanorama(_ artwork: MK2PixelImage) -> Bool {
        artwork.width > MK2PixelFrame.width
    }

    private static func identityScreen(
        _ scene: MK2PaulincheSplashScene,
        artwork: MK2PixelImage,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            if isPanorama(artwork) {
                MK2ImageElement(artwork, x: 0, brightness: Self.panoramaBrightness)
            } else {
                MK2ImageElement(artwork, brightness: 0.4)
            }
            MK2ContentText(scene.title, x: 0, y: 92, maxWidth: MK2PixelFrame.width, role: .title, alignment: .center)
            MK2ContentText(scene.subtitle, x: 0, y: 132, maxWidth: MK2PixelFrame.width, color: MK2HIG.Chrome.dim, alignment: .center)
            MK2ContentText(scene.version, x: 0, y: 246, maxWidth: MK2PixelFrame.width, role: .footnote, color: MK2HIG.Chrome.dim, alignment: .center)
        }.build(renderer: renderer)
    }

    private static func detailScreen(
        _ scene: MK2PaulincheSplashScene,
        artwork: MK2PixelImage,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            if isPanorama(artwork) {
                MK2ImageElement(artwork, x: MK2PixelFrame.width - artwork.width, brightness: Self.panoramaBrightness)
            } else {
                MK2ImageElement(artwork, brightness: 0.2)
            }
            if let detail = scene.detail {
                MK2ContentText(detail, x: 0, y: 246, maxWidth: MK2PixelFrame.width, role: .footnote, color: MK2HIG.Chrome.dim, alignment: .center)
            }
        }.build(renderer: renderer)
    }
}
