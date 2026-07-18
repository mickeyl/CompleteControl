import Foundation

/// Independent linear mappings for the MK3's contact/strike velocity and
/// held-pressure values. The strike floor also acts as the host-side trigger
/// threshold for contacts the hardware reports as touch-only.
public struct KontrolPadVelocityCalibration: Equatable, Sendable {
    public var strikeFloor: Int
    public var strikeCeiling: Int
    public var pressureFloor: Int
    public var pressureCeiling: Int

    public init(
        strikeFloor: Int = 8,
        strikeCeiling: Int = 768,
        pressureFloor: Int = 64,
        pressureCeiling: Int = 3072
    ) {
        self.strikeFloor = max(0, min(4094, strikeFloor))
        self.strikeCeiling = max(self.strikeFloor + 1, min(4095, strikeCeiling))
        self.pressureFloor = max(0, min(4094, pressureFloor))
        self.pressureCeiling = max(self.pressureFloor + 1, min(4095, pressureCeiling))
    }

    public func velocityValue(for rawStrikeVelocity: Int) -> UInt8 {
        // MIDI Note On velocity zero is defined as Note Off. An accepted hit
        // therefore always occupies the playable 1...127 range, even when its
        // raw value lies at or below the calibrated floor.
        max(1, Self.midiValue(
            rawStrikeVelocity,
            lowerBound: strikeFloor,
            upperBound: strikeCeiling
        ))
    }

    /// The MK3 distinguishes a native strike from a slower touch at roughly
    /// raw value 140. A lower host threshold recovers deliberate ghost notes
    /// without deriving attack velocity from the independent pressure stream.
    public func acceptsSoftHit(_ rawTouchVelocity: Int) -> Bool {
        rawTouchVelocity > 0 && rawTouchVelocity >= strikeFloor
    }

    public func pressureValue(for rawPressure: Int) -> UInt8 {
        Self.midiValue(
            rawPressure,
            lowerBound: pressureFloor,
            upperBound: pressureCeiling
        )
    }

    private static func midiValue(
        _ value: Int,
        lowerBound: Int,
        upperBound: Int
    ) -> UInt8 {
        guard value > lowerBound else { return 0 }
        guard value < upperBound else { return 127 }
        let numerator = (value - lowerBound) * 127
        let denominator = upperBound - lowerBound
        return UInt8(max(0, min(127, (numerator + denominator / 2) / denominator)))
    }
}

public enum KontrolPadHitSource: Equatable, Sendable {
    case softTouch
    case pressureFallback
    case nativeStrike
}

public struct KontrolPadStrikeAnalysis: Equatable, Sendable {
    public var padIndex: Int
    public var isHeld: Bool
    public var strikeCount: Int
    /// Contact speed for both touch-only contacts and native strikes.
    public var rawHitVelocity: Int?
    public var hitSource: KontrolPadHitSource?
    public var triggersMIDI: Bool
    /// Native strike value only, retained separately for protocol diagnostics.
    public var rawStrikeVelocity: Int?
    public var currentPressure: Int
    public var velocityValue: UInt8?
    public var pressureValue: UInt8
}

/// Bounded per-pad state for the calibration lab. It retains the most recent
/// strike and current pressure only, with no sample history or hot-path growth.
public struct KontrolPadStrikeAnalyzer: Sendable {
    private struct PadState: Sendable {
        var isHeld = false
        var strikeCount = 0
        var rawHitVelocity: Int?
        var hitSource: KontrolPadHitSource?
        var rawStrikeVelocity: Int?
        var currentPressure = 0
    }

    public var calibration: KontrolPadVelocityCalibration {
        didSet { refreshAnalyses() }
    }
    public private(set) var analyses: [KontrolPadStrikeAnalysis?]
    private var states: [PadState]

    public init(
        padCount: Int = 16,
        calibration: KontrolPadVelocityCalibration = KontrolPadVelocityCalibration()
    ) {
        let count = max(0, padCount)
        self.calibration = calibration
        analyses = [KontrolPadStrikeAnalysis?](repeating: nil, count: count)
        states = [PadState](repeating: PadState(), count: count)
    }

    public mutating func reset() {
        analyses = [KontrolPadStrikeAnalysis?](repeating: nil, count: analyses.count)
        states = [PadState](repeating: PadState(), count: states.count)
    }

    @discardableResult
    public mutating func receive(_ event: KontrolSurfacePadEvent) -> KontrolPadStrikeAnalysis? {
        guard states.indices.contains(event.index) else { return nil }
        var state = states[event.index]
        switch event.phase {
            case .touch:
                state.isHeld = true
                state.rawHitVelocity = event.pressure
                state.hitSource = .softTouch
                state.rawStrikeVelocity = nil
                state.currentPressure = event.pressure
            case .down:
                state.isHeld = true
                state.strikeCount += 1
                if let strikeVelocity = event.strikeVelocity {
                    state.rawHitVelocity = strikeVelocity
                    state.hitSource = .nativeStrike
                    state.rawStrikeVelocity = strikeVelocity
                } else if event.pressure > 0 {
                    state.rawHitVelocity = event.pressure
                    state.hitSource = .pressureFallback
                    state.rawStrikeVelocity = nil
                }
                state.currentPressure = event.pressure
            case .pressure:
                state.isHeld = true
                state.currentPressure = event.pressure
            case .up:
                state.isHeld = false
                state.currentPressure = 0
        }
        states[event.index] = state
        return publish(state, padIndex: event.index)
    }

    private mutating func refreshAnalyses() {
        for index in states.indices where analyses[index] != nil {
            _ = publish(states[index], padIndex: index)
        }
    }

    private mutating func publish(
        _ state: PadState,
        padIndex: Int
    ) -> KontrolPadStrikeAnalysis {
        let triggersMIDI: Bool
        switch state.hitSource {
            case .softTouch, .pressureFallback:
                triggersMIDI = state.rawHitVelocity.map(calibration.acceptsSoftHit) ?? false
            case .nativeStrike:
                triggersMIDI = state.rawHitVelocity != nil
            case nil:
                triggersMIDI = false
        }
        let analysis = KontrolPadStrikeAnalysis(
            padIndex: padIndex,
            isHeld: state.isHeld,
            strikeCount: state.strikeCount,
            rawHitVelocity: state.rawHitVelocity,
            hitSource: state.hitSource,
            triggersMIDI: triggersMIDI,
            rawStrikeVelocity: state.rawStrikeVelocity,
            currentPressure: state.currentPressure,
            velocityValue: triggersMIDI
                ? state.rawHitVelocity.map(calibration.velocityValue(for:))
                : nil,
            pressureValue: calibration.pressureValue(for: state.currentPressure)
        )
        analyses[padIndex] = analysis
        return analysis
    }
}
