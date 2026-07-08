import Foundation
import KontrolSurfaceKit2

struct SelectionDemoItem: Sendable {
    var title: String
    var detail: String
    var category: String
    var tone: String
    var bank: String
    var icon: String

    var selectionItem: MK2SelectionItem {
        MK2SelectionItem(title: title, detail: detail, badge: category, iconGlyph: icon)
    }
}

enum SelectionDemoMode: Int, CaseIterable, Sendable {
    case plainList
    case plainGrid
    case filteredList
    case filteredGrid

    var next: SelectionDemoMode {
        Self(rawValue: (rawValue + 1) % Self.allCases.count)!
    }

    var title: String {
        switch self {
            case .plainList: "Plain List"
            case .plainGrid: "Plain Grid"
            case .filteredList: "Filtered List"
            case .filteredGrid: "Filtered Grid"
        }
    }

    var shortTitle: String {
        switch self {
            case .plainList: "PLAIN LIST"
            case .plainGrid: "PLAIN GRID"
            case .filteredList: "FILTERED LIST"
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

enum SelectionLabFixtures {
    static let items = [
        SelectionDemoItem(title: "Kick Resin", detail: "Round transient, short tail", category: "Drums", tone: "Warm", bank: "Factory", icon: "\u{e340}"),
        SelectionDemoItem(title: "Snare Alloy", detail: "Bright shell with tight snap", category: "Drums", tone: "Bright", bank: "Factory", icon: "\u{e340}"),
        SelectionDemoItem(title: "Hat Needle", detail: "Closed metallic tick", category: "Drums", tone: "Bright", bank: "User", icon: "\u{e340}"),
        SelectionDemoItem(title: "Bass Rubber", detail: "Elastic mono bass", category: "Bass", tone: "Warm", bank: "Factory", icon: "\u{ea08}"),
        SelectionDemoItem(title: "Sub Pure", detail: "Clean sine foundation", category: "Bass", tone: "Dark", bank: "User", icon: "\u{ea08}"),
        SelectionDemoItem(title: "Lead Glass", detail: "Thin digital lead", category: "Synth", tone: "Bright", bank: "Factory", icon: "\u{e802}"),
        SelectionDemoItem(title: "Arp Carbon", detail: "Tight sequence layer", category: "Synth", tone: "Dark", bank: "User", icon: "\u{e802}"),
        SelectionDemoItem(title: "Pad Violet", detail: "Slow ensemble pad", category: "Pads", tone: "Warm", bank: "Factory", icon: "\u{e9c8}"),
        SelectionDemoItem(title: "Tape Strings", detail: "Soft sampled ensemble", category: "Pads", tone: "Warm", bank: "User", icon: "\u{e9c8}"),
        SelectionDemoItem(title: "Organ Mini", detail: "Small drawbar comp", category: "Keys", tone: "Bright", bank: "Factory", icon: "\u{e340}"),
        SelectionDemoItem(title: "Piano Noir", detail: "Muted felt grand", category: "Keys", tone: "Dark", bank: "User", icon: "\u{e340}"),
        SelectionDemoItem(title: "Vox Byte", detail: "Formant stab", category: "Voice", tone: "Bright", bank: "User", icon: "\u{e326}"),
    ]

    static let types = ["All", "Drums", "Bass", "Synth", "Pads", "Keys", "Voice"]
    static let tones = ["All", "Warm", "Bright", "Dark"]
    static let banks = ["All", "Factory", "User"]
    static let cellSizes = [
        MK2SelectionCellSize(width: 232, height: 66),
        MK2SelectionCellSize(width: 154, height: 58),
        MK2SelectionCellSize(width: 116, height: 48),
    ]
}
