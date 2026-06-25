import Foundation

/// A declarative description of the whole surface. `body` composes `Cell`,
/// `Lamp`, `Status`, and `PageIndicator` elements with the result builder; the
/// surface lowers it to a ``SurfaceModel`` and reconciles the hardware to match.
///
/// Screens are pure values — they never touch the device — so the declarative
/// path stands on its own, independent of the imperative setters.
public protocol Screen {
    @ScreenBuilder var body: [any ScreenElement] { get }
}

public extension Screen {
    /// Lowers the screen to a model snapshot.
    func lowered() -> SurfaceModel {
        var model = SurfaceModel()
        for element in body { element.render(into: &model) }
        return model
    }
}
