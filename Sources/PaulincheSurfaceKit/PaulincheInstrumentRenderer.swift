import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public enum MK2PaulincheInstrumentKind: Sendable, Equatable {
    case sample
    case wavetable
}

public struct MK2PaulincheInstrumentScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var instrumentIndex: Int
    public var kind: MK2PaulincheInstrumentKind
    public var detail: String
    public var playheadProgress: Double?
    public var waveform: [Double]
    public var parameters: [MK2PaulinchePatternParameter]
    public var meters: [MK2PaulinchePatternMeter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        instrumentIndex: Int,
        kind: MK2PaulincheInstrumentKind,
        detail: String,
        playheadProgress: Double? = nil,
        waveform: [Double] = [],
        parameters: [MK2PaulinchePatternParameter],
        meters: [MK2PaulinchePatternMeter] = [],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.instrumentIndex = max(0, instrumentIndex)
        self.kind = kind
        self.detail = detail
        self.playheadProgress = playheadProgress.map { MK2PaulincheRendererSupport.clamped01($0) }
        self.waveform = waveform.map { Swift.max(-1, Swift.min(1, $0)) }
        self.parameters = Array(parameters.prefix(8))
        self.meters = meters
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulincheInstrumentActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?

    public init(onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil) {
        self.onSoftKey = onSoftKey
    }
}

public enum MK2PaulincheInstrumentRenderer {
    public static func render(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions = MK2PaulincheInstrumentActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        let textRenderer = renderer ?? (try? FreeTypeTextRenderer())
        return MK2DoubleScreenDSL(
            left: identityScreen(scene, actions: actions, renderer: textRenderer),
            right: parameterScreen(scene, actions: actions, renderer: textRenderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions = MK2PaulincheInstrumentActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    private static func identityScreen(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: scene.title, subtitle: scene.subtitle, subtitleAlignment: .trailing),
            footer: .filters(height: 42)
        ) {
            MK2RenderBlock { frame, context in
                drawInstrumentIdentity(scene, into: &frame, context: context, renderer: renderer)
                drawFooterSoftKeys(scene.softKeys, into: &frame, context: context, renderer: renderer)
            }
            MK2PaulincheRendererSupport.softKeyBindings(scene.softKeys, onSoftKey: actions.onSoftKey)
        }.build(renderer: renderer)
    }

    private static func parameterScreen(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: scene.kind.label, subtitle: String(format: "INS %02d", scene.instrumentIndex + 1), subtitleAlignment: .trailing),
            footer: .filters(height: 42)
        ) {
            MK2RenderBlock { frame, context in
                guard let content = context.layout?.contentRect else { return }
                MK2PaulincheRendererSupport.drawParameterSlots(
                    scene.parameters,
                    in: MK2PixelRect(x: content.x + 8, y: content.y + 8, width: 448, height: scene.meters.isEmpty ? 132 : 104),
                    into: &frame,
                    renderer: renderer
                )
                if !scene.meters.isEmpty {
                    MK2PaulincheRendererSupport.drawMeters(
                        scene.meters,
                        in: MK2PixelRect(x: content.x + 16, y: content.y + 150, width: 432, height: 32),
                        into: &frame,
                        renderer: renderer
                    )
                }
                drawFooterSoftKeys(scene.softKeys, into: &frame, context: context, renderer: renderer)
            }
            MK2EncoderDiscreteValuesElement(parameterEncoderValues(scene.parameters), drawsDisplays: false)
            if let progress = scene.playheadProgress {
                MK2ProgressBarElement(rect: MK2PixelRect(x: 16, y: scene.meters.isEmpty ? 150 : 134, width: 432, height: 12), progress: progress)
            }
            MK2PaulincheRendererSupport.softKeyBindings(scene.softKeys, onSoftKey: actions.onSoftKey)
        }.build(renderer: renderer)
    }

    private static func drawInstrumentIdentity(
        _ scene: MK2PaulincheInstrumentScene,
        into frame: inout MK2PixelFrame,
        context: MK2ScreenContext,
        renderer: FreeTypeTextRenderer?
    ) {
        guard let contentRect = context.layout?.contentRect else { return }
        let tagRect = MK2PixelRect(x: contentRect.x + 8, y: contentRect.y + 4, width: 118, height: 28)
        frame.fillRounded(tagRect, radius: 5, MK2PaulincheRendererSupport.Palette.panelFill, antialiased: true)
        frame.stroke(tagRect, MK2HIG.Chrome.border)
        MK2PaulincheRendererSupport.drawText(scene.kind.label.uppercased(), into: &frame, x: tagRect.x + 10, y: tagRect.y + 7, style: MK2PaulincheRendererSupport.captionStyle(color: MK2HIG.Chrome.accent), renderer: renderer, maxWidth: tagRect.width - 20)
        MK2PaulincheRendererSupport.drawText(String(format: "SLOT %02d", scene.instrumentIndex + 1), into: &frame, x: tagRect.maxX + 16, y: tagRect.y + 7, style: MK2PaulincheRendererSupport.captionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: 120)
        MK2PaulincheRendererSupport.drawWrappedText(scene.detail, into: &frame, x: contentRect.x + 8, y: contentRect.y + 44, style: MK2PaulincheRendererSupport.bodyStyle(color: MK2HIG.Chrome.text), renderer: renderer, maxWidth: contentRect.width - 16, maxLines: 2, lineSpacing: 2)
        drawWaveform(scene.waveform, playheadProgress: scene.playheadProgress, rect: MK2PixelRect(x: contentRect.x + 8, y: contentRect.y + 102, width: contentRect.width - 16, height: 70), into: &frame)
    }

    private static func drawWaveform(
        _ samples: [Double],
        playheadProgress: Double?,
        rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        frame.fillRounded(rect, radius: 4, MK2PaulincheRendererSupport.Palette.secondaryPanelFill, antialiased: true)
        frame.stroke(rect, MK2HIG.Chrome.border)
        let inner = MK2PixelRect(x: rect.x + 3, y: rect.y + 3, width: max(0, rect.width - 6), height: max(0, rect.height - 6))
        let midY = inner.y + inner.height / 2
        frame.fill(MK2PixelRect(x: inner.x, y: midY, width: inner.width, height: 1), MK2HIG.Chrome.border)

        guard !samples.isEmpty else { return }
        let sourceSpan = Double(max(1, samples.count - 1))
        let targetSpan = Double(max(1, inner.width - 1))
        for xOffset in 0..<inner.width {
            let position = Double(xOffset) / targetSpan
            let sampleIndex = min(samples.count - 1, Int((position * sourceSpan).rounded()))
            let amplitude = samples[sampleIndex]
            let height = max(1, Int((abs(amplitude) * Double(inner.height - 2) / 2).rounded()))
            let y = amplitude >= 0 ? midY - height : midY
            frame.fill(MK2PixelRect(x: inner.x + xOffset, y: y, width: 1, height: height), 0x464f)
        }

        if let playheadProgress {
            let x = inner.x + Int((Double(max(0, inner.width - 1)) * playheadProgress).rounded())
            frame.fill(MK2PixelRect(x: x, y: inner.y, width: 2, height: inner.height), MK2HIG.Chrome.accent)
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

    private static func parameterEncoderValues(_ parameters: [MK2PaulinchePatternParameter]) -> [MK2EncoderDiscreteValue] {
        parameters.prefix(8).enumerated().map { index, _ in
            MK2EncoderDiscreteValue(
                encoder: index + 1,
                value: 0,
                bounds: -128...127,
                wraps: false,
                onChange: { _ in }
            )
        }
    }
}

private extension MK2PaulincheInstrumentKind {
    var label: String {
        switch self {
            case .sample:
                "SAMPLE"
            case .wavetable:
                "WAVETABLE"
        }
    }
}
