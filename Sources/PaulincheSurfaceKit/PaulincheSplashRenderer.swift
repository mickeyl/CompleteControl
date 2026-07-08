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

/// The splash/about pair shown while the app is still warming up: the hero artwork
/// behind a centered identity block on the left, a quieter echo with version and an
/// optional status line on the right. No input bindings — the caller installs its own
/// (transport, encoders) so the hardware is live even before the first real scene.
public enum MK2PaulincheSplashRenderer {
    public static func render(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: identityScreen(scene, renderer: renderer),
            right: versionScreen(scene, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, renderer: renderer).scene()
    }

    private static func identityScreen(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            if let artwork = scene.artwork {
                MK2ImageElement(artwork, brightness: 0.4)
            }
            MK2ContentText(scene.title, x: 0, y: 92, maxWidth: MK2PixelFrame.width, role: .title, alignment: .center)
            MK2ContentText(scene.subtitle, x: 0, y: 132, maxWidth: MK2PixelFrame.width, color: MK2HIG.Chrome.dim, alignment: .center)
            MK2ContentText(scene.version, x: 0, y: 246, maxWidth: MK2PixelFrame.width, role: .footnote, color: MK2HIG.Chrome.dim, alignment: .center)
        }.build(renderer: renderer)
    }

    private static func versionScreen(
        _ scene: MK2PaulincheSplashScene,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            if let artwork = scene.artwork {
                MK2ImageElement(artwork, brightness: 0.2)
            }
            if let detail = scene.detail {
                MK2ContentText(detail, x: 0, y: 246, maxWidth: MK2PixelFrame.width, role: .footnote, color: MK2HIG.Chrome.dim, alignment: .center)
            }
        }.build(renderer: renderer)
    }
}
