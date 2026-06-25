import Foundation
import KompleteKontrol

/// Normalized, semantic surface input. A thin, app-facing translation of
/// `KKInputEvent` that hides report-byte details. Gesture recognition
/// (tap/hold/double-tap) and per-encoder velocity will layer on top later.
public enum SurfaceInput: Sendable, Equatable {
    case encoder(index: Int, delta: Int, value: Int)
    case encoderTouch(index: Int, touching: Bool)
    case mainEncoder(delta: Int)
    case button(name: String, pressed: Bool)
    case strip(name: String, value: Int)

    static func from(_ event: KKInputEvent) -> SurfaceInput? {
        switch event {
            case let .button(name, pressed):
                .button(name: name, pressed: pressed)
            case let .touchEncoder(index, touched):
                .encoderTouch(index: index, touching: touched)
            case let .rotaryEncoder(index, delta, value):
                .encoder(index: index, delta: delta, value: value)
            case let .mainEncoder(delta):
                .mainEncoder(delta: delta)
            case .mainEncoderState:
                nil
            case let .touchStrip(name, value):
                .strip(name: name, value: value)
        }
    }
}
