import Foundation
import KompleteKontrol

public struct SimulatorRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct MaschineMK3ButtonDescriptor: Sendable, Equatable {
    public var button: MaschineMK3Button
    public var label: String
    public var secondaryLabel: String?
    public var rect: SimulatorRect

    public init(_ button: MaschineMK3Button, _ label: String, secondary: String? = nil, rect: SimulatorRect) {
        self.button = button
        self.label = label
        secondaryLabel = secondary
        self.rect = rect
    }
}

public struct MaschineMK3PanelGeometry: Sendable, Equatable {
    public static let physicalWidthMM = 320.0
    public static let physicalHeightMM = 301.0
    public static let pointsPerMillimetre = 3.0
    public static let panelWidth = physicalWidthMM * pointsPerMillimetre
    public static let panelHeight = physicalHeightMM * pointsPerMillimetre
    public static let displayBezelOutset = 9.0

    public var displays: [SimulatorRect]
    public var displayEncoders: [SimulatorRect]
    public var mainEncoder: SimulatorRect
    public var touchStrip: SimulatorRect
    public var pads: [SimulatorRect]
    public var padShiftLabels: [String]
    public var buttons: [MaschineMK3ButtonDescriptor]

    public static let calibrated = MaschineMK3PanelGeometry(
        displays: [
            SimulatorRect(x: 274, y: 90, width: 288, height: 163),
            SimulatorRect(x: 624, y: 90, width: 288, height: 163),
        ],
        displayEncoders: (0..<8).map { index in
            SimulatorRect(x: 270 + Double(index) * 83, y: 273, width: 42, height: 42)
        },
        mainEncoder: SimulatorRect(x: 42, y: 330, width: 112, height: 112),
        touchStrip: SimulatorRect(x: 37, y: 541, width: 315, height: 48),
        pads: (0..<16).map { index in
            let row = 3 - index / 4
            let column = index % 4
            return SimulatorRect(
                x: 506 + Double(column) * 107,
                y: 424 + Double(row) * 113,
                width: 96,
                height: 102
            )
        },
        padShiftLabels: [
            "Undo", "Redo", "Step Undo", "Step Redo",
            "Quantize", "Quantize 50%", "Nudge <", "Nudge >",
            "Clear", "Clear Auto", "Copy", "Paste",
            "Semitone -", "Semitone +", "Octave -", "Octave +",
        ],
        buttons: Self.makeButtons()
    )

    private static func makeButtons() -> [MaschineMK3ButtonDescriptor] {
        var result: [MaschineMK3ButtonDescriptor] = []
        func add(_ button: MaschineMK3Button, _ label: String, _ x: Double, _ y: Double,
                 _ width: Double = 76, _ height: Double = 31, secondary: String? = nil) {
            result.append(MaschineMK3ButtonDescriptor(
                button, label, secondary: secondary,
                rect: SimulatorRect(x: x, y: y, width: width, height: height)
            ))
        }

        let navigation: [(MaschineMK3Button, String, String?)] = [
            (.channel, "CHANNEL", "MIDI"), (.plugin, "PLUG-IN", "Instance"),
            (.arranger, "ARRANGER", nil), (.mixer, "MIXER", nil),
            (.browser, "BROWSER", "Plug-in"), (.sampling, "SAMPLING", nil),
            (.arrowLeft, "◀", nil), (.arrowRight, "▶", nil),
            (.file, "FILE", "Save"), (.settings, "SETTINGS", nil),
            (.auto, "AUTO", nil), (.macro, "MACRO", "Set"),
        ]
        for (index, item) in navigation.enumerated() {
            add(item.0, item.1, 34 + Double(index % 2) * 87, 31 + Double(index / 2) * 48, 78, 34, secondary: item.2)
        }

        for index in 0..<8 {
            add(
                MaschineMK3Button(rawValue: "display-button-\(index + 1)")!,
                "F\(index + 1)", 270 + Double(index) * 83, 28, 70, 25
            )
        }

        add(.volume, "VOLUME", 202, 350, 70, 30, secondary: "Velocity")
        add(.noteRepeat, "NOTE REPEAT", 282, 350, 76, 68, secondary: "Arp")
        add(.swing, "SWING", 202, 388, 70, 30, secondary: "Position")
        add(.lock, "LOCK", 282, 426, 76, 30, secondary: "Ext Lock")
        add(.tempo, "TEMPO", 202, 426, 70, 30, secondary: "Tune")

        let modes: [(MaschineMK3Button, String)] = [
            (.fixedVelocity, "FIXED VEL"), (.padMode, "PAD MODE"), (.keyboard, "KEYBOARD"),
            (.chords, "CHORDS"), (.step, "STEP"),
        ]
        let modePositions = [407.0, 510.0, 613.0, 716.0, 831.0]
        for (index, item) in modes.enumerated() {
            add(item.0, item.1, modePositions[index], 350, 92, 31)
        }

        let editColumn: [(MaschineMK3Button, String, String?)] = [
            (.scene, "SCENE", "Section"), (.pattern, "PATTERN", nil),
            (.events, "EVENTS", nil), (.variation, "VARIATION", "Navigate"),
            (.duplicate, "DUPLICATE", "Double"), (.select, "SELECT", nil),
            (.solo, "SOLO", nil), (.mute, "MUTE", "Choke"),
        ]
        let editColumnTop = 424.0
        let editButtonHeight = 45.0
        let padColumnBottom = 865.0
        let editColumnStep = (padColumnBottom - editColumnTop - editButtonHeight)
            / Double(editColumn.count - 1)
        for (index, item) in editColumn.enumerated() {
            add(
                item.0, item.1, 407, editColumnTop + Double(index) * editColumnStep,
                76, editButtonHeight, secondary: item.2
            )
        }

        let performance: [(MaschineMK3Button, String)] = [
            (.pitch, "PITCH"), (.mod, "MOD"), (.perform, "PERFORM"), (.notes, "NOTES"),
        ]
        for (index, item) in performance.enumerated() {
            add(item.0, item.1, 37 + Double(index) * 81, 493, 72, 31)
        }

        for (index, group) in [MaschineMK3Button.groupA, .groupB, .groupC, .groupD,
                               .groupE, .groupF, .groupG, .groupH].enumerated() {
            add(group, String(UnicodeScalar(65 + index)!), 37 + Double(index % 4) * 82,
                617 + Double(index / 4) * 57, 69, 43)
        }

        let transport: [(MaschineMK3Button, String, String?)] = [
            (.restart, "RESTART", "Loop"), (.erase, "ERASE", "Replace"),
            (.tap, "TAP", "Metro"), (.follow, "FOLLOW", "Grid"),
            (.play, "▶ PLAY", nil), (.record, "● REC", "Count-In"),
            (.stop, "■ STOP", nil), (.shift, "SHIFT", nil),
        ]
        for (index, item) in transport.enumerated() {
            add(item.0, item.1, 37 + Double(index % 4) * 81, 781 + Double(index / 4) * 48,
                72, 36, secondary: item.2)
        }

        add(.mainEncoderPress, "PUSH", 76, 364, 44, 44)
        add(.mainEncoderUp, "▲", 78, 331, 40, 24)
        add(.mainEncoderRight, "▶", 121, 365, 24, 40)
        add(.mainEncoderDown, "▼", 78, 418, 40, 24)
        add(.mainEncoderLeft, "◀", 48, 365, 24, 40)
        return result
    }
}
