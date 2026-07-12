import Foundation

/// Demo taxonomy of the lab browser (rework plan, decisions 2026-07-12):
/// Calibration tunes hardware physics, Look & Feel judges rendering,
/// Kit Catalogue exercises the reusable elements, Diagnostics pokes the
/// device directly.
enum DemoCategory: Int, CaseIterable, Sendable {
    case calibration
    case lookAndFeel
    case catalogue
    case diagnostics

    var title: String {
        switch self {
            case .calibration: "Calibration"
            case .lookAndFeel: "Look & Feel"
            case .catalogue: "Kit Catalogue"
            case .diagnostics: "Diagnostics"
        }
    }

    var badge: String {
        switch self {
            case .calibration: "CAL"
            case .lookAndFeel: "LOOK"
            case .catalogue: "KIT"
            case .diagnostics: "DIAG"
        }
    }
}

/// Identity card of one demo: what the browser lists, what its detail pane
/// explains, and which snapshot variants the harness captures. The `id` is
/// also the REPL name (`open <id>`) and the snapshot file stem.
struct DemoDescriptor: Sendable {
    let id: String
    let title: String
    let category: DemoCategory
    /// One-line list row detail.
    let summary: String
    /// Detail-pane lines: what the demo shows and which controls it takes.
    let detail: String
    let snapshotVariants: [String]

    init(
        id: String,
        title: String,
        category: DemoCategory,
        summary: String,
        detail: String,
        snapshotVariants: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.summary = summary
        self.detail = detail
        self.snapshotVariants = snapshotVariants
    }
}
