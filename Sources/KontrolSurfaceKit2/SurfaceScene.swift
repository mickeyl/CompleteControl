import Foundation
import KompleteKontrol

public enum MK2LampState2: Sendable, Equatable {
    case off
    case on(KKRGB)
    case blink(KKRGB, period: Double)
    case pulse(KKRGB, period: Double)

    public static var white: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff)) }
    public static var amber: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0x7f, blue: 0x00)) }
    public static var blue: MK2LampState2 { .on(KKRGB(red: 0x00, green: 0x7f, blue: 0xff)) }
    public static var green: MK2LampState2 { .on(KKRGB(red: 0x00, green: 0xff, blue: 0x66)) }
    public static var red: MK2LampState2 { .on(KKRGB(red: 0xff, green: 0x18, blue: 0x18)) }
}

public struct MK2InputBindings2: Sendable {
    public var buttonDown: [String: @Sendable () -> Void] = [:]
    public var buttonUp: [String: @Sendable () -> Void] = [:]
    public var encoder: [Int: @Sendable (_ delta: Int, _ value: Int) -> Void] = [:]
    public var encoderTouch: [Int: @Sendable (_ touched: Bool) -> Void] = [:]
    /// Two touch-downs on the same encoder within the double-touch window; the pro-audio
    /// "reset to default" gesture — what "default" means is the client's decision.
    public var encoderDoubleTouch: [Int: @Sendable () -> Void] = [:]
    public var jog: (@Sendable (_ direction: String) -> Void)?
    public var jogScroll: (@Sendable (_ delta: Int, _ value: Int) -> Void)?
    public var jogTouch: (@Sendable (_ touched: Bool) -> Void)?
    public var strip: (@Sendable (_ position: Int?, _ time: Int) -> Void)?
    public var midi: (@Sendable (_ event: KKMIDIEvent) -> Void)?

    public init() {}

    public mutating func onPress(_ led: KKMK2ButtonLED, _ handler: @escaping @Sendable () -> Void) {
        buttonDown[led.protocolName] = handler
    }

    public mutating func onRelease(_ led: KKMK2ButtonLED, _ handler: @escaping @Sendable () -> Void) {
        buttonUp[led.protocolName] = handler
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
