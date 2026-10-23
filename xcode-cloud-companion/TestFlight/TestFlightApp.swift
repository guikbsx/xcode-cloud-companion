import Foundation

/// An app that hands builds to TestFlight, as a sync knows it.
nonisolated struct TestFlightApp: Sendable, Equatable, Identifiable {
    /// The Xcode Cloud product: what a muted app and a palette are keyed by.
    var productID: String
    var appID: String
    var name: String
    /// When the newest successful build of a workflow that ships to TestFlight finished.
    var newestShippedFinish: Date?

    var id: String { productID }

    /// The apps with a workflow that hands its archive to TestFlight and an App Store Connect app to ask about.
    static func shipping(in snapshot: BuildSnapshot) -> [TestFlightApp] {
        snapshot.products.compactMap { product in
            guard let appID = product.appID else { return nil }
            let shipping = Set(snapshot.workflows.filter { $0.productID == product.id && $0.shipsToTestFlight }.map(\.id))
            guard !shipping.isEmpty else { return nil }
            let finish = snapshot.runs
                .filter { $0.productID == product.id && $0.completionStatus == .succeeded && $0.workflowID.map(shipping.contains) == true }
                .compactMap { $0.finishedDate }
                .max()
            return TestFlightApp(productID: product.id, appID: appID, name: product.displayName, newestShippedFinish: finish)
        }
    }
}
