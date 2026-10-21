import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public enum MK2PaulincheInstrumentKind: Sendable, Equatable {
    case sample
    case wavetable
}

public enum MK2PaulincheWavetablePage: Int, Sendable, Equatable, CaseIterable {
    case source
    case attack
    case performance
    case filterBank
    case ringAndSweep
    case pwm
    case vibrato
    case frameScan
    case tremolo
    case envelopes
    case stepSequence

    var title: String {
        switch self {
            case .source: "SOURCE"
            case .attack: "PCM ATTACK"
            case .performance: "PERFORMANCE"
            case .filterBank: "FILTER BANK"
            case .ringAndSweep: "RING + SWEEP"
            case .pwm: "PWM"
            case .vibrato: "VIBRATO"
            case .frameScan: "FRAME SCAN"
            case .tremolo: "TREMOLO"
            case .envelopes: "ENVELOPES"
            case .stepSequence: "PITCH / VOLUME"
        }
    }
}

public enum MK2PaulincheHybridTimelineSegment: Sendable, Equatable {
    case attack
    case body
}

/// Product-specific render data for the D-50-style PCM-to-wavetable signal
/// flow. The two segments stay semantic here; the renderer adapts them to the
/// physical pair of 480-pixel displays.
public struct MK2PaulincheHybridTimeline: Sendable, Equatable {
    public var attackWaveform: MK2WaveformEnvelope
    public var bodyWaveform: MK2WaveformEnvelope
    public var bodyFrameCount: Int
    public var attackStartFraction: Double
    public var attackEndFraction: Double
    public var crossfadeFraction: Double
    public var playheadSegment: MK2PaulincheHybridTimelineSegment?
    public var playheadProgress: Double?

    public init(
        attackWaveform: MK2WaveformEnvelope,
        bodyWaveform: MK2WaveformEnvelope,
        bodyFrameCount: Int,
        attackStartFraction: Double,
        attackEndFraction: Double,
        crossfadeFraction: Double,
        playheadSegment: MK2PaulincheHybridTimelineSegment? = nil,
        playheadProgress: Double? = nil
    ) {
        let start = MK2PaulincheRendererSupport.clamped01(attackStartFraction)
        self.attackWaveform = attackWaveform
        self.bodyWaveform = bodyWaveform
        self.bodyFrameCount = max(1, bodyFrameCount)
        self.attackStartFraction = start
        self.attackEndFraction = max(start, MK2PaulincheRendererSupport.clamped01(attackEndFraction))
        self.crossfadeFraction = MK2PaulincheRendererSupport.clamped01(crossfadeFraction)
        if let playheadSegment, let playheadProgress {
            self.playheadSegment = playheadSegment
            self.playheadProgress = MK2PaulincheRendererSupport.clamped01(playheadProgress)
        } else {
            self.playheadSegment = nil
            self.playheadProgress = nil
        }
    }
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
    public var wavetablePage: MK2PaulincheWavetablePage?
    public var instrumentColorGradient: MK2PaulincheInstrumentColorGradient
    public var infoLines: [String]
    public var playheadProgress: Double?
    public var waveform: MK2WaveformEnvelope
    public var hybridTimeline: MK2PaulincheHybridTimeline?
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
        wavetablePage: MK2PaulincheWavetablePage? = nil,
        instrumentColorGradient: MK2PaulincheInstrumentColorGradient = .fallback,
        infoLines: [String] = [],
        playheadProgress: Double? = nil,
        waveform: MK2WaveformEnvelope = MK2WaveformEnvelope(minima: [], maxima: []),
        hybridTimeline: MK2PaulincheHybridTimeline? = nil,
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
        self.wavetablePage = wavetablePage
        self.instrumentColorGradient = instrumentColorGradient
        self.infoLines = infoLines
        self.playheadProgress = playheadProgress.map { MK2PaulincheRendererSupport.clamped01($0) }
        self.waveform = waveform
        self.hybridTimeline = hybridTimeline
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

/// Renders both instrument workflows in the tracker's surface layout. Samples
/// keep the waveform/region view; wavetables use a dual-screen sound-design
/// page with page-specific graphics and both F-key bars. Encoder slots remain
/// bottom-flush above their physical controls in either workflow.
public enum MK2PaulincheInstrumentRenderer {
    static let encoderSlotRect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)
    static let waveformRect = MK2PixelRect(x: 8, y: 32, width: 464, height: 174)
    static let instrumentColorRect = MK2PixelRect(x: 430, y: 4, width: 42, height: 24)

    public static func render(
        _ scene: MK2PaulincheInstrumentScene,
        actions: MK2PaulincheInstrumentActions = MK2PaulincheInstrumentActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        if scene.kind == .wavetable, let page = scene.wavetablePage {
            return MK2DoubleScreenDSL(
                left: wavetableScreen(scene, page: page, side: .left, actions: actions, renderer: renderer),
                right: wavetableScreen(scene, page: page, side: .right, actions: actions, renderer: renderer)
            )
        }
        return MK2DoubleScreenDSL(
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

    private enum WavetableScreenSide {
        case left
        case right

        var parameterRange: Range<Int> {
            self == .left ? 0..<4 : 4..<8
        }

        var functionSide: MK2FunctionKeyBarElement.Side {
            self == .left ? .left : .right
        }

        var functionOffset: Int {
            self == .left ? 0 : 4
        }
    }

    private static let wavetableVisualizationRect = MK2PixelRect(x: 8, y: 53, width: 464, height: 151)

    private static func wavetableScreen(
        _ scene: MK2PaulincheInstrumentScene,
        page: MK2PaulincheWavetablePage,
        side: WavetableScreenSide,
        actions: MK2PaulincheInstrumentActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Support = MK2PaulincheRendererSupport
        let offset = side.functionOffset
        return MK2FullScreenDSL(background: Support.Palette.background) {
            MK2FunctionKeyBarElement(
                slots: functionKeySlots(scene.softKeys, range: offset..<(offset + 4)),
                side: side.functionSide,
                onPress: softKeyPress(scene.softKeys, offset: offset, handler: actions.onSoftKey)
            )
            MK2ContentText(
                side == .left ? page.title : scene.title.uppercased(),
                x: 8,
                y: 27,
                maxWidth: side == .right && scene.hybridTimeline != nil ? 246 : 330,
                role: .custom(weight: .bold, pixelSize: 14),
                color: Support.Palette.blue,
                relativeToContent: false
            )
            if side == .right, scene.hybridTimeline != nil {
                MK2TagElement(
                    "HYBRID",
                    x: 270,
                    y: 24,
                    height: 20,
                    minWidth: 68,
                    pixelSize: 10,
                    colors: MK2TagColors(
                        text: Support.Palette.orange,
                        fill: Support.Palette.panelFill,
                        border: Support.Palette.border
                    ),
                    relativeToContent: false
                )
            }
            MK2ContentText(
                String(format: "PAGE %d/%d", page.rawValue + 1, MK2PaulincheWavetablePage.allCases.count),
                x: 356,
                y: 29,
                maxWidth: 116,
                role: .custom(weight: .medium, pixelSize: 11),
                color: Support.Palette.dim,
                relativeToContent: false
            )
            MK2RenderBlock { frame, _ in
                drawWavetableVisualization(
                    scene,
                    page: page,
                    side: side,
                    into: &frame,
                    renderer: renderer
                )
            }
            MK2ParameterPageElement(
                slots: parameterPageSlots(scene.parameters, range: side.parameterRange),
                rect: encoderSlotRect,
                columns: 4,
                relativeToContent: false
            )
            encoderBindings(scene.parameters, range: side.parameterRange, actions: actions)
        }.build(renderer: renderer)
    }

    private static func drawWavetableVisualization(
        _ scene: MK2PaulincheInstrumentScene,
        page: MK2PaulincheWavetablePage,
        side: WavetableScreenSide,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let rect = wavetableVisualizationRect
        frame.fillRoundedVerticalGradient(
            rect,
            radius: 7,
            top: Support.Palette.panelFill,
            bottom: Support.Palette.secondaryPanelFill,
            antialiased: true
        )
        frame.stroke(rect, Support.Palette.border)
        let title = visualizationTitle(page: page, side: side)
        Support.drawText(
            title,
            into: &frame,
            x: rect.x + 10,
            y: rect.y + 8,
            style: Support.captionStyle(color: Support.Palette.credit),
            renderer: renderer,
            maxWidth: rect.width - 20
        )
        let graph = MK2PixelRect(x: rect.x + 10, y: rect.y + 30, width: rect.width - 20, height: rect.height - 42)
        if let hybridTimeline = scene.hybridTimeline {
            drawHybridPhaseRail(hybridTimeline, side: side, in: rect, into: &frame)
        }
        switch page {
            case .source:
                if side == .left {
                    let bodyWaveform = scene.hybridTimeline?.bodyWaveform ?? scene.waveform
                    MK2WaveformDisplay(
                        envelope: bodyWaveform,
                        rect: graph,
                        playhead: bodyPlayhead(in: scene)
                    ).draw(into: &frame)
                } else {
                    drawFrameBank(scene, in: graph, into: &frame)
                }
            case .attack:
                if let hybridTimeline = scene.hybridTimeline {
                    if side == .left {
                        drawHybridAttack(hybridTimeline, in: graph, into: &frame)
                    } else {
                        drawHybridBody(hybridTimeline, in: graph, into: &frame)
                    }
                } else if side == .left {
                    MK2WaveformDisplay(envelope: scene.waveform, rect: graph).draw(into: &frame)
                } else {
                    drawFrameBank(scene, in: graph, into: &frame)
                }
            case .performance:
                if side == .left {
                    drawVarianceBars(scene, in: graph, into: &frame)
                } else {
                    drawTriggerCloud(scene, in: graph, into: &frame)
                }
            case .filterBank:
                drawFilterResponse(scene, alternate: side == .right, in: graph, into: &frame)
            case .ringAndSweep:
                if side == .left {
                    drawRingMod(scene, in: graph, into: &frame)
                } else {
                    drawSweep(scene, in: graph, into: &frame)
                }
            case .pwm, .vibrato, .frameScan, .tremolo:
                if side == .left {
                    drawLFO(scene, in: graph, into: &frame)
                } else if page == .frameScan {
                    drawFrameBank(scene, in: graph, into: &frame)
                } else {
                    drawModulationOnset(scene, in: graph, into: &frame)
                }
            case .stepSequence:
                if side == .left {
                    MK2WaveformDisplay(envelope: scene.waveform, rect: graph).draw(into: &frame)
                } else {
                    drawFrameBank(scene, in: graph, into: &frame)
                }
            case .envelopes:
                if side == .left {
                    drawAmplitudeEnvelope(scene, in: graph, into: &frame)
                } else {
                    drawPitchEnvelope(scene, in: graph, into: &frame)
                }
        }
        if side == .right {
            for (index, line) in scene.infoLines.prefix(2).enumerated() {
                Support.drawText(
                    line.uppercased(),
                    into: &frame,
                    x: graph.x + 4,
                    y: graph.maxY - 31 + index * 15,
                    style: Support.monoCaptionStyle(color: index == 0 ? Support.Palette.credit : Support.Palette.dim),
                    renderer: renderer,
                    maxWidth: graph.width - 8
                )
            }
        }
    }

    private static func visualizationTitle(page: MK2PaulincheWavetablePage, side: WavetableScreenSide) -> String {
        switch (page, side) {
            case (.source, .left): "CURRENT BANK"
            case (.source, .right): "FRAME OVERVIEW"
            case (.attack, .left): "PCM TRANSIENT"
            case (.attack, .right): "WAVETABLE BODY"
            case (.performance, .left): "VARIANCE RANGES"
            case (.performance, .right): "PER-NOTE DISTRIBUTION"
            case (.filterBank, .left): "START RESPONSE"
            case (.filterBank, .right): "END RESPONSE"
            case (.ringAndSweep, .left): "RING MOD"
            case (.ringAndSweep, .right): "TIMBRE SWEEP"
            case (.pwm, .left): "PWM SHAPE"
            case (.pwm, .right): "PWM ONSET"
            case (.vibrato, .left): "PITCH LFO"
            case (.vibrato, .right): "VIBRATO ONSET"
            case (.frameScan, .left): "SCAN LFO"
            case (.frameScan, .right): "FRAME RANGE"
            case (.tremolo, .left): "LEVEL LFO"
            case (.tremolo, .right): "TREMOLO ONSET"
            case (.stepSequence, .left): "WAVEFORM CONTEXT"
            case (.stepSequence, .right): "BANK CONTEXT"
            case (.envelopes, .left): "AMPLITUDE ADSR"
            case (.envelopes, .right): "PITCH ENVELOPE"
        }
    }

    /// The desktop keeps its hybrid timeline pinned above the complete editor.
    /// On the dual-display surface the same overview becomes a two-part rail:
    /// PCM on the left panel, wavetable body on the right panel. It remains
    /// visible on every sound-design page while the larger graph stays
    /// dedicated to that page's parameters.
    private static func drawHybridPhaseRail(
        _ timeline: MK2PaulincheHybridTimeline,
        side: WavetableScreenSide,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let rail = MK2PixelRect(x: rect.x + 10, y: rect.y + 24, width: rect.width - 20, height: 3)
        let segmentColor = side == .left ? Support.Palette.orange : Support.Palette.blue
        frame.fill(rail, Support.Palette.track)
        frame.fill(MK2PixelRect(x: rail.x, y: rail.y + 1, width: rail.width, height: 1), segmentColor)

        if side == .left, timeline.crossfadeFraction > 0 {
            let crossfadeWidth = max(1, Int((Double(rail.width) * timeline.crossfadeFraction).rounded()))
            let startX = rail.maxX - crossfadeWidth
            for x in startX..<rail.maxX {
                let progress = Double(x - startX) / Double(max(1, crossfadeWidth - 1))
                frame[x, rail.y + 1] = MK2OrderedDither.lerp(
                    Support.Palette.orange,
                    Support.Palette.blue,
                    t: progress,
                    x: x,
                    y: rail.y + 1
                )
            }
        }

        let matchingSegment: MK2PaulincheHybridTimelineSegment = side == .left ? .attack : .body
        if timeline.playheadSegment == matchingSegment, let progress = timeline.playheadProgress {
            let x = rail.x + Int((progress * Double(max(1, rail.width - 1))).rounded())
            frame.fill(
                MK2PixelRect(x: min(rail.maxX - 2, x), y: rail.y - 1, width: 2, height: rail.height + 2),
                MK2HIG.Waveform.playhead
            )
        }
    }

    private static func drawHybridAttack(
        _ timeline: MK2PaulincheHybridTimeline,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        let region = timeline.attackStartFraction...timeline.attackEndFraction
        MK2WaveformDisplay(
            envelope: timeline.attackWaveform,
            rect: rect,
            region: region
        ).draw(into: &frame)
        drawHybridCrossfade(timeline, in: rect, into: &frame)
        if timeline.playheadSegment == .attack, let progress = timeline.playheadProgress {
            let position = timeline.attackStartFraction
                + (progress * (timeline.attackEndFraction - timeline.attackStartFraction))
            drawWaveformPlayhead(position, in: rect, into: &frame)
        }
    }

    private static func drawHybridBody(
        _ timeline: MK2PaulincheHybridTimeline,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        // The right screen's two info lines own the lower graph rows.
        let waveformRect = MK2PixelRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: max(24, rect.height - 34)
        )
        MK2WaveformDisplay(envelope: timeline.bodyWaveform, rect: waveformRect).draw(into: &frame)

        let inner = waveformInnerRect(waveformRect)
        let visibleFrameGroups = min(16, timeline.bodyFrameCount)
        if visibleFrameGroups > 1, !inner.isEmpty {
            for boundary in 1..<visibleFrameGroups {
                let fraction = Double(boundary) / Double(visibleFrameGroups)
                let x = inner.x + Int((fraction * Double(max(1, inner.width - 1))).rounded())
                frame.fill(MK2PixelRect(x: x, y: inner.y, width: 1, height: inner.height), Support.Palette.track)
            }
        }
        if timeline.playheadSegment == .body, let progress = timeline.playheadProgress {
            drawWaveformPlayhead(progress, in: waveformRect, into: &frame)
        }
    }

    private static func drawHybridCrossfade(
        _ timeline: MK2PaulincheHybridTimeline,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let inner = waveformInnerRect(rect)
        guard !inner.isEmpty,
              timeline.crossfadeFraction > 0,
              timeline.attackEndFraction > timeline.attackStartFraction
        else { return }

        let activeWidth = timeline.attackEndFraction - timeline.attackStartFraction
        let crossfadeStart = timeline.attackEndFraction - activeWidth * timeline.crossfadeFraction
        let startX = inner.x + Int((crossfadeStart * Double(max(1, inner.width - 1))).rounded())
        let endX = inner.x + Int((timeline.attackEndFraction * Double(max(1, inner.width - 1))).rounded())
        guard endX >= startX else { return }

        for x in startX...min(inner.maxX - 1, endX) {
            let progress = Double(x - startX) / Double(max(1, endX - startX))
            let tint = 0.08 + (0.22 * progress)
            for y in inner.y..<inner.maxY {
                frame[x, y] = MK2OrderedDither.lerp(
                    frame[x, y],
                    Support.Palette.orange,
                    t: tint,
                    x: x,
                    y: y
                )
            }
        }
        frame.fill(
            MK2PixelRect(x: max(inner.x, startX), y: inner.y, width: 1, height: inner.height),
            Support.Palette.orange
        )
    }

    private static func drawWaveformPlayhead(
        _ progress: Double,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        let inner = waveformInnerRect(rect)
        guard !inner.isEmpty else { return }
        let clamped = MK2PaulincheRendererSupport.clamped01(progress)
        let x = inner.x + Int((clamped * Double(max(1, inner.width - 1))).rounded())
        frame.fill(
            MK2PixelRect(x: min(inner.maxX - 2, x), y: inner.y, width: 2, height: inner.height),
            MK2HIG.Waveform.playhead
        )
    }

    private static func waveformInnerRect(_ rect: MK2PixelRect) -> MK2PixelRect {
        MK2PixelRect(x: rect.x + 2, y: rect.y + 2, width: max(0, rect.width - 4), height: max(0, rect.height - 4))
    }

    private static func level(_ scene: MK2PaulincheInstrumentScene, _ index: Int) -> Double {
        guard scene.parameters.indices.contains(index) else { return 0 }
        return MK2PaulincheRendererSupport.clamped01(
            scene.parameters[index].isEnabled ? (scene.parameters[index].level ?? 0) : 0
        )
    }

    private static func drawFrameBank(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let count = 12
        let gap = 4
        let width = max(4, (rect.width - gap * (count - 1)) / count)
        for index in 0..<count {
            let progress = Double(index) / Double(max(1, count - 1))
            let amplitude = 0.25 + 0.65 * abs(sin(progress * .pi * 2 + level(scene, 3) * .pi))
            let height = max(5, Int(Double(rect.height - 32) * amplitude))
            let x = rect.x + index * (width + gap)
            let y = rect.y + 5 + (rect.height - 32 - height) / 2
            frame.fill(MK2PixelRect(x: x, y: y, width: width, height: height), index % 2 == 0 ? Support.Palette.blue : Support.Palette.green)
        }
        if let playhead = bodyPlayhead(in: scene) {
            let playheadRect = MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: max(1, rect.height - 27))
            drawWaveformPlayhead(playhead, in: playheadRect, into: &frame)
        }
    }

    private static func bodyPlayhead(in scene: MK2PaulincheInstrumentScene) -> Double? {
        guard let hybridTimeline = scene.hybridTimeline else { return scene.playheadProgress }
        guard hybridTimeline.playheadSegment == .body else { return nil }
        return hybridTimeline.playheadProgress
    }

    private static func drawVarianceBars(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        for index in 0..<5 {
            let y = rect.y + 4 + index * 18
            frame.centeredBar(
                MK2PixelRect(x: rect.x + 20, y: y, width: rect.width - 40, height: 7),
                value: level(scene, index),
                fill: index == 0 ? Support.Palette.orange : Support.Palette.blue,
                track: Support.Palette.track
            )
        }
    }

    private static func drawTriggerCloud(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let spread = level(scene, 0) + level(scene, 1) + level(scene, 2) + level(scene, 3) + level(scene, 4)
        frame.hline(y: rect.y + rect.height / 2, x: rect.x, width: rect.width, color: Support.Palette.track)
        for index in 0..<31 {
            let seed = Double((index * 37) % 101) / 100
            let xOffset = (seed - 0.5) * min(1, spread / 2.5)
            let ySeed = Double((index * 61) % 97) / 96
            let x = rect.x + rect.width / 2 + Int(xOffset * Double(rect.width - 20))
            let y = rect.y + 8 + Int(ySeed * Double(rect.height - 32))
            frame.fill(MK2PixelRect(x: x, y: y, width: 3, height: 3), index % 3 == 0 ? Support.Palette.orange : Support.Palette.blue)
        }
    }

    private static func drawFilterResponse(
        _ scene: MK2PaulincheInstrumentScene,
        alternate: Bool,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let cutoff = level(scene, alternate ? 3 : 2)
        let resonance = level(scene, 4)
        let poles = 1 + Int((level(scene, 1) * 3).rounded())
        let filterType = scene.parameters.first?.value.uppercased() ?? "LP"
        frame.hline(y: rect.maxY - 18, x: rect.x, width: rect.width, color: Support.Palette.track)
        var points: [(Int, Int)] = []
        for x in 0..<rect.width {
            let position = Double(x) / Double(max(1, rect.width - 1))
            let slope = max(2, Double(poles) * 4)
            let lowpass = 1 / (1 + exp((position - cutoff) * slope * 4))
            let response: Double
            if filterType.contains("HP") {
                response = 1 - lowpass
            } else if filterType.contains("BP") {
                response = exp(-pow((position - cutoff) * slope * 2.2, 2))
            } else {
                response = lowpass
            }
            let peak = resonance * exp(-pow((position - cutoff) * 25, 2)) * 0.65
            let value = min(1, response + peak)
            points.append((rect.x + x, rect.maxY - 18 - Int(value * Double(rect.height - 30))))
        }
        drawPolyline(points, color: alternate ? Support.Palette.green : Support.Palette.orange, into: &frame)
    }

    private static func drawRingMod(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let harmonic = 1 + Int((level(scene, 0) * 15).rounded())
        let depth = 0.15 + level(scene, 1) * 0.8
        let center = rect.y + (rect.height - 22) / 2
        var points: [(Int, Int)] = []
        for x in 0..<rect.width {
            let phase = Double(x) / Double(max(1, rect.width - 1)) * .pi * 2
            let value = sin(phase) * sin(phase * Double(harmonic)) * depth
            points.append((rect.x + x, center - Int(value * Double(rect.height - 30) * 0.45)))
        }
        frame.hline(y: center, x: rect.x, width: rect.width, color: Support.Palette.track)
        drawPolyline(points, color: Support.Palette.orange, into: &frame)
    }

    private static func drawSweep(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let top = rect.y + 4
        let height = rect.height - 30
        let startY = top + height - Int(level(scene, 4) * Double(height))
        let endY = top + height - Int(level(scene, 5) * Double(height))
        drawPolyline([(rect.x + 4, startY), (rect.maxX - 4, endY)], color: Support.Palette.blue, into: &frame)
        frame.dottedHLine(y: top + height / 2, x: rect.x, width: rect.width, color: Support.Palette.track, pitch: 4)
    }

    private static func drawLFO(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let shape = scene.parameters.first?.value.uppercased() ?? "SINE"
        let depth = 0.1 + level(scene, 3) * 0.9
        let center = rect.y + (rect.height - 25) / 2
        var points: [(Int, Int)] = []
        for x in 0..<rect.width {
            let phase = Double(x) / Double(max(1, rect.width - 1))
            let cycle = phase * 2
            let value: Double
            if shape.contains("SQUARE") {
                value = cycle.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1
            } else if shape.contains("SAW") {
                value = 1 - 2 * cycle.truncatingRemainder(dividingBy: 1)
            } else if shape.contains("TRI") {
                value = 1 - 4 * abs(cycle.truncatingRemainder(dividingBy: 1) - 0.5)
            } else {
                value = sin(phase * .pi * 4)
            }
            points.append((rect.x + x, center - Int(value * depth * Double(rect.height - 34) * 0.5)))
        }
        frame.hline(y: center, x: rect.x, width: rect.width, color: Support.Palette.track)
        drawPolyline(points, color: Support.Palette.blue, into: &frame)
    }

    private static func drawModulationOnset(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let delay = level(scene, 4)
        let fade = level(scene, 5)
        let baseY = rect.maxY - 24
        let activeY = rect.y + 12
        let delayX = rect.x + Int(delay * Double(rect.width) * 0.45)
        let fadeX = min(rect.maxX - 4, delayX + Int(fade * Double(rect.width) * 0.45) + 4)
        drawPolyline(
            [(rect.x + 2, baseY), (delayX, baseY), (fadeX, activeY), (rect.maxX - 2, activeY)],
            color: Support.Palette.green,
            into: &frame
        )
    }

    private static func drawAmplitudeEnvelope(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let attackX = rect.x + 8 + Int(level(scene, 0) * Double(rect.width) * 0.22)
        let decayX = attackX + 8 + Int(level(scene, 1) * Double(rect.width) * 0.22)
        let releaseX = rect.maxX - 8 - Int(level(scene, 3) * Double(rect.width) * 0.22)
        let sustainY = rect.maxY - 22 - Int(level(scene, 2) * Double(rect.height - 38))
        drawPolyline(
            [(rect.x + 4, rect.maxY - 22), (attackX, rect.y + 8), (decayX, sustainY), (releaseX, sustainY), (rect.maxX - 4, rect.maxY - 22)],
            color: Support.Palette.green,
            into: &frame
        )
    }

    private static func drawPitchEnvelope(
        _ scene: MK2PaulincheInstrumentScene,
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame
    ) {
        typealias Support = MK2PaulincheRendererSupport
        let center = rect.y + (rect.height - 24) / 2
        let height = rect.height - 38
        let startY = rect.maxY - 22 - Int(level(scene, 4) * Double(height))
        let endY = rect.maxY - 22 - Int(level(scene, 5) * Double(height))
        frame.dottedHLine(y: center, x: rect.x, width: rect.width, color: Support.Palette.track, pitch: 4)
        drawPolyline([(rect.x + 4, startY), (rect.maxX - 4, endY)], color: Support.Palette.orange, into: &frame)
    }

    private static func drawPolyline(
        _ points: [(Int, Int)],
        color: UInt16,
        into frame: inout MK2PixelFrame
    ) {
        guard points.count > 1 else { return }
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let steps = max(abs(end.0 - start.0), abs(end.1 - start.1), 1)
            for step in 0...steps {
                let progress = Double(step) / Double(steps)
                let x = Int((Double(start.0) + Double(end.0 - start.0) * progress).rounded())
                let y = Int((Double(start.1) + Double(end.1 - start.1) * progress).rounded())
                frame.fill(MK2PixelRect(x: x, y: y, width: 2, height: 2), color)
            }
        }
    }

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
            encoderBindings(scene.parameters, range: 0..<4, actions: actions)
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
            encoderBindings(scene.parameters, range: 4..<8, actions: actions)
        }.build(renderer: renderer)
    }

    // MARK: - Shared pieces

    private static func functionKeySlots(
        _ softKeys: [MK2PaulincheSoftKey],
        range: Range<Int>
    ) -> [MK2FunctionKeySlot] {
        range.map { index in
            guard softKeys.indices.contains(index) else { return MK2FunctionKeySlot("", isEnabled: false) }
            return MK2FunctionKeySlot(
                softKeys[index].label,
                isEnabled: softKeys[index].isEnabled,
                isSelected: softKeys[index].isSelected
            )
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
                colors: parameter.isEnabled ? nil : disabledParameterColors,
                // Encoders are bound separately (velocity-scaled app-side
                // values), so the touch selection names its encoder itself.
                selectionEncoder: index + 1
            )
        }
    }

    private static func encoderBindings(
        _ parameters: [MK2PaulinchePatternParameter],
        range: Range<Int>,
        actions: MK2PaulincheInstrumentActions
    ) -> [any MK2ScreenElement] {
        range.compactMap { index in
            guard parameters.indices.contains(index), parameters[index].isEnabled else { return nil }
            let encoder = index + 1
            // Deliberately raw: Paulinche owns each instrument parameter's
            // concrete span and applies its span-aware adaptive scaler app-side.
            return MK2RawEncoderBindingElement(
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

    private static let disabledParameterColors = MK2ValueCellColors(
        label: MK2PaulincheRendererSupport.Palette.empty,
        value: MK2PaulincheRendererSupport.Palette.empty,
        border: MK2PaulincheRendererSupport.Palette.track,
        fill: MK2PaulincheRendererSupport.Palette.background,
        focusedValue: MK2PaulincheRendererSupport.Palette.empty,
        focusedFill: MK2PaulincheRendererSupport.Palette.track,
        focusedBorder: MK2PaulincheRendererSupport.Palette.track
    )
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
