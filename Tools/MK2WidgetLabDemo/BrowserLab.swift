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

    var next: BrowserDemoMode {
        Self(rawValue: (rawValue + 1) % Self.allCases.count)!
    }

    var title: String {
        switch self {
            case .plainList: "Browser List"
            case .plainGrid: "Browser Grid"
            case .filteredList: "Filtered Browser"
            case .filteredGrid: "Filtered Grid"
        }
    }

    var shortTitle: String {
        switch self {
            case .plainList: "BROWSER LIST"
            case .plainGrid: "BROWSER GRID"
            case .filteredList: "FILTERED BROWSER"
            case .filteredGrid: "FILTERED GRID"
        }
    }

    var isGrid: Bool {
        self == .plainGrid || self == .filteredGrid
    }

    var hasFilters: Bool {
        self == .filteredList || self == .filteredGrid
    }
}

enum BrowserLabFixtures {
    static let items = [
        BrowserDemoItem(title: "Piano Noir", detail: "Muted felt grand with intimate release", area: "Browse", source: "Factory", status: "Instrument 48 MB", icon: "\u{f001}"),
        BrowserDemoItem(title: "Tape Strings", detail: "Warm ensemble pad, slow filtered attack", area: "Browse", source: "User", status: "Instrument 82 MB", icon: "\u{f8ef}"),
        BrowserDemoItem(title: "Kick Resin", detail: "Round transient and short analogue tail", area: "Browse", source: "Factory", status: "Sample 24 bit", icon: "\u{f001}"),
        BrowserDemoItem(title: "Drum Folder", detail: "Imported one-shots from the project folder", area: "Browse", source: "Session", status: "28 samples", icon: "\u{f07b}"),
        BrowserDemoItem(title: "MIDI Routing", detail: "Live input, channel focus, record target", area: "Settings", source: "Device", status: "Channel 3 active", icon: "\u{f1de}"),
        BrowserDemoItem(title: "Display", detail: "OLED brightness and browser preview density", area: "Settings", source: "Device", status: "Brightness 80 %", icon: "\u{f26c}"),
        BrowserDemoItem(title: "Library Root", detail: "Persistent folder scan for samples and instruments", area: "Settings", source: "User", status: "~/Music/Paulinche", icon: "\u{f07c}"),
        BrowserDemoItem(title: "Autosave", detail: "Snapshot interval and dirty-pattern warning", area: "Settings", source: "Session", status: "Every 2 min", icon: "\u{f0c7}"),
        BrowserDemoItem(title: "Audio Engine", detail: "Output device, buffer size, audition voice", area: "System", source: "Device", status: "48 kHz / 128", icon: "\u{f2a2}"),
        BrowserDemoItem(title: "Project Info", detail: "Pattern count, sample memory, last save", area: "System", source: "Session", status: "03 patterns", icon: "\u{f05a}"),
    ]

    static let areas = ["All", "Browse", "Settings", "System"]
    static let sources = ["All", "Factory", "User", "Session", "Device"]
    static let gridCellSizes = [
        MK2SelectionCellSize(width: 154, height: 58),
        MK2SelectionCellSize(width: 232, height: 66),
    ]
}
