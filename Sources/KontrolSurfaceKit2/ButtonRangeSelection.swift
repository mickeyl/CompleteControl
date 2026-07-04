import Foundation
import KompleteKontrol

/// A bounded selection browsed by two hardware buttons.
///
/// The element keeps button availability and navigation behavior together: buttons at
/// the corresponding range edge are not lit and do not install a press handler.
public struct MK2ButtonRangeSelection: Sendable {
    public var value: Int
    public var bounds: ClosedRange<Int>
    public var previousButton: KKMK2ButtonLED
    public var nextButton: KKMK2ButtonLED
    public var availableLamp: MK2LampState2
    public var step: Int

    private let onSelect: @Sendable (_ value: Int) -> Void

    public init(
        value: Int,
        bounds: ClosedRange<Int>,
        previousButton: KKMK2ButtonLED,
        nextButton: KKMK2ButtonLED,
        availableLamp: MK2LampState2 = .white,
        step: Int = 1,
        onSelect: @escaping @Sendable (_ value: Int) -> Void
    ) {
        self.value = value
        self.bounds = bounds
        self.previousButton = previousButton
        self.nextButton = nextButton
        self.availableLamp = availableLamp
        self.step = max(1, step)
        self.onSelect = onSelect
    }

    public var canSelectPrevious: Bool {
        value > bounds.lowerBound
    }

    public var canSelectNext: Bool {
        value < bounds.upperBound
    }

    public func previousValue() -> Int {
        max(bounds.lowerBound, value - step)
    }

    public func nextValue() -> Int {
        min(bounds.upperBound, value + step)
    }

    public func apply(
        lamps: inout [KKMK2ButtonLED: MK2LampState2],
        bindings: inout MK2InputBindings2
    ) {
        lamps[previousButton] = canSelectPrevious ? availableLamp : .off
        lamps[nextButton] = canSelectNext ? availableLamp : .off

        if canSelectPrevious {
            bindings.onPress(previousButton) {
                onSelect(previousValue())
            }
        }
        if canSelectNext {
            bindings.onPress(nextButton) {
                onSelect(nextValue())
            }
        }
    }
}
