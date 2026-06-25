import Foundation

/// An ordered set of ``ParameterPage``s with a selected index. Page through it
/// with `Surface.bankNext` / `bankPrevious`; the surface renders the selected
/// page and shows its title and the bank position on the status display.
public final class ParameterBank: @unchecked Sendable {
    public private(set) var pages: [ParameterPage]
    public private(set) var index: Int

    public init(_ pages: [ParameterPage], index: Int = 0) {
        self.pages = pages
        self.index = pages.isEmpty ? 0 : min(max(0, index), pages.count - 1)
    }

    public var count: Int { pages.count }
    public var current: ParameterPage? { pages.indices.contains(index) ? pages[index] : nil }

    func selectNext() {
        guard !pages.isEmpty else { return }
        index = (index + 1) % pages.count
    }

    func selectPrevious() {
        guard !pages.isEmpty else { return }
        index = (index + pages.count - 1) % pages.count
    }
}
