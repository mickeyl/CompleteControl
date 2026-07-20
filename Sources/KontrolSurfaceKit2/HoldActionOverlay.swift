import Foundation
import KompleteKontrol

/// One direct choice in a held action picker or command bar.
///
/// `label` is the compact F-key caption, `value` is the larger selected-value
/// readout, and `detail` explains the action. Disabled actions remain visible
/// but do not bind or light their function key. Destructive actions use the
/// semantic warning treatment; confirmation remains the client's job.
public struct MK2HoldAction: Equatable, Sendable {
    public var label: String
    public var value: String?
    public var detail: String?
    public var isEnabled: Bool
    public var isDestructive: Bool

    public init(
        _ label: String,
        value: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
    }
}

/// A momentary, two-screen setting popup activated by holding one hardware
/// button. The overlay owns F1-F8 while visible, draws their labels in chrome
/// aligned with the physical buttons, highlights the current persistent value,
/// and can show concise help. Selecting a value changes client-owned state;
/// releasing the trigger closes the popup without reverting that setting.
///
/// Build the element and pass the returned layer to
/// `MK2DoubleScreenDSL.heldButtonLayers`. Selection is immediate on button
/// down; releasing the trigger restores the base scene.
public struct MK2HoldActionOverlayElement: Sendable {
    public var trigger: KKMK2ButtonLED
    public var title: String
    public var helpText: String?
    public var actions: [MK2HoldAction]
    public var selectedIndex: Int?
    public var background: UInt16
    public var accent: UInt16
    private let onSelect: @Sendable (_ index: Int) -> Void

    public init(
        trigger: KKMK2ButtonLED,
        title: String,
        helpText: String? = nil,
        actions: [MK2HoldAction],
        selectedIndex: Int? = nil,
        background: UInt16 = MK2HIG.Chrome.background,
        accent: UInt16 = MK2HIG.Chrome.accent,
        onSelect: @escaping @Sendable (_ index: Int) -> Void
    ) {
        self.trigger = trigger
        self.title = title
        self.helpText = helpText
        let boundedActions = Array(actions.prefix(8))
        self.actions = boundedActions
        self.selectedIndex = selectedIndex.flatMap { boundedActions.indices.contains($0) ? $0 : nil }
        self.background = background
        self.accent = accent
        self.onSelect = onSelect
    }

    public func build(renderer: FreeTypeTextRenderer? = nil) -> MK2SurfaceScene2.HeldButtonLayer {
        let left = screen(side: .left, actionOffset: 0, renderer: renderer)
        let right = screen(side: .right, actionOffset: 4, renderer: renderer)

        var bindings = MK2InputBindings2()
        for button in Self.functionButtons {
            // The overlay owns the complete F-key plane. Empty and disabled
            // slots must not leak scene actions through the fallback policy.
            bindings.onPress(button) {}
        }
        bindings.merge(left.bindings)
        bindings.merge(right.bindings)

        var lamps = Dictionary(
            uniqueKeysWithValues: Self.functionButtons.map { ($0, MK2LampState2.off) }
        )
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)
        for (index, action) in actions.enumerated()
            where action.isEnabled && !action.label.isEmpty
        {
            lamps[Self.functionButtons[index]] = .on(
                white,
                intensity: selectedIndex == index ? 0x03 : 0x01
            )
        }

        return MK2SurfaceScene2.HeldButtonLayer(
            trigger: trigger,
            left: left.screen.frame,
            right: right.screen.frame,
            lamps: lamps,
            bindings: bindings,
            buttonPolicy: .fallback,
            lampOverlayPolicy: .layerWins
        )
    }

    private func screen(
        side: MK2FunctionKeyBarElement.Side,
        actionOffset: Int,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        let slots = (0..<4).map { localIndex -> MK2FunctionKeySlot in
            let index = actionOffset + localIndex
            guard actions.indices.contains(index) else { return MK2FunctionKeySlot() }
            let action = actions[index]
            return MK2FunctionKeySlot(
                action.label,
                isEnabled: action.isEnabled,
                isSelected: selectedIndex == index,
                isDestructive: action.isDestructive
            )
        }

        return MK2FullScreenDSL(background: background) {
            MK2FunctionKeyBarElement(
                slots: slots,
                side: side,
                style: .chromeBand,
                onPress: { localIndex in
                    let index = actionOffset + localIndex
                    guard actions.indices.contains(index), actions[index].isEnabled else { return }
                    onSelect(index)
                }
            )

            if side == .left {
                MK2ContentText(
                    title.uppercased(),
                    x: 12,
                    y: 54,
                    maxWidth: 456,
                    role: .caption,
                    color: accent,
                    relativeToContent: false
                )
                MK2ContentText(
                    selectedAction?.value ?? selectedAction?.label ?? "-",
                    x: 12,
                    y: 86,
                    maxWidth: 456,
                    role: .custom(weight: MK2HIG.Fonts.titleWeight, pixelSize: 46),
                    color: MK2HIG.Chrome.text,
                    relativeToContent: false
                )
                if let detail = selectedAction?.detail {
                    MK2ContentText(
                        detail,
                        x: 12,
                        y: 154,
                        maxWidth: 456,
                        role: .body,
                        color: MK2HIG.Chrome.dim,
                        relativeToContent: false,
                        maxLines: 3,
                        lineSpacing: 2
                    )
                }
            } else {
                MK2ContentText(
                    "HOLD \(trigger.protocolName.uppercased())",
                    x: 12,
                    y: 54,
                    maxWidth: 456,
                    role: .caption,
                    color: accent,
                    relativeToContent: false
                )
                MK2ContentText(
                    helpText ?? "Choose with the function buttons above. The selection applies immediately.",
                    x: 12,
                    y: 88,
                    maxWidth: 456,
                    role: .body,
                    color: MK2HIG.Chrome.text,
                    relativeToContent: false,
                    maxLines: 5,
                    lineSpacing: 4
                )
                MK2ContentText(
                    "Release to return",
                    x: 12,
                    y: 230,
                    maxWidth: 456,
                    role: .footnote,
                    color: MK2HIG.Chrome.dim,
                    relativeToContent: false
                )
            }
        }.build(renderer: renderer)
    }

    private var selectedAction: MK2HoldAction? {
        guard let selectedIndex, actions.indices.contains(selectedIndex) else { return nil }
        return actions[selectedIndex]
    }

    private static let functionButtons: [KKMK2ButtonLED] = [
        .function1, .function2, .function3, .function4,
        .function5, .function6, .function7, .function8,
    ]
}

/// A compact held-button command popup that preserves the scene beneath it.
///
/// The layer copies the two base frames, dims the body to half RGB565
/// brightness, and replaces their top 90 pixels with a command band. It owns
/// all F1-F8 presses and lamps until `trigger` is released; empty and disabled
/// slots deliberately swallow presses. One- or two-line details are centered
/// on the same slot axis as their button labels.
///
/// Build this element after rendering the base screens and attach the returned
/// layer to the same scene. The runtime activates it only when the layer was
/// already present at trigger button-down time, so a mode-switch press cannot
/// also open a newly published command plane. Rebuild it with the base scene so
/// its pre-composited frames and availability remain current.
///
/// Each selection is an immediate, one-shot command; this element stores no
/// selected value. Use `MK2HoldActionOverlayElement` for a persistent setting
/// whose current value must remain selected across popup presentations.
public struct MK2HoldCommandBarElement: Sendable {
    public static let height = 90

    public var trigger: KKMK2ButtonLED
    public var title: String
    public var actions: [MK2HoldAction]
    public var accent: UInt16
    private let onSelect: @Sendable (_ index: Int) -> Void

    public init(
        trigger: KKMK2ButtonLED,
        title: String,
        actions: [MK2HoldAction],
        accent: UInt16 = MK2HIG.Chrome.accent,
        onSelect: @escaping @Sendable (_ index: Int) -> Void
    ) {
        self.trigger = trigger
        self.title = title
        self.actions = Array(actions.prefix(8))
        self.accent = accent
        self.onSelect = onSelect
    }

    public func build(
        baseLeft: MK2PixelFrame?,
        baseRight: MK2PixelFrame?,
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2.HeldButtonLayer {
        let left = screen(base: baseLeft, side: .left, actionOffset: 0, renderer: renderer)
        let right = screen(base: baseRight, side: .right, actionOffset: 4, renderer: renderer)

        var bindings = MK2InputBindings2()
        for button in Self.functionButtons {
            // The held command plane is complete: empty and disabled slots
            // swallow presses instead of leaking the base F-key action.
            bindings.onPress(button) {}
        }
        bindings.merge(left.bindings)
        bindings.merge(right.bindings)

        var lamps = Dictionary(
            uniqueKeysWithValues: Self.functionButtons.map { ($0, MK2LampState2.off) }
        )
        for (index, action) in actions.enumerated()
            where action.isEnabled && !action.label.isEmpty
        {
            let color = action.isDestructive
                ? KKRGB(red: 0xff, green: 0x48, blue: 0x38)
                : KKRGB(red: 0xff, green: 0xff, blue: 0xff)
            lamps[Self.functionButtons[index]] = .on(color, intensity: 0x01)
        }

        return MK2SurfaceScene2.HeldButtonLayer(
            trigger: trigger,
            left: left.screen.frame,
            right: right.screen.frame,
            lamps: lamps,
            bindings: bindings,
            buttonPolicy: .fallback,
            lampOverlayPolicy: .layerWins
        )
    }

    private func screen(
        base: MK2PixelFrame?,
        side: MK2FunctionKeyBarElement.Side,
        actionOffset: Int,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        var frame = base ?? MK2PixelFrame(fill: MK2HIG.Chrome.background)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        let context = MK2ScreenContext(renderer: renderer)
        let barHeight = MK2FunctionKeyBarElement.chromeBandHeight

        frame.dimHalf(MK2PixelRect(
            x: 0,
            y: Self.height,
            width: MK2PixelFrame.width,
            height: MK2PixelFrame.height - Self.height
        ))

        frame.fillRoundedVerticalGradient(
            MK2PixelRect(
                x: 0,
                y: barHeight,
                width: MK2PixelFrame.width,
                height: Self.height - barHeight - 4
            ),
            radius: 0,
            top: MK2HIG.Chrome.headerFill.scaled565(by: 1.25),
            bottom: MK2HIG.Chrome.headerFill.scaled565(by: 0.65)
        )

        let slots = (0..<4).map { localIndex -> MK2FunctionKeySlot in
            let index = actionOffset + localIndex
            guard actions.indices.contains(index) else { return MK2FunctionKeySlot() }
            let action = actions[index]
            return MK2FunctionKeySlot(
                action.label,
                isEnabled: action.isEnabled,
                isDestructive: action.isDestructive
            )
        }
        MK2FunctionKeyBarElement(
            slots: slots,
            side: side,
            style: .chromeBand,
            onPress: { localIndex in
                let index = actionOffset + localIndex
                guard actions.indices.contains(index), actions[index].isEnabled else { return }
                onSelect(index)
            }
        ).apply(to: &frame, context: context, result: &result)

        let heading = side == .left ? title.uppercased() : "HOLD \(trigger.protocolName.uppercased())"
        MK2ContentText(
            heading,
            x: 8,
            y: barHeight + 3,
            maxWidth: MK2PixelFrame.width - 16,
            role: .caption,
            color: accent,
            relativeToContent: false
        ).apply(to: &frame, context: context, result: &result)

        for localIndex in 0..<4 {
            let index = actionOffset + localIndex
            guard actions.indices.contains(index) else { continue }
            let action = actions[index]
            let detail = action.detail ?? action.value ?? ""
            guard !detail.isEmpty else { continue }
            MK2ContentText(
                detail,
                x: MK2ScreenLayout.encoderSlotXs[localIndex] + 2,
                y: barHeight + 22,
                maxWidth: MK2ScreenLayout.encoderSlotWidth - 4,
                role: .footnote,
                color: action.isEnabled
                    ? (action.isDestructive ? MK2HIG.Chrome.destructive : MK2HIG.Chrome.text)
                    : MK2HIG.Chrome.dim,
                alignment: .center,
                relativeToContent: false,
                maxLines: 2,
                lineSpacing: 1
            ).apply(to: &frame, context: context, result: &result)
        }

        // A four-row opaque shadow makes the band read as a popup without
        // allowing bright glyphs from the preserved scene to leak through.
        frame.fillRoundedVerticalGradient(
            MK2PixelRect(x: 0, y: Self.height - 4, width: MK2PixelFrame.width, height: 4),
            radius: 0,
            top: 0x0000,
            bottom: MK2HIG.Chrome.background.scaled565(by: 0.45)
        )

        result.screen = .fullScreen(frame)
        return result
    }

    private static let functionButtons: [KKMK2ButtonLED] = [
        .function1, .function2, .function3, .function4,
        .function5, .function6, .function7, .function8,
    ]
}
