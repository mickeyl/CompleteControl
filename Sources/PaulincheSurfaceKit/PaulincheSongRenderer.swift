import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public struct MK2PaulincheSongOrder: Sendable, Equatable {
    public var index: Int
    public var patternLabel: String
    public var title: String
    public var rowCount: Int
    public var isSelected: Bool
    public var isPlaybackOrder: Bool

    public init(
        index: Int,
        patternLabel: String,
        title: String,
        rowCount: Int,
        isSelected: Bool = false,
        isPlaybackOrder: Bool = false
    ) {
        self.index = max(0, index)
        self.patternLabel = patternLabel
        self.title = title
        self.rowCount = max(1, rowCount)
        self.isSelected = isSelected
        self.isPlaybackOrder = isPlaybackOrder
    }
}

public struct MK2PaulincheSongScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var progress: Double
    public var orders: [MK2PaulincheSongOrder]
    public var parameters: [MK2PaulinchePatternParameter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        progress: Double = 0,
        orders: [MK2PaulincheSongOrder],
        parameters: [MK2PaulinchePatternParameter],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.progress = MK2PaulincheRendererSupport.clamped01(progress)
        self.orders = orders
        self.parameters = Array(parameters.prefix(8))
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulincheSongActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?

    public init(onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil) {
        self.onSoftKey = onSoftKey
    }
}

public enum MK2PaulincheSongRenderer {
    public static func render(
        _ scene: MK2PaulincheSongScene,
        actions: MK2PaulincheSongActions = MK2PaulincheSongActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: orderScreen(scene, actions: actions, renderer: renderer),
            right: overviewScreen(scene, actions: actions, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheSongScene,
        actions: MK2PaulincheSongActions = MK2PaulincheSongActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    private static func orderScreen(
        _ scene: MK2PaulincheSongScene,
        actions: MK2PaulincheSongActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: scene.title, subtitle: scene.subtitle, subtitleAlignment: .trailing),
            footer: .filters(height: 42)
        ) {
            MK2RenderBlock { frame, context in
                drawOrders(scene.orders, into: &frame, context: context, renderer: renderer)
                drawFooterSoftKeys(scene.softKeys, into: &frame, context: context, renderer: renderer)
            }
            MK2PaulincheRendererSupport.softKeyBindings(scene.softKeys, onSoftKey: actions.onSoftKey)
        }.build(renderer: renderer)
    }

    private static func overviewScreen(
        _ scene: MK2PaulincheSongScene,
        actions: MK2PaulincheSongActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "SONG", subtitle: scene.subtitle, subtitleAlignment: .trailing),
            footer: .filters(height: 42)
        ) {
            MK2RenderBlock { frame, context in
                guard let content = context.layout?.contentRect else { return }
                MK2PaulincheRendererSupport.drawParameterSlots(
                    scene.parameters,
                    in: MK2PixelRect(x: content.x + 8, y: content.y + 8, width: 448, height: 118),
                    into: &frame,
                    renderer: renderer
                )
                MK2PaulincheRendererSupport.drawText(
                    "ARRANGEMENT POSITION",
                    into: &frame,
                    x: content.x + 16,
                    y: content.y + 126,
                    style: MK2PaulincheRendererSupport.captionStyle(color: MK2HIG.Chrome.dim),
                    renderer: renderer,
                    maxWidth: 240
                )
                drawFooterSoftKeys(scene.softKeys, into: &frame, context: context, renderer: renderer)
            }
            MK2ProgressBarElement(
                rect: MK2PixelRect(x: 16, y: 146, width: 432, height: 14),
                progress: scene.progress
            )
            MK2PaulincheRendererSupport.softKeyBindings(scene.softKeys, onSoftKey: actions.onSoftKey)
        }.build(renderer: renderer)
    }

    private static func drawOrders(
        _ orders: [MK2PaulincheSongOrder],
        into frame: inout MK2PixelFrame,
        context: MK2ScreenContext,
        renderer: FreeTypeTextRenderer?
    ) {
        guard let contentRect = context.layout?.contentRect else { return }
        let rowHeight = 24
        let visibleRows = max(0, min(orders.count, contentRect.height / rowHeight))
        MK2PaulincheRendererSupport.drawText("ORD", into: &frame, x: contentRect.x + 6, y: contentRect.y, style: MK2PaulincheRendererSupport.monoCaptionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: 42)
        MK2PaulincheRendererSupport.drawText("PATTERN", into: &frame, x: contentRect.x + 56, y: contentRect.y, style: MK2PaulincheRendererSupport.monoCaptionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: 92)
        MK2PaulincheRendererSupport.drawText("ROWS", into: &frame, x: contentRect.maxX - 58, y: contentRect.y, style: MK2PaulincheRendererSupport.monoCaptionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: 52)

        for (visibleIndex, order) in orders.prefix(visibleRows).enumerated() {
            let y = contentRect.y + 18 + visibleIndex * rowHeight
            let rowRect = MK2PixelRect(x: contentRect.x + 2, y: y - 3, width: contentRect.width - 4, height: rowHeight - 2)
            if order.isPlaybackOrder {
                frame.fill(rowRect, MK2PaulincheRendererSupport.Palette.playbackRow)
            }
            if order.isSelected {
                frame.fill(rowRect, MK2PaulincheRendererSupport.Palette.selectedRow)
                frame.fill(MK2PixelRect(x: rowRect.x - 3, y: rowRect.y + 5, width: 3, height: 8), MK2HIG.Chrome.accent)
            }

            let primaryColor = order.isSelected ? MK2HIG.Chrome.text : 0xbdf7
            let secondaryColor = order.isSelected ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim
            MK2PaulincheRendererSupport.drawText(String(format: "%02d", order.index + 1), into: &frame, x: contentRect.x + 6, y: y, style: MK2PaulincheRendererSupport.monoBodyStyle(color: secondaryColor), renderer: renderer, maxWidth: 40)
            MK2PaulincheRendererSupport.drawText(order.patternLabel, into: &frame, x: contentRect.x + 56, y: y, style: MK2PaulincheRendererSupport.monoBodyStyle(color: primaryColor), renderer: renderer, maxWidth: 88)
            MK2PaulincheRendererSupport.drawText(order.title, into: &frame, x: contentRect.x + 150, y: y, style: MK2PaulincheRendererSupport.bodyStyle(color: primaryColor), renderer: renderer, maxWidth: 210)
            MK2PaulincheRendererSupport.drawText("\(order.rowCount)", into: &frame, x: contentRect.maxX - 54, y: y, style: MK2PaulincheRendererSupport.monoBodyStyle(color: secondaryColor), renderer: renderer, maxWidth: 48)
        }
    }

    private static func drawFooterSoftKeys(
        _ softKeys: [MK2PaulincheSoftKey],
        into frame: inout MK2PixelFrame,
        context: MK2ScreenContext,
        renderer: FreeTypeTextRenderer?
    ) {
        guard let footer = context.layout?.footerRect else { return }
        MK2PaulincheRendererSupport.drawSoftKeyStrip(softKeys, into: &frame, renderer: renderer, y: footer.y, height: footer.height)
    }
}
