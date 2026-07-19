import Foundation
import KontrolSurfaceKit2

struct BrowserDemoItem: Sendable {
    var title: String
    var detail: String
    var area: String
    var source: String
    var status: String
    var icon: String

    var selectionItem: MK2SelectionItem {
        MK2SelectionItem(title: title, detail: detail, badge: area, iconGlyph: icon)
    }
}

enum BrowserDemoMode: Int, CaseIterable, Sendable {
    case plainList
    case plainGrid
    case filteredList
    case filteredGrid
    case orderTable

    var next: BrowserDemoMode {
        Self(rawValue: (rawValue + 1) % Self.allCases.count)!
    }

    var title: String {
        switch self {
            case .plainList: "Browser List"
            case .plainGrid: "Browser Grid"
            case .filteredList: "Filtered Browser"
            case .filteredGrid: "Filtered Grid"
            case .orderTable: "Order Table"
        }
    }

    var shortTitle: String {
        switch self {
            case .plainList: "BROWSER LIST"
            case .plainGrid: "BROWSER GRID"
            case .filteredList: "FILTERED BROWSER"
            case .filteredGrid: "FILTERED GRID"
            case .orderTable: "ORDER TABLE"
        }
    }

    var isGrid: Bool {
        self == .plainGrid || self == .filteredGrid
    }

    var hasFilters: Bool {
        self == .filteredList || self == .filteredGrid
    }
}

/// One song-order row for the tabular list mode: the structure the future
/// SCENE/Arranger scene will render (position, pattern, title, row count).
struct OrderTableRow: Sendable {
    var position: String
    var pattern: String
    var title: String
    var rows: String

    var selectionItem: MK2SelectionItem {
        MK2SelectionItem(title: title, columns: [position, pattern, title, rows])
    }
}

enum BrowserLabFixtures {
    static let orderRows = [
        OrderTableRow(position: "00", pattern: "01", title: "Intro", rows: "32"),
        OrderTableRow(position: "01", pattern: "02", title: "Verse", rows: "64"),
        OrderTableRow(position: "02", pattern: "02", title: "Verse", rows: "64"),
        OrderTableRow(position: "03", pattern: "03", title: "Chorus", rows: "64"),
        OrderTableRow(position: "04", pattern: "04", title: "Break Filter", rows: "16"),
        OrderTableRow(position: "05", pattern: "02", title: "Verse", rows: "64"),
        OrderTableRow(position: "06", pattern: "03", title: "Chorus", rows: "64"),
        OrderTableRow(position: "07", pattern: "05", title: "Bridge Arp", rows: "48"),
        OrderTableRow(position: "08", pattern: "03", title: "Chorus", rows: "64"),
        OrderTableRow(position: "09", pattern: "06", title: "Outro Fade", rows: "32"),
    ]

    static let items = [
        BrowserDemoItem(title: "Piano Noir", detail: "Muted felt grand with intimate release", area: "Browse", source: "Factory", status: "Instrument 48 MB", icon: "\u{e340}"),
        BrowserDemoItem(title: "Tape Strings", detail: "Warm ensemble pad, slow filtered attack", area: "Browse", source: "User", status: "Instrument 82 MB", icon: "\u{e9c8}"),
        BrowserDemoItem(title: "Kick Resin", detail: "Round transient and short analogue tail", area: "Browse", source: "Factory", status: "Sample 24 bit", icon: "\u{e340}"),
        BrowserDemoItem(title: "Drum Folder", detail: "Imported one-shots from the project folder", area: "Browse", source: "Session", status: "28 samples", icon: "\u{e24a}"),
        BrowserDemoItem(title: "MIDI Routing", detail: "Live input, channel focus, record target", area: "Settings", source: "Device", status: "Channel 3 active", icon: "\u{e432}"),
        BrowserDemoItem(title: "Display", detail: "OLED brightness and browser preview density", area: "Settings", source: "Device", status: "Brightness 80 %", icon: "\u{e32e}"),
        BrowserDemoItem(title: "Library Root", detail: "Persistent folder scan for samples and instruments", area: "Settings", source: "User", status: "~/Music/Paulinche", icon: "\u{e256}"),
        BrowserDemoItem(title: "Autosave", detail: "Snapshot interval and dirty-pattern warning", area: "Settings", source: "Session", status: "Every 2 min", icon: "\u{e248}"),
        BrowserDemoItem(title: "Audio Engine", detail: "Output device, buffer size, audition voice", area: "System", source: "Device", status: "48 kHz / 128", icon: "\u{e44a}"),
        BrowserDemoItem(title: "Project Info", detail: "Pattern count, sample memory, last save", area: "System", source: "Session", status: "03 patterns", icon: "\u{e2ce}"),
    ]

    static let areas = ["All", "Browse", "Settings", "System"]
    static let sources = ["All", "Factory", "User", "Session", "Device"]
    // 154×54 puts three rows into the filtered grid (3×54 = 162 ≤ 166 content).
    static let gridCellSizes = [
        MK2SelectionCellSize(width: 154, height: 54),
        MK2SelectionCellSize(width: 232, height: 66),
    ]
}
