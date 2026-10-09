import Foundation

nonisolated struct JSONAPIDocument<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let data: [JSONAPIResource<Attributes>]
    let included: [JSONAPIIncludedResource]?
    let links: Links?

    struct Links: Decodable, Sendable {
        let next: URL?
    }

    func includedResource(for identifier: JSONAPIResourceIdentifier?) -> JSONAPIIncludedResource? {
        guard let identifier else { return nil }
        return included?.first { $0.type == identifier.type && $0.id == identifier.id }
    }
}

nonisolated struct JSONAPIResource<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let id: String
    let attributes: Attributes?
    let relationships: [String: JSONAPIRelationship]?

    func relationship(_ name: String) -> JSONAPIResourceIdentifier? {
        relationships?[name]?.data
    }
}

nonisolated struct JSONAPIRelationship: Decodable, Sendable {
    let data: JSONAPIResourceIdentifier?

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only to-one relationships are used; to-many or link-only relationships decode as nil.
        data = try? container.decodeIfPresent(JSONAPIResourceIdentifier.self, forKey: .data)
    }
}

nonisolated struct JSONAPIResourceIdentifier: Decodable, Sendable, Equatable {
    let type: String
    let id: String
}

nonisolated struct JSONAPIIncludedResource: Decodable, Sendable {
    let type: String
    let id: String
    let attributes: Attributes?

    struct Attributes: Decodable, Sendable {
        let name: String?
        let bundleId: String?
        let kind: String?
    }
}

nonisolated struct JSONAPIErrorResponse: Decodable, Sendable {
    let errors: [Entry]

    struct Entry: Decodable, Sendable {
        let status: String?
        let code: String?
        let title: String?
        let detail: String?
    }
}

nonisolated extension JSONDecoder {
    static let appStoreConnect: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date: \(string)")
        }
        return decoder
    }()
}
