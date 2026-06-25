import Foundation

/// Semantic transport state, decoupled from button names and LED brightness.
/// The app mutates this (directly, or from a host) and the surface reflects it
/// on the hardware transport LEDs: play steady, record blinking, loop steady.
public struct TransportState: Sendable, Equatable {
    public var isPlaying = false
    public var isRecording = false
    public var loopEnabled = false

    public init(isPlaying: Bool = false, isRecording: Bool = false, loopEnabled: Bool = false) {
        self.isPlaying = isPlaying
        self.isRecording = isRecording
        self.loopEnabled = loopEnabled
    }
}
