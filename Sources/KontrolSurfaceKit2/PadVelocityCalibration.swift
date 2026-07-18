import Foundation

/// Independent linear mappings for the MK3's native strike-velocity and
/// held-pressure values. Moving either floor/ceiling pair changes sensitivity
/// without conflating the two hardware signals.
public struct KontrolPadVelocityCalibration: Equatable, Sendable {
    public var strikeFloor: Int
    public var strikeCeiling: Int
    public var pressureFloor: Int
    public var pressureCeiling: Int

    public init(
        strikeFloor: Int = 128,
        strikeCeiling: Int = 3072,
        pressureFloor: Int = 64,
        pressureCeiling: Int = 3072
    ) {
        self.strikeFloor = max(0, min(4094, strikeFloor))
        self.strikeCeiling = max(self.strikeFloor + 1, min(4095, strikeCeiling))
        self.pressureFloor = max(0, min(4094, pressureFloor))
        self.pressureCeiling = max(self.pressureFloor + 1, min(4095, pressureCeiling))
    }

    public func velocityValue(for rawStrikeVelocity: Int) -> UInt8 {
        // MIDI Note On velocity zero is defined as Note Off. A real hardware
        // strike therefore always occupies the playable 1...127 range, even
        // when its raw value lies at or below the calibrated floor.
        max(1, Self.midiValue(
            rawStrikeVelocity,
            lowerBound: strikeFloor,
            upperBound: strikeCeiling
        ))
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

public struct KontrolPadStrikeAnalysis: Equatable, Sendable {
    public var padIndex: Int
    public var isHeld: Bool
    public var strikeCount: Int
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
                state.rawStrikeVelocity = nil
                state.currentPressure = event.pressure
            case .down:
                state.isHeld = true
                state.strikeCount += 1
                state.rawStrikeVelocity = event.strikeVelocity
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
        let analysis = KontrolPadStrikeAnalysis(
            padIndex: padIndex,
            isHeld: state.isHeld,
            strikeCount: state.strikeCount,
            rawStrikeVelocity: state.rawStrikeVelocity,
            currentPressure: state.currentPressure,
            velocityValue: state.rawStrikeVelocity.map(calibration.velocityValue(for:)),
            pressureValue: calibration.pressureValue(for: state.currentPressure)
        )
        analyses[padIndex] = analysis
        return analysis
    }
}
