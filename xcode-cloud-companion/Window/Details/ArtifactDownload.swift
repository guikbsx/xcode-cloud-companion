import AppKit
import Foundation
import Observation

/// The only addresses an artifact may be fetched from: https, on Apple's or iCloud's own domains.
nonisolated enum ArtifactAddress {
    enum Refusal: Error, Equatable {
        case missing
        case notHTTPS
        case unexpectedHost
    }

    static let trustedDomains = ["apple.com", "icloud-content.com"]

    static func validated(_ url: URL?) throws(Refusal) -> URL {
        guard let url else { throw .missing }
        guard url.scheme == "https" else { throw .notHTTPS }
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false)?.lowercased(),
              trustedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { throw .unexpectedHost }
        return url
    }
}

enum ArtifactState: Equatable {
    case idle
    case preparing
    case failed(String)
}

/// Gives an artifact to the system once Apple has handed out a fresh address. The address is short-lived and signed:
/// it is asked for right before use, checked, opened and forgotten, and never logged or stored.
@Observable
final class ArtifactOpener {
    private(set) var states: [String: ArtifactState] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let open: (URL) -> Void

    init(client: @escaping () async -> AppStoreConnectClient?, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.client = client
        self.open = open
    }

    func state(of artifactID: String) -> ArtifactState {
        states[artifactID] ?? .idle
    }

    func download(_ artifact: CIArtifact) async {
        guard states[artifact.id] != .preparing else { return }
        states[artifact.id] = .preparing
        guard let client = await client() else {
            states[artifact.id] = .failed(String(localized: "No API key is set up."))
            return
        }
        do {
            let fresh = try await client.artifact(id: artifact.id, buildActionID: artifact.buildActionID)
            let address = try ArtifactAddress.validated(fresh.downloadURL)
            open(address)
            states[artifact.id] = .idle
        } catch let error as AppStoreConnectError {
            states[artifact.id] = .failed(error.message)
        } catch let refusal as ArtifactAddress.Refusal {
            states[artifact.id] = .failed(Self.message(for: refusal))
        } catch {
            states[artifact.id] = .failed(String(localized: "The download could not start."))
        }
    }

    static func message(for refusal: ArtifactAddress.Refusal) -> String {
        switch refusal {
        case .missing: String(localized: "Apple gave no download address for this file. It may have expired.")
        case .notHTTPS, .unexpectedHost: String(localized: "Apple gave an address this app doesn’t trust, so nothing was opened.")
        }
    }
}

nonisolated extension CIArtifact {
    var kindLabel: String {
        switch fileType {
        case "ARCHIVE": String(localized: "Archive")
        case "ARCHIVE_EXPORT": String(localized: "Exported archive")
        case "LOG_BUNDLE": String(localized: "Logs")
        case "RESULT_BUNDLE": String(localized: "Test results")
        case "TEST_PRODUCTS": String(localized: "Test products")
        case "XCODEBUILD_PRODUCTS": String(localized: "Build products")
        case "STAPLED_NOTARIZED_ARCHIVE": String(localized: "Notarized archive")
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: String(localized: "File")
        }
    }
}
