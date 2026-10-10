import AppKit
import Foundation
import Observation
import Synchronization

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
    case downloading(fraction: Double?)
    case saved(URL)
    case failed(String)
}

nonisolated enum ArtifactFetchResult: Sendable, Equatable {
    /// The file, in a temporary place, ready to be moved where the user chose.
    case file(URL)
    /// Anything but a success: the body is never read.
    case status(Int)
}

/// Fetches the file behind a fresh address. The request carries no `Authorization` header and no cookie: the address is signed.
nonisolated protocol ArtifactFetching: Sendable {
    func fetch(_ address: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> ArtifactFetchResult
}

/// A session of its own (no cookies, no shared credentials) that only follows redirects that stay on trusted hosts.
nonisolated struct URLSessionArtifactFetcher: ArtifactFetching {
    var configuration: URLSessionConfiguration = .ephemeral

    private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        let progress: @Sendable (Double?) -> Void
        let observation = Mutex<NSKeyValueObservation?>(nil)

        init(progress: @escaping @Sendable (Double?) -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let report = progress
            observation.withLock {
                $0 = task.progress.observe(\.fractionCompleted) { progress, _ in
                    report(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                }
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler((try? ArtifactAddress.validated(request.url)) == nil ? nil : request)
        }
    }

    func fetch(_ address: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> ArtifactFetchResult {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: address, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        let (file, response) = try await session.download(for: request, delegate: Delegate(progress: progress))
        guard let http = response as? HTTPURLResponse else { return .status(0) }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            return .status(http.statusCode)
        }
        return .file(file)
    }
}

/// Saves an artifact where the user chooses, with progress and cancellation. The address is short-lived and signed: it is asked for
/// right before use, checked, used once (twice at most, when the first one was refused) and forgotten, never logged or stored.
@Observable
final class ArtifactSaver {
    private(set) var states: [String: ArtifactState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let fetcher: any ArtifactFetching
    private let chooseDestination: (String) -> URL?

    init(
        client: @escaping () async -> AppStoreConnectClient?,
        fetcher: any ArtifactFetching = URLSessionArtifactFetcher(),
        chooseDestination: @escaping (String) -> URL? = { ArtifactSaver.askUser(suggestedName: $0) }
    ) {
        self.client = client
        self.fetcher = fetcher
        self.chooseDestination = chooseDestination
    }

    func state(of artifactID: String) -> ArtifactState {
        states[artifactID] ?? .idle
    }

    func start(_ artifact: CIArtifact) {
        guard tasks[artifact.id] == nil else { return }
        tasks[artifact.id] = Task { [self] in
            await save(artifact)
            tasks[artifact.id] = nil
        }
    }

    func cancel(_ artifactID: String) {
        tasks[artifactID]?.cancel()
    }

    func save(_ artifact: CIArtifact) async {
        switch states[artifact.id] {
        case .preparing?, .downloading?: return
        default: break
        }
        guard let destination = chooseDestination(artifact.fileName ?? artifact.kindLabel) else { return }
        states[artifact.id] = .preparing
        guard let client = await client() else {
            states[artifact.id] = .failed(String(localized: "No API key is set up."))
            return
        }
        do {
            var result = try await fetchFresh(artifact, client: client)
            if case .status = result {
                // Refused: the link may have expired. One fresh address, one more try, then the code as it is.
                result = try await fetchFresh(artifact, client: client)
            }
            switch result {
            case .status(let code):
                states[artifact.id] = .failed(String(localized: "The link expired or is invalid (HTTP \(code))."))
            case .file(let file):
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                states[artifact.id] = .saved(destination)
            }
        } catch is CancellationError {
            states[artifact.id] = .idle
        } catch let error as URLError where error.code == .cancelled {
            states[artifact.id] = .idle
        } catch let error as AppStoreConnectError {
            states[artifact.id] = .failed(error.message)
        } catch let refusal as ArtifactAddress.Refusal {
            states[artifact.id] = .failed(Self.message(for: refusal))
        } catch {
            states[artifact.id] = .failed(String(localized: "The download could not be completed."))
        }
    }

    private func fetchFresh(_ artifact: CIArtifact, client: AppStoreConnectClient) async throws -> ArtifactFetchResult {
        let fresh = try await client.artifact(id: artifact.id, buildActionID: artifact.buildActionID)
        let address = try ArtifactAddress.validated(fresh.downloadURL)
        states[artifact.id] = .downloading(fraction: nil)
        let id = artifact.id
        return try await fetcher.fetch(address) { [weak self] fraction in
            Task { @MainActor in
                if case .downloading? = self?.states[id] { self?.states[id] = .downloading(fraction: fraction) }
            }
        }
    }

    static func message(for refusal: ArtifactAddress.Refusal) -> String {
        switch refusal {
        case .missing: String(localized: "Apple gave no download address for this file. It may have expired.")
        case .notHTTPS, .unexpectedHost: String(localized: "Apple gave an address this app doesn’t trust, so nothing was downloaded.")
        }
    }

    static func askUser(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
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
