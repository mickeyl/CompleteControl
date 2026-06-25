import Foundation

/// How a parameter value is rendered to its display cell.
public enum ValueFormat: Sendable {
    case integer
    case decimal(Int)
    case percent
    case decibel
    case custom(@Sendable (Double) -> String)

    func string(_ value: Double) -> String {
        switch self {
            case .integer:
                "\(Int(value.rounded()))"
            case let .decimal(places):
                String(format: "%.\(max(0, places))f", value)
            case .percent:
                "\(Int(value.rounded()))%"
            case .decibel:
                String(format: "%+.1f", value)
            case let .custom(render):
                render(value)
        }
    }
}

/// A single controllable value, bound by a ``ParameterPage`` to one encoder and
/// one display. Continuous and numeric for now; enumerated/stepped variants can
/// follow. The `step`/`accelerate` fields drive the velocity-sensitive encoder
/// response (ported from the KontrolProbe demo).
public struct Parameter: Sendable {
    public var name: String
    public var value: Double
    public var range: ClosedRange<Double>
    public var step: Double
    public var accelerate: Bool
    public var format: ValueFormat
    public var onChange: (@Sendable (Double) -> Void)?

    public init(
        name: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double = 1,
        accelerate: Bool = true,
        format: ValueFormat = .integer,
        onChange: (@Sendable (Double) -> Void)? = nil
    ) {
        self.name = name
        self.range = range
        self.value = min(range.upperBound, max(range.lowerBound, value))
        self.step = step
        self.accelerate = accelerate
        self.format = format
        self.onChange = onChange
    }

    /// Value mapped to 0…1 for the progress bar.
    public var normalized: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (value - range.lowerBound) / span : 0
    }

    public var formattedValue: String { format.string(value) }

    mutating func apply(delta: Double) {
        value = min(range.upperBound, max(range.lowerBound, value + delta))
    }
}
