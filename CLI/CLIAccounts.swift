import Foundation

/// The account a command answers for: the one named with `--account`, otherwise the one on screen in the app.
nonisolated struct CLIAccountScope: Equatable, Sendable {
    var account: Account
    var isSelected: Bool
    /// The app follows other accounts too: a table then says which one it shows.
    var hasSiblings: Bool
    /// Where the app keeps this account's caches.
    var directory: URL

    static func registry(in root: URL) async -> AccountRegistry? {
        await AccountRegistryStore(fileURL: root.appending(path: "Accounts.json")).load()
    }

    static func directory(of account: Account, in root: URL) -> URL {
        AccountPaths(accountID: account.id, supportRoot: root, cachesRoot: root).support
    }

    /// Without a list of accounts the app never ran: there is no cache either.
    static func resolve(_ reference: String?, in root: URL) async throws(CLIFailure) -> CLIAccountScope {
        guard let registry = await registry(in: root) else { throw CLIFailure.noCache }
        guard let reference else {
            return CLIAccountScope(
                account: registry.selected, isSelected: true, hasSiblings: registry.accounts.count > 1, directory: directory(of: registry.selected, in: root)
            )
        }
        let matches = registry.accounts(matching: reference)
        switch matches.count {
        case 1:
            return CLIAccountScope(
                account: matches[0], isSelected: matches[0].id == registry.selectedID, hasSiblings: registry.accounts.count > 1,
                directory: directory(of: matches[0], in: root)
            )
        case 0:
            throw CLIFailure(
                code: .notFound, message: "No account matches '\(reference)'.",
                suggestions: registry.accounts.map { "Known account: \($0.name)" }
            )
        default:
            throw CLIFailure(
                code: .ambiguous, message: "Several accounts are named '\(reference)'.",
                suggestions: matches.map { "Use its id: \($0.id)" }
            )
        }
    }
}
