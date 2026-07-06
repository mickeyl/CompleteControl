import Foundation
import KompleteKontrol

public enum MK2LampState2: Sendable, Equatable {
    case off
    case on(KKRGB, intensity: UInt8 = 0x03)
    case blink(KKRGB, period: Double, intensity: UInt8 = 0x03)
    case pulse(KKRGB, period: Double)

    public static var white: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff)) }
    public static var amber: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0x7f, blue: 0x00)) }
    public static var blue: MK2LampState2 { .on(KKRGB(red: 0x00, green: 0x7f, blue: 0xff)) }
    public static var green: MK2LampState2 { .on(KKRGB(red: 0x00, green: 0xff, blue: 0x66)) }
    public static var red: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0x18, blue: 0x18)) }
}

/// Declares which logical UI element receives USB-MIDI input for the current scene.
/// A client should use product-level ids such as `tracker.channel.1`, not hardware ids,
/// so the same focus concept can later route keyboard, simulator, and hardware events.
public struct MIDIFocus: Sendable {
    public let id: String
    private let handler: @Sendable (_ event: KKMIDIEvent) -> Void

    public init(_ id: String, handler: @escaping @Sendable (_ event: KKMIDIEvent) -> Void) {
        self.id = id
        self.handler = handler
    }

    public func receive(_ event: KKMIDIEvent) {
        handler(event)
    }
}

public struct MK2InputBindings2: Sendable {
    public enum ModifierRequirement: Sendable, Hashable {
        case any
        case unmodified
        case shift
    }

    public struct ModifiedButton: Sendable, Hashable {
        public var led: KKMK2ButtonLED
        public var requirement: ModifierRequirement

        public init(_ led: KKMK2ButtonLED, _ requirement: ModifierRequirement) {
            self.led = led
            self.requirement = requirement
        }
    }

    public var buttonDown: [KKMK2ButtonLED: @Sendable () -> Void] = [:]
    public var buttonUp: [KKMK2ButtonLED: @Sendable () -> Void] = [:]
    public var buttonHold: [KKMK2ButtonLED: @Sendable () -> Void] = [:]
    public var modifiedButtonDown: [ModifiedButton: @Sendable () -> Void] = [:]
    public var modifiedButtonUp: [ModifiedButton: @Sendable () -> Void] = [:]
    public var modifiedButtonHold: [ModifiedButton: @Sendable () -> Void] = [:]
    /// `timestampNanos` is the daemon-side reception time (KKTiming clock): velocity-
    /// sensitive consumers must measure from it, not from processing time — handler
    /// invocations bunch up behind rendering and would fake fast turns otherwise.
    public var encoder: [Int: @Sendable (_ delta: Int, _ value: Int, _ timestampNanos: UInt64) -> Void] = [:]
    public var encoderTouch: [Int: @Sendable (_ touched: Bool) -> Void] = [:]
    /// Two touch-downs on the same encoder within the double-touch window; the pro-audio
    /// "reset to default" gesture — what "default" means is the client's decision.
    public var encoderDoubleTouch: [Int: @Sendable () -> Void] = [:]
    public var jog: (@Sendable (_ direction: String) -> Void)?
    public var jogCenter: (@Sendable () -> Void)?
    public var jogScroll: (@Sendable (_ delta: Int, _ value: Int) -> Void)?
    public var jogTouch: (@Sendable (_ touched: Bool) -> Void)?
    public var strip: (@Sendable (_ position: Int?, _ time: Int) -> Void)?
    public var midi: (@Sendable (_ event: KKMIDIEvent) -> Void)?
    /// If present, MIDI is routed to this focused element instead of the legacy global
    /// MIDI handler. Use this for tracker channels, instrument editors, and similar
    /// command targets where MIDI input should follow UI focus.
    public var midiFocus: MIDIFocus?

    public init() {}

    public mutating func onPress(
        _ led: KKMK2ButtonLED,
        modifiers: ModifierRequirement = .any,
        _ handler: @escaping @Sendable () -> Void
    ) {
        if modifiers == .any {
            buttonDown[led] = handler
        } else {
            modifiedButtonDown[ModifiedButton(led, modifiers)] = handler
        }
    }

    public mutating func onRelease(
        _ led: KKMK2ButtonLED,
        modifiers: ModifierRequirement = .any,
        _ handler: @escaping @Sendable () -> Void
    ) {
        if modifiers == .any {
            buttonUp[led] = handler
        } else {
            modifiedButtonUp[ModifiedButton(led, modifiers)] = handler
        }
    }

    public mutating func onHold(
        _ led: KKMK2ButtonLED,
        modifiers: ModifierRequirement = .any,
        _ handler: @escaping @Sendable () -> Void
    ) {
        if modifiers == .any {
            buttonHold[led] = handler
        } else {
            modifiedButtonHold[ModifiedButton(led, modifiers)] = handler
        }
    }

    public mutating func merge(_ other: MK2InputBindings2) {
        buttonDown.merge(other.buttonDown) { _, next in next }
        buttonUp.merge(other.buttonUp) { _, next in next }
        buttonHold.merge(other.buttonHold) { _, next in next }
        modifiedButtonDown.merge(other.modifiedButtonDown) { _, next in next }
        modifiedButtonUp.merge(other.modifiedButtonUp) { _, next in next }
        modifiedButtonHold.merge(other.modifiedButtonHold) { _, next in next }
        encoder.merge(other.encoder) { _, next in next }
        encoderTouch.merge(other.encoderTouch) { _, next in next }
        encoderDoubleTouch.merge(other.encoderDoubleTouch) { _, next in next }
        if let jog = other.jog { self.jog = jog }
        if let jogCenter = other.jogCenter { self.jogCenter = jogCenter }
        if let jogScroll = other.jogScroll { self.jogScroll = jogScroll }
        if let jogTouch = other.jogTouch { self.jogTouch = jogTouch }
        if let strip = other.strip { self.strip = strip }
        if let midi = other.midi { self.midi = midi }
        if let midiFocus = other.midiFocus { self.midiFocus = midiFocus }
    }
}

public struct MK2SurfaceScene2: Sendable {
    public var displays: [MK2PixelFrame?]
    public var lamps: [KKMK2ButtonLED: MK2LampState2]
    public var keyColors: [Int: KKRGB]
    public var bindings: MK2InputBindings2

    public init(
        left: MK2PixelFrame? = nil,
        right: MK2PixelFrame? = nil,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) {
        displays = [left, right]
        self.lamps = lamps
        self.keyColors = keyColors
        self.bindings = bindings
    }
}
