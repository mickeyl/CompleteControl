import Foundation
import KompleteKontrol

public enum MK2LampState2: Sendable, Equatable {
    case off
    case on(KKRGB, intensity: UInt8 = 0x03)
    case blink(KKRGB, period: Double, intensity: UInt8 = 0x03)
    case pulse(KKRGB, period: Double)
    /// A literal device LED byte for protocol diagnostics and calibration.
    ///
    /// This deliberately bypasses semantic colour/intensity lowering. Product
    /// scenes should use `.on`, `.blink`, or `.pulse` instead.
    case rawOutput(UInt8)

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

/// Hardware-neutral pad input before it is translated into MIDI.
///
/// `index` follows panel order (`0` is physical Pad 1). MK3 distinguishes a
/// below-threshold `.touch` from a triggered `.down`; only `.down` carries the
/// native 12-bit strike value. The following pressure stream is independent.
public struct KontrolSurfacePadEvent: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case touch
        case down
        case pressure
        case up
    }

    public var index: Int
    public var phase: Phase
    public var pressure: Int
    public var maximumPressure: Int
    public var strikeVelocity: Int?
    public var maximumStrikeVelocity: Int
    public var timestampNanos: UInt64

    public init(
        index: Int,
        phase: Phase,
        pressure: Int,
        maximumPressure: Int,
        strikeVelocity: Int? = nil,
        maximumStrikeVelocity: Int = 1,
        timestampNanos: UInt64
    ) {
        self.index = index
        self.phase = phase
        self.maximumPressure = max(1, maximumPressure)
        self.pressure = max(0, min(self.maximumPressure, pressure))
        let clampedMaximumStrikeVelocity = max(1, maximumStrikeVelocity)
        self.maximumStrikeVelocity = clampedMaximumStrikeVelocity
        self.strikeVelocity = strikeVelocity.map {
            max(0, min(clampedMaximumStrikeVelocity, $0))
        }
        self.timestampNanos = timestampNanos
    }

    public var number: Int { index + 1 }
    public var normalizedPressure: Double {
        Double(pressure) / Double(maximumPressure)
    }
    public var normalizedStrikeVelocity: Double? {
        strikeVelocity.map { Double($0) / Double(maximumStrikeVelocity) }
    }
}

/// A held hardware key that modifies the surface. Shift is the only first-class
/// modifier; the set shape keeps the door open for other held-button layers
/// without another API change.
public enum MK2Modifier: Sendable, Hashable {
    case shift
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
    /// Native pad input with daemon reception timestamps. Kit2 also translates
    /// triggered MK3 pads into the shared MIDI binding; this raw seam remains
    /// available for calibration and hardware diagnostics.
    public var pad: (@Sendable (_ event: KontrolSurfacePadEvent) -> Void)?
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
        if let pad = other.pad { self.pad = pad }
        if let midi = other.midi { self.midi = midi }
        if let midiFocus = other.midiFocus { self.midiFocus = midiFocus }
    }
}

public struct MK2LightGuideColor: Equatable, Sendable {
    public var color: KKRGB
    public var intensity: UInt8

    public init(color: KKRGB, intensity: UInt8 = 3) {
        self.color = color
        self.intensity = min(3, intensity)
    }

    public var paletteCode: UInt8 {
        KompleteKontrolSSeriesMK2.paletteCode(for: color, intensity: intensity)
    }
}

/// A physical LED target for protocol diagnostics.
///
/// This intentionally sits outside the semantic lamp vocabulary. Product
/// scenes should use `lamps`; calibration tools may use these targets to verify
/// native bytes for controls that have no honest MK2 equivalent yet.
public enum KontrolSurfaceDiagnosticLED: Hashable, Sendable {
    case maschineMK3Button(MaschineMK3ButtonLED)
    case maschineMK3Pad(MaschineMK3PadLED)
}

public struct MK2SurfaceScene2: Sendable {
    /// Alternate surface state active while the hardware SHIFT button is held.
    ///
    /// The layer is an overlay, not a second scene: per-screen frames replace the
    /// base frames (`nil` keeps the base visible), and key colors merge over the
    /// base. `buttonPolicy` decides whether button lamps/bindings fall back to the
    /// base or form an exclusive, complete layer.
    public struct ShiftLayer: Sendable {
        public enum ButtonPolicy: Sendable, Equatable {
            /// Layer entries override the base; unbound buttons and unmentioned
            /// lamps continue to use the base scene.
            case fallback
            /// Only layer button bindings and lamps are active while held.
            /// Clients must repeat every intentional passthrough in the layer.
            case exclusive
        }

        public var displays: [MK2PixelFrame?]
        public var lamps: [KKMK2ButtonLED: MK2LampState2]
        public var keyColors: [Int: KKRGB]
        public var keyIntensities: [Int: UInt8]
        public var bindings: MK2InputBindings2
        public var buttonPolicy: ButtonPolicy

        public init(
            left: MK2PixelFrame? = nil,
            right: MK2PixelFrame? = nil,
            lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
            keyColors: [Int: KKRGB] = [:],
            keyIntensities: [Int: UInt8] = [:],
            bindings: MK2InputBindings2 = MK2InputBindings2(),
            buttonPolicy: ButtonPolicy = .fallback
        ) {
            displays = [left, right]
            self.lamps = lamps
            self.keyColors = keyColors
            self.keyIntensities = keyIntensities.mapValues { min(3, $0) }
            self.bindings = bindings
            self.buttonPolicy = buttonPolicy
        }
    }

    public var displays: [MK2PixelFrame?]
    public var lamps: [KKMK2ButtonLED: MK2LampState2]
    public var keyColors: [Int: KKRGB]
    public var keyIntensities: [Int: UInt8]
    /// Performance-pad colors in physical panel order (`0` is Pad 1).
    /// Controllers without illuminated performance pads ignore this state.
    public var padColors: [Int: KKRGB]
    public var padIntensities: [Int: UInt8]
    public var bindings: MK2InputBindings2
    public var shift: ShiftLayer?
    /// Literal native LED bytes applied after semantic lamp lowering.
    /// Intended only for hardware calibration and protocol diagnostics.
    public var diagnosticLEDBytes: [KontrolSurfaceDiagnosticLED: UInt8]
    /// Prepared touch highlights of encoder-bound slots, keyed by encoder;
    /// the runtime blits them locally while the touch selection is active.
    /// Suppressed while the shift layer is held — its slots show other values.
    public var encoderTouchOverlays: [Int: MK2EncoderTouchOverlay]

    public init(
        left: MK2PixelFrame? = nil,
        right: MK2PixelFrame? = nil,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        keyIntensities: [Int: UInt8] = [:],
        padColors: [Int: KKRGB] = [:],
        padIntensities: [Int: UInt8] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2(),
        shift: ShiftLayer? = nil,
        diagnosticLEDBytes: [KontrolSurfaceDiagnosticLED: UInt8] = [:],
        encoderTouchOverlays: [Int: MK2EncoderTouchOverlay] = [:]
    ) {
        displays = [left, right]
        self.lamps = lamps
        self.keyColors = keyColors
        self.keyIntensities = keyIntensities.mapValues { min(3, $0) }
        self.padColors = padColors
        self.padIntensities = padIntensities.mapValues { min(3, $0) }
        self.bindings = bindings
        self.shift = shift
        self.diagnosticLEDBytes = diagnosticLEDBytes
        self.encoderTouchOverlays = encoderTouchOverlays
    }
}
