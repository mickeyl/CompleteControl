import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

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

    /// Compact value for the category filter cell.
    var filterValue: String {
        switch self {
            case .calibration: "Calibration"
            case .lookAndFeel: "Look & Feel"
            case .catalogue: "Kit"
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

/// What the shell hands a demo: the shared text renderer and a way to run a
/// state mutation on the shell's executor followed by a re-present. Demos
/// never talk to the surface directly.
struct LabContext: Sendable {
    let renderer: FreeTypeTextRenderer?
    /// Run a mutation on the shell's executor, then re-present.
    let update: @Sendable (_ mutation: @escaping @Sendable () -> Void) -> Void
    /// Run a mutation on the shell's executor without re-presenting — for
    /// demos that coalesce expensive renders themselves.
    let mutate: @Sendable (_ mutation: @escaping @Sendable () -> Void) -> Void
    /// Present benchmark framebuffers through the real Kit2 → daemon → device
    /// path and wait until their physical display transfers have completed.
    let beginDisplayMeasurements: @Sendable () async throws -> String
    let measureDisplays: @Sendable (
        _ displays: [MK2PixelFrame?]
    ) async throws -> MK2DisplayPresentationMeasurement
    let endDisplayMeasurements: @Sendable () async throws -> MK2DisplayTransportSnapshot
}

/// One self-contained demo: it builds its complete scene (screens, lamps,
/// bindings, shift layer) and owns every control while open — the shell
/// injects only the reserved SCENE exit and the REPL LED overrides on top.
/// Instances are held and called exclusively by the shell actor; binding
/// closures route mutations back through `LabContext.update`.
protocol LabDemo: AnyObject, Sendable {
    var descriptor: DemoDescriptor { get }
    func buildScene(_ context: LabContext) -> MK2SurfaceScene2
    /// The harness sets up the named variant before capturing; "" is the default.
    func prepareSnapshot(variant: String)
    /// Called when the shell leaves the demo — stop timers and playback here.
    func demoWillClose()
    /// Demo-local REPL commands, listed in help while the demo is open.
    func replCommands() -> [ReplCommand]
    /// Handle a REPL line; return false to fall through to the shell's error.
    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool
    /// Optional machine-readable state for long-running test activities.
    func testState() -> String?
}

extension LabDemo {
    func prepareSnapshot(variant: String) {}
    func demoWillClose() {}
    func replCommands() -> [ReplCommand] { [] }
    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool { false }
    func testState() -> String? { nil }
}
