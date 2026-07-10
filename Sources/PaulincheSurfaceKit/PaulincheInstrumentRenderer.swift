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
    public var infoLines: [String]
    public var playheadProgress: Double?
    public var waveform: MK2WaveformEnvelope
    public var loopRegion: ClosedRange<Double>?
    public var markers: [Double]
    /// Fixed eight slots; the slot index is the encoder index (E1…E8).
    /// Slots with empty labels are drawn as unassigned.
    public var parameters: [MK2PaulinchePatternParameter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        instrumentIndex: Int,
        kind: MK2PaulincheInstrumentKind,
        infoLines: [String] = [],
        playheadProgress: Double? = nil,
        waveform: MK2WaveformEnvelope = MK2WaveformEnvelope(minima: [], maxima: []),
        loopRegion: ClosedRange<Double>? = nil,
        markers: [Double] = [],
        parameters: [MK2PaulinchePatternParameter] = [],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.instrumentIndex = max(0, instrumentIndex)
        self.kind = kind
        self.infoLines = infoLines
        self.playheadProgress = playheadProgress.map { MK2PaulincheRendererSupport.clamped01($0) }
        self.waveform = waveform
        self.loopRegion = loopRegion
        self.markers = markers
        self.parameters = Array(parameters.prefix(8))
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulincheInstrumentActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    public var onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)?
    public var onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)?

    public init(
        onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil,
        onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)? = nil,
        onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)? = nil
    ) {
        self.onSoftKey = onSoftKey
        self.onEncoderTouch = onEncoderTouch
        self.onEncoderChange = onEncoderChange
    }
}

/// Renders the instrument editor in the tracker's surface layout: the left
/// screen carries the waveform with the loop region right above the encoders
/// that move it (E1–E3), the right screen carries the sample facts and the
/// mix-relevant values (E5…E7). Encoder slots sit bottom-flush above the
/// physical encoders; the function buttons stay unassigned for now.
public enum MK2PaulincheInstrumentRenderer {
    static let encoderSlotRect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)
    static let waveformRect = MK2PixelRect(x: 8, y: 32, width: 464, height: 174)

    public static func render(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions = MK2PaulincheInstrumentActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: waveformScreen(scene, actions: actions, renderer: renderer),
            right: detailScreen(scene, actions: actions, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions = MK2PaulincheInstrumentActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    // MARK: - Left screen: waveform

    private static func waveformScreen(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Support = MK2PaulincheRendererSupport
        return MK2FullScreenDSL(background: Support.Palette.background) {
            MK2RenderBlock { frame, _ in
                Support.drawText(scene.title.uppercased(), into: &frame, x: 8, y: 6, style: Support.textStyle(weight: .bold, pixelSize: 15, color: Support.Palette.blue), renderer: renderer, maxWidth: 330)
                Support.drawText(scene.subtitle.uppercased(), into: &frame, x: 344, y: 8, style: Support.captionStyle(color: Support.Palette.dim), renderer: renderer, maxWidth: 128)
                MK2WaveformDisplay(
                    envelope: scene.waveform,
                    rect: waveformRect,
                    region: scene.loopRegion,
                    markers: scene.markers,
                    playhead: scene.playheadProgress,
                    colors: waveformColors
                ).draw(into: &frame)
            }
            MK2ParameterPageElement(
                slots: parameterPageSlots(scene.parameters, range: 0..<4),
                rect: encoderSlotRect,
                columns: 4,
                relativeToContent: false
            )
            encoderBindings(range: 0..<4, actions: actions)
        }.build(renderer: renderer)
    }

    // MARK: - Right screen: facts and mix values

    private static func detailScreen(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Support = MK2PaulincheRendererSupport
        return MK2FullScreenDSL(background: Support.Palette.background) {
            MK2RenderBlock { frame, _ in
                drawKindTag(scene, into: &frame, renderer: renderer)
                for (index, line) in scene.infoLines.prefix(6).enumerated() {
                    Support.drawText(line.uppercased(), into: &frame, x: 8, y: 56 + index * 22, style: Support.monoBodyStyle(color: Support.Palette.dim), renderer: renderer, maxWidth: 464)
                }
            }
            MK2ParameterPageElement(
                slots: parameterPageSlots(scene.parameters, range: 4..<8),
                rect: encoderSlotRect,
                columns: 4,
                relativeToContent: false
            )
            encoderBindings(range: 4..<8, actions: actions)
        }.build(renderer: renderer)
    }

    private static func drawKindTag(
        _ scene: MK2PaulincheInstrumentScene,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let tagRect = MK2PixelRect(x: 8, y: 8, width: 96, height: 24)
        frame.fillRounded(tagRect, radius: 5, Support.Palette.panelFill, antialiased: true)
        frame.stroke(tagRect, MK2HIG.Chrome.border)
        Support.drawText(scene.kind.label, into: &frame, x: tagRect.x + 10, y: tagRect.y + 5, style: Support.captionStyle(color: MK2HIG.Chrome.accent), renderer: renderer, maxWidth: tagRect.width - 20)
        Support.drawText(String(format: "SLOT %02d", scene.instrumentIndex + 1), into: &frame, x: tagRect.maxX + 14, y: tagRect.y + 5, style: Support.captionStyle(color: Support.Palette.dim), renderer: renderer, maxWidth: 140)
    }

    // MARK: - Shared pieces

    private static var waveformColors: MK2WaveformDisplay.Colors {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return MK2WaveformDisplay.Colors(
            background: Palette.secondaryPanelFill,
            border: Palette.border,
            centerLine: Palette.border,
            wave: Palette.green,
            waveOutsideRegion: Palette.empty,
            regionFill: Palette.playbackRow,
            regionEdge: Palette.blue,
            marker: Palette.orange,
            playhead: MK2HIG.Chrome.accent
        )
    }

    /// Keeps the encoder-index correspondence while hiding unassigned slots:
    /// empty labels stay in place as blank cells.
    private static func parameterPageSlots(
        _ parameters: [MK2PaulinchePatternParameter],
        range: Range<Int>
    ) -> [MK2ParameterPageSlot] {
        range.map { index in
            guard parameters.indices.contains(index) else { return MK2ParameterPageSlot(label: "", value: "") }
            let parameter = parameters[index]
            return MK2ParameterPageSlot(
                label: parameter.label,
                value: parameter.value,
                isFocused: parameter.isFocused
            )
        }
    }

    private static func encoderBindings(
        range: Range<Int>,
        actions: MK2PaulincheInstrumentActions
    ) -> [any MK2ScreenElement] {
        range.map { index in
            let encoder = index + 1
            return MK2EncoderBindingElement(
                encoder,
                onTouch: { touched in
                    actions.onEncoderTouch?(encoder, touched)
                },
                onChange: { delta, _, _ in
                    actions.onEncoderChange?(encoder, delta)
                }
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
