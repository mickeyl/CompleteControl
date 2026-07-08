import Foundation

struct PhosphorIcon: Sendable, Equatable, Decodable {
    let name: String
    let label: String
    let codepoint: UInt32

    var glyph: String {
        guard let scalar = UnicodeScalar(codepoint) else { return "" }
        return String(scalar)
    }
}

enum PhosphorIconCatalog {
    private struct Payload: Decodable {
        let source: String
        let icons: [PhosphorIcon]
    }

    static func load() throws -> (source: String, icons: [PhosphorIcon]) {
        let url = Bundle.module.url(forResource: "PhosphorIcons.regular", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.source, payload.icons)
    }
}
