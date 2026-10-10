import Foundation

nonisolated struct CLIResult: Equatable, Sendable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = CLIExitCode.success
}

nonisolated enum CLIExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let noCache: Int32 = 3
    static let appUnreachable: Int32 = 4
    static let notFound: Int32 = 5
    static let timedOut: Int32 = 6
}

/// Everything a command reads from the outside, so tests run it against a temporary folder and a fixed clock.
nonisolated struct CLIEnvironment: Sendable {
    var version: String
    var build: String
    /// The app group's Application Support, where the app writes its caches.
    var directory: URL
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .current
    var isTerminal = false
    var terminalWidth = 100
    /// Opens an address with the system; false when it could not.
    var openURL: @Sendable (URL) -> Bool = { _ in false }
    /// The socket the app listens on; nil when the shared folder is out of reach.
    var socketPath: String?
    /// Starts the Cumulus app in the background; false when the system refused.
    var launchApp: @Sendable () async -> Bool = { false }
    /// How long a freshly started app is given to answer on its socket.
    var launchPatience: TimeInterval = 15

    static var live: CLIEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        return CLIEnvironment(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            directory: SharedContainer.applicationSupport,
            isTerminal: isatty(STDOUT_FILENO) != 0,
            terminalWidth: liveTerminalWidth(),
            openURL: CLISystem.open,
            socketPath: SharedContainer.socketPath,
            launchApp: { CLISystem.run("/usr/bin/open", ["-g", "-b", CLISystem.appBundleIdentifier]) }
        )
    }

    private static func liveTerminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return ProcessInfo.processInfo.environment["COLUMNS"].flatMap { Int($0) } ?? 100
    }
}

nonisolated enum CLISystem {
    static let appBundleIdentifier = "com.guik.xcode-cloud-companion"

    /// The sandbox lets the command hand an address to `open`, which asks Launch Services: no AppKit needed.
    static func open(_ url: URL) -> Bool {
        run("/usr/bin/open", [url.absoluteString])
    }

    static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
