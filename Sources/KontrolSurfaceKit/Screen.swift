import Foundation

/// A reusable, declarative description of the whole surface. Conformers set the
/// content they want via the isolated `surface`; anything they leave untouched
/// is cleared by ``Surface/present(_:)`` before `render` runs.
///
/// This is the building block the upcoming result-builder DSL will sit on top of;
/// for now it gives a clean object form alongside the imperative setters.
public protocol Screen: Sendable {
    func render(on surface: isolated Surface)
}
