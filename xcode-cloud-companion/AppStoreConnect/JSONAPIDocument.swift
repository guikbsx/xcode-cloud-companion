import Foundation

nonisolated struct JSONAPIDocument<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let data: [JSONAPIResource<Attributes>]
    let included: [JSONAPIIncludedResource]?
    let links: Links?

    struct Links: Decodable, Sendable {
        let next: URL?
    }

    init(single: JSONAPISingleDocument<Attributes>) {
        data = [single.data]
        included = single.included
        links = nil
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

    func relationships(_ name: String) -> [JSONAPIResourceIdentifier] {
        relationships?[name]?.dataList ?? []
    }
}

/// A response holding one resource (`GET /v1/ciArtifacts/{id}`) rather than a collection.
nonisolated struct JSONAPISingleDocument<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let data: JSONAPIResource<Attributes>
    let included: [JSONAPIIncludedResource]?
}

nonisolated struct JSONAPIRelationship: Decodable, Sendable {
    /// The target of a to-one relationship; nil for a to-many or link-only one.
    let data: JSONAPIResourceIdentifier?
    /// The targets of a to-many relationship (empty for a to-one or link-only one).
    let dataList: [JSONAPIResourceIdentifier]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try? container.decodeIfPresent(JSONAPIResourceIdentifier.self, forKey: .data)
        dataList = (try? container.decodeIfPresent([JSONAPIResourceIdentifier].self, forKey: .data)) ?? []
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
        // ciXcodeVersions, ciMacOsVersions
        let version: String?
        // scmRepositories
        let ownerName: String?
        let repositoryName: String?
        // scmPullRequests
        let title: String?
        let number: Int?
        let webUrl: String?
        let sourceBranchName: String?
        let destinationBranchName: String?
        let isClosed: Bool?
    }
}

nonisolated struct JSONAPIErrorResponse: Decodable, Sendable {
    let errors: [Entry]

    struct Entry: Decodable, Sendable {
        let status: String?
        let code: String?
        let title: String?
        let detail: String?
        let source: Source?

        /// Where in the request the refusal points, e.g. `/data/relationships/sourceBranchOrTag`.
        struct Source: Decodable, Sendable {
            let pointer: String?
        }
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
