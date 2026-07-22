import Foundation

/// Text shown on one OLED by `MK2PopupOverlayElement`.
public struct MK2PopupOverlayContent: Equatable, Sendable {
    public var title: String
    public var body: String
    public var footnote: String?

    public init(title: String, body: String, footnote: String? = nil) {
        self.title = title
        self.body = body
        self.footnote = footnote
    }
}

public enum MK2PopupOverlayDisplayMode: String, CaseIterable, Equatable, Sendable {
    case left
    case right
    case both
}

/// A passive popup composited over one or both displays of an existing scene.
///
/// The element preserves the scene's lamps and bindings. Each display carrying
/// a popup is dimmed to half RGB565 brightness before the stable card geometry
/// is drawn; a display without popup content remains untouched. It owns
/// presentation only; capture, dismissal, and other input semantics remain
/// client state.
public struct MK2PopupOverlayElement: Sendable {
    public static let defaultRect = MK2PixelRect(x: 24, y: 56, width: 432, height: 156)

    public var left: MK2PopupOverlayContent?
    public var right: MK2PopupOverlayContent?
    public var rect: MK2PixelRect
    public var dimsBackground: Bool
    public var cornerRadius: Int
    public var borderWidth: Int
    public var colors: MK2DialogCardColors

    public var displayMode: MK2PopupOverlayDisplayMode {
        switch (left, right) {
        case (.some, .some): .both
        case (.some, .none): .left
        case (.none, .some): .right
        case (.none, .none):
            preconditionFailure("A popup overlay must target at least one display")
        }
    }

    public init(
        left: MK2PopupOverlayContent? = nil,
        right: MK2PopupOverlayContent? = nil,
        rect: MK2PixelRect = Self.defaultRect,
        dimsBackground: Bool = true,
        cornerRadius: Int = 9,
        borderWidth: Int = 2,
        colors: MK2DialogCardColors = MK2DialogCardColors(
            surface: MK2HIG.Chrome.background
        )
    ) {
        precondition(left != nil || right != nil, "A popup overlay must target at least one display")
        self.left = left
        self.right = right
        self.rect = rect
        self.dimsBackground = dimsBackground
        self.cornerRadius = max(0, cornerRadius)
        self.borderWidth = max(1, borderWidth)
        self.colors = colors
    }

    public func apply(
        to scene: inout MK2SurfaceScene2,
        renderer: FreeTypeTextRenderer? = nil
    ) {
        let content: [MK2PopupOverlayContent?] = [left, right]
        for screenIndex in scene.displays.indices where content.indices.contains(screenIndex) {
            guard let popupContent = content[screenIndex],
                  var frame = scene.displays[screenIndex]
            else { continue }
            if dimsBackground {
                frame.dimHalf(MK2PixelFrame.bounds)
            }
            draw(popupContent, into: &frame, renderer: renderer)
            scene.displays[screenIndex] = frame
        }
    }

    public func applying(
        to scene: MK2SurfaceScene2,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        var scene = scene
        apply(to: &scene, renderer: renderer)
        return scene
    }

    private func draw(
        _ content: MK2PopupOverlayContent,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        frame.fillRounded(rect, radius: cornerRadius, colors.border, antialiased: true)
        let inner = MK2PixelRect(
            x: rect.x + borderWidth,
            y: rect.y + borderWidth,
            width: max(0, rect.width - borderWidth * 2),
            height: max(0, rect.height - borderWidth * 2)
        )
        frame.fillRounded(
            inner,
            radius: max(0, cornerRadius - borderWidth),
            colors.surface,
            antialiased: true
        )

        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        let context = MK2ScreenContext(renderer: renderer)
        let textX = rect.x + 18
        let textWidth = max(0, rect.width - 36)
        MK2ContentText(
            content.title.uppercased(),
            x: textX,
            y: rect.y + 16,
            maxWidth: textWidth,
            role: .title,
            color: colors.title,
            relativeToContent: false
        ).apply(to: &frame, context: context, result: &result)
        MK2ContentText(
            content.body,
            x: textX,
            y: rect.y + 62,
            maxWidth: textWidth,
            role: .body,
            color: colors.body,
            relativeToContent: false,
            maxLines: content.footnote == nil ? 3 : 2,
            lineSpacing: 2
        ).apply(to: &frame, context: context, result: &result)
        if let footnote = content.footnote {
            MK2ContentText(
                footnote,
                x: textX,
                y: rect.maxY - 31,
                maxWidth: textWidth,
                role: .footnote,
                color: colors.footnote,
                relativeToContent: false
            ).apply(to: &frame, context: context, result: &result)
        }
    }
}
