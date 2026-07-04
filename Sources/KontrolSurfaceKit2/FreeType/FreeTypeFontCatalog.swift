import Foundation

public enum FreeTypeFontWeight: Int, CaseIterable, Sendable, Comparable {
    case light = 300
    case regular = 400
    case text = 450
    case medium = 500
    case semiBold = 600
    case bold = 700

    public static func < (lhs: FreeTypeFontWeight, rhs: FreeTypeFontWeight) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
            case .light: "Light"
            case .regular: "Regular"
            case .text: "Text"
            case .medium: "Medium"
            case .semiBold: "SemiBold"
            case .bold: "Bold"
        }
    }
}

public struct FreeTypeFontSource: Sendable, Equatable {
    public var resourceName: String
    public var faceIndex: Int
    public var variationWeight: Int?

    public init(resourceName: String, faceIndex: Int = 0, variationWeight: Int? = nil) {
        self.resourceName = resourceName
        self.faceIndex = faceIndex
        self.variationWeight = variationWeight
    }
}

public struct FreeTypeFontFamily: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var faces: [FreeTypeFontWeight: FreeTypeFontSource]

    public init(id: String, label: String, faces: [FreeTypeFontWeight: FreeTypeFontSource]) {
        self.id = id
        self.label = label
        self.faces = faces
    }

    public func source(for weight: FreeTypeFontWeight) -> FreeTypeFontSource {
        if let exact = faces[weight] { return exact }
        return faces.min { abs($0.key.rawValue - weight.rawValue) < abs($1.key.rawValue - weight.rawValue) }!.value
    }
}

public struct FreeTypeFontCatalog: Sendable, Equatable {
    public static let textFamilyID = "plex-sans-condensed"
    public static let iconProLightFamilyID = "fontawesome-pro-light"

    public var families: [FreeTypeFontFamily]

    public init(families: [FreeTypeFontFamily]) {
        self.families = families
    }

    public func family(id: String) -> FreeTypeFontFamily? {
        families.first { $0.id == id }
    }

    public static let production = FreeTypeFontCatalog(families: [
        FreeTypeFontFamily(
            id: Self.textFamilyID,
            label: "IBM Plex Sans Condensed",
            faces: [
                .regular: FreeTypeFontSource(resourceName: "IBMPlexSansCondensed-Regular.otf"),
                .medium: FreeTypeFontSource(resourceName: "IBMPlexSansCondensed-Medium.otf"),
            ]
        ),
        FreeTypeFontFamily(
            id: Self.iconProLightFamilyID,
            label: "Font Awesome 7 Pro Light",
            faces: [
                .regular: FreeTypeFontSource(resourceName: "FontAwesome7Pro-Light-300.otf"),
            ]
        ),
    ])

    public static let exploratory = production
}
