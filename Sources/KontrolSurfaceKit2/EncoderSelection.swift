import Foundation

/// How an encoder-bound slot reacts to its encoder's touch sensor.
public enum MK2EncoderSelectionBehavior: Sendable, Equatable {
    /// Opt-out: only the app-declared `isFocused` state highlights the slot.
    case none
    /// Highlighted while the encoder is touched.
    case momentary
    /// The last-touched slot stays highlighted until another latched slot
    /// is touched.
    case latched
}

/// The pre-rendered touched appearance of one encoder-bound slot.
///
/// Scenes are presented as finished frames, so the runtime cannot re-run the
/// DSL build on a touch event. Like the shift layer, the highlight therefore
/// comes from prepared pixels: the build captures the slot's focused variant,
/// and the surface blits it while the touch is active — no app round trip.
/// The touched and focused appearances are intentionally identical, so an app
/// that confirms the touch by setting `isFocused` in its next projection
/// causes no visible change.
public struct MK2EncoderTouchOverlay: Sendable {
    /// Display index, assigned when the two screen build results are merged
    /// into a scene.
    public var screen: Int
    public var rect: MK2PixelRect
    public var pixels: [UInt16]
    public var behavior: MK2EncoderSelectionBehavior

    public init(screen: Int = 0, rect: MK2PixelRect, pixels: [UInt16], behavior: MK2EncoderSelectionBehavior) {
        self.screen = screen
        self.rect = rect
        self.pixels = pixels
        self.behavior = behavior
    }
}
