import Foundation
import KompleteKontrol

/// Holds the intended RGB colour of every light-guide key and reports the full
/// set when anything changed, so the reconcile loop sends one guide report only
/// when a key actually changes.
struct KeyReconciler {
    private var intended: [KKRGB]
    private var lastSent: [KKRGB]?

    init() {
        intended = Array(repeating: .off, count: KompleteKontrolS25MK1Protocol.keyCount)
    }

    mutating func set(_ index: Int, _ color: KKRGB) {
        guard intended.indices.contains(index) else { return }
        intended[index] = color
    }

    /// Replaces the whole guide from a sparse colour map (unset keys go off).
    mutating func setAll(_ colors: [Int: KKRGB]) {
        intended = Array(repeating: .off, count: intended.count)
        for (index, color) in colors where intended.indices.contains(index) {
            intended[index] = color
        }
    }

    mutating func clearAll() {
        intended = Array(repeating: .off, count: intended.count)
    }

    mutating func render() -> [KKRGB]? {
        guard lastSent != intended else { return nil }
        lastSent = intended
        return intended
    }
}
