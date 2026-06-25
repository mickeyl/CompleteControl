import Foundation

/// Target state of a single button LED. The S25 button LEDs are single-channel
/// (brightness 0…0x7f), so `blink` and `pulse` are synthesized on the surface
/// clock rather than being hardware features.
public enum LampState: Sendable, Equatable {
    case off
    case on(UInt8)
    case blink(period: Double, level: UInt8)
    case pulse(period: Double, level: UInt8)

    public static var on: LampState { .on(0x7f) }
    public static var blink: LampState { .blink(period: 0.5, level: 0x7f) }
    public static var pulse: LampState { .pulse(period: 1.2, level: 0x7f) }
}
