import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public enum MK2PaulincheInstrumentKind: Sendable, Equatable {
    case sample
    case wavetable
}

public struct MK2PaulincheInstrumentColorGradient: Sendable, Equatable {
    public var top: KKRGB
    public var center: KKRGB
    public var bottom: KKRGB

    public init(top: KKRGB, center: KKRGB, bottom: KKRGB) {
        self.top = top
        self.center = center
        self.bottom = bottom
    }

    public static let fallback = MK2PaulincheInstrumentColorGradient(
        top: KKRGB(red: 0xff, green: 0x52, blue: 0x52),
        center: KKRGB(red: 0xff, green: 0x00, blue: 0x00),
        bottom: KKRGB(red: 0xb8, green: 0x00, blue: 0x00)
    )
}

public struct MK2PaulincheInstrumentScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var instrumentIndex: Int
    public var kind: MK2PaulincheInstrumentKind
    public var instrumentColorGradient: MK2PaulincheInstrumentColorGradient
    public var infoLines: [String]
    public var playheadProgress: Double?
    public var waveform: MK2WaveformEnvelope
    public var loopRegion: ClosedRange<Double>?
    public var markers: [Double]
    /// Fixed eight slots; the slot index is the encoder index (E1…E8).
    /// Slots with empty labels are drawn as unassigned.
    public var parameters: [MK2PaulinchePatternParameter]
    public var softKeys: [MK2PaulincheSoftKey]
    /// Alternate soft keys shown while SHIFT is held, same fixed eight-slot
    /// indexing as `softKeys`. An empty list declares no shift layer; a
    /// non-empty list makes every unassigned slot dark and inert under shift.
    public var shiftSoftKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        instrumentIndex: Int,
        kind: MK2PaulincheInstrumentKind,
        instrumentColorGradient: MK2PaulincheInstrumentColorGradient = .fallback,
        infoLines: [String] = [],
        playheadProgress: Double? = nil,
        waveform: MK2WaveformEnvelope = MK2WaveformEnvelope(minima: [], maxima: []),
        loopRegion: ClosedRange<Double>? = nil,
        markers: [Double] = [],
        parameters: [MK2PaulinchePatternParameter] = [],
        softKeys: [MK2PaulincheSoftKey] = [],
        shiftSoftKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.instrumentIndex = max(0, instrumentIndex)
        self.kind = kind
        self.instrumentColorGradient = instrumentColorGradient
        self.infoLines = infoLines
        self.playheadProgress = playheadProgress.map { MK2PaulincheRendererSupport.clamped01($0) }
        self.waveform = waveform
        self.loopRegion = loopRegion
        self.markers = markers
        self.parameters = Array(parameters.prefix(8))
        self.softKeys = Array(softKeys.prefix(8))
        self.shiftSoftKeys = Array(shiftSoftKeys.prefix(8))
    }
}

public struct MK2PaulincheInstrumentActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    public var onShiftSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    public var onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)?
    public var onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)?
    /// The "back to default" gesture; which reset an encoder means is the
    /// client's decision.
    public var onEncoderDoubleTouch: (@Sendable (_ encoder: Int) -> Void)?

    public init(
        onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil,
        onShiftSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil,
        onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)? = nil,
        onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)? = nil,
        onEncoderDoubleTouch: (@Sendable (_ encoder: Int) -> Void)? = nil
    ) {
        self.onSoftKey = onSoftKey
        self.onShiftSoftKey = onShiftSoftKey
        self.onEncoderTouch = onEncoderTouch
        self.onEncoderChange = onEncoderChange
        self.onEncoderDoubleTouch = onEncoderDoubleTouch
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
    static let instrumentColorRect = MK2PixelRect(x: 430, y: 4, width: 42, height: 24)

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
            MK2ContentText(scene.title.uppercased(), x: 8, y: 6, maxWidth: 330, role: .custom(weight: .bold, pixelSize: 15), color: Support.Palette.blue, relativeToContent: false)
            MK2RenderBlock { frame, _ in
                drawInstrumentColorGradient(scene.instrumentColorGradient, into: &frame)
            }
            MK2RenderBlock { frame, _ in
                MK2WaveformDisplay(
                    envelope: scene.waveform,
                    rect: waveformRect,
                    region: scene.loopRegion,
                    markers: scene.markers,
                    playhead: scene.playheadProgress
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

    private static func drawInstrumentColorGradient(
        _ gradient: MK2PaulincheInstrumentColorGradient,
        into frame: inout MK2PixelFrame
    ) {
        let radius = 5
        let topHeight = Int((Double(instrumentColorRect.height) * 0.48).rounded())
        let topRect = MK2PixelRect(
            x: instrumentColorRect.x,
            y: instrumentColorRect.y,
            width: instrumentColorRect.width,
            height: topHeight
        )
        let bottomRect = MK2PixelRect(
            x: instrumentColorRect.x,
            y: instrumentColorRect.y + topHeight,
            width: instrumentColorRect.width,
            height: instrumentColorRect.height - topHeight
        )
        let top = KompleteKontrolSSeriesMK2.rgb565(gradient.top)
        let center = KompleteKontrolSSeriesMK2.rgb565(gradient.center)
        let bottom = KompleteKontrolSSeriesMK2.rgb565(gradient.bottom)

        frame.fillRoundedVerticalGradient(
            instrumentColorRect,
            radius: radius,
            top: center,
            bottom: center,
            antialiased: true
        )
        frame.fillRoundedVerticalGradient(
            topRect,
            radius: radius,
            top: top,
            bottom: center,
            antialiased: true
        )
        frame.fillRoundedVerticalGradient(
            bottomRect,
            radius: radius,
            top: center,
            bottom: bottom,
            antialiased: true
        )
    }

    // MARK: - Right screen: facts and mix values

    private static func detailScreen(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Support = MK2PaulincheRendererSupport
        let softKeys = scene.softKeys
        let shiftSoftKeys = scene.shiftSoftKeys
        return MK2FullScreenDSL(background: Support.Palette.background) {
            if shiftSoftKeys.isEmpty {
                MK2FunctionKeyBarElement(
                    slots: functionKeySlots(softKeys, range: 4..<8),
                    side: .right,
                    onPress: softKeyPress(softKeys, offset: 4, handler: actions.onSoftKey)
                )
            } else {
                MK2FunctionKeyBarElement(
                    slots: functionKeySlots(softKeys, range: 4..<8),
                    shiftSlots: functionKeySlots(shiftSoftKeys, range: 4..<8),
                    side: .right,
                    onPress: softKeyPress(softKeys, offset: 4, handler: actions.onSoftKey),
                    onShiftPress: softKeyPress(shiftSoftKeys, offset: 4, handler: actions.onShiftSoftKey)
                )
            }
            MK2TagElement(
                scene.kind.label,
                x: 8,
                y: 28,
                minWidth: 96,
                colors: MK2TagColors(text: MK2HIG.Chrome.accent),
                relativeToContent: false
            )
            MK2ContentText(
                String(format: "SLOT %02d", scene.instrumentIndex + 1),
                x: 118,
                y: 33,
                maxWidth: 140,
                role: .custom(weight: .medium, pixelSize: 12),
                color: Support.Palette.dim,
                relativeToContent: false
            )
            MK2RenderBlock { frame, _ in
                for (index, line) in scene.infoLines.prefix(6).enumerated() {
                    Support.drawText(line.uppercased(), into: &frame, x: 8, y: 60 + index * 22, style: Support.monoBodyStyle(color: Support.Palette.dim), renderer: renderer, maxWidth: 464)
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

    // MARK: - Shared pieces

    private static func functionKeySlots(
        _ softKeys: [MK2PaulincheSoftKey],
        range: Range<Int>
    ) -> [MK2FunctionKeySlot] {
        range.map { index in
            guard softKeys.indices.contains(index) else { return MK2FunctionKeySlot("", isEnabled: false) }
            return MK2FunctionKeySlot(softKeys[index].label, isEnabled: softKeys[index].isEnabled)
        }
    }

    /// Always non-nil so enabled slots bind their F-buttons even without a
    /// handler — an unclaimed function button falling through to scene-global
    /// bindings would fire an action the bar's label does not announce.
    private static func softKeyPress(
        _ softKeys: [MK2PaulincheSoftKey],
        offset: Int,
        handler: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    ) -> @Sendable (_ slot: Int) -> Void {
        { slot in
            let index = slot + offset
            guard softKeys.indices.contains(index) else { return }
            handler?(index, softKeys[index])
        }
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
                iconGlyph: parameter.iconGlyph,
                value: parameter.value,
                isFocused: parameter.isFocused,
                // Encoders are bound separately (velocity-scaled app-side
                // values), so the touch selection names its encoder itself.
                selectionEncoder: index + 1
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
                onDoubleTouch: actions.onEncoderDoubleTouch.map { handler in
                    { @Sendable in handler(encoder) }
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
