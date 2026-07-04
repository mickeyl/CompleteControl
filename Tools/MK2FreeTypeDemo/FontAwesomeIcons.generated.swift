import Foundation

struct FontAwesomeIcon: Sendable, Equatable, Decodable {
    let name: String
    let label: String
    let codepoint: UInt32
    let styleMask: UInt16

    var glyph: String {
        guard let scalar = UnicodeScalar(codepoint) else { return "" }
        return String(scalar)
    }

    func supports(_ mask: UInt16) -> Bool {
        styleMask & mask != 0
    }
}

enum FontAwesomeIconCatalog {
    private struct Payload: Decodable {
        let source: String
        let icons: [FontAwesomeIcon]
    }

    static func load() throws -> (source: String, icons: [FontAwesomeIcon]) {
        let url = Bundle.module.url(forResource: "FontAwesomeIcons.pro", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.source, payload.icons)
    }
}
