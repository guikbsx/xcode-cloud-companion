import Foundation

nonisolated enum AppStoreConnectEndpoint {
    static let host = "api.appstoreconnect.apple.com"
    static let maximumPageSize = 200

    static func products(pageSize: Int) -> URL {
        url(path: "/v1/ciProducts", query: [
            "include": "app",
            "fields[ciProducts]": "name,productType,app",
            "fields[apps]": "name,bundleId",
            "limit": String(clampedPageSize(pageSize)),
        ])
    }

    static func buildRuns(productID: String, pageSize: Int) -> URL {
        url(path: "/v1/ciProducts/\(productID)/buildRuns", query: [
            "sort": "-number",
            "include": "workflow,sourceBranchOrTag",
            "fields[ciBuildRuns]": "number,createdDate,startedDate,finishedDate,executionProgress,completionStatus,startReason,workflow,sourceBranchOrTag",
            "fields[ciWorkflows]": "name",
            "fields[scmGitReferences]": "name,kind",
            "limit": String(clampedPageSize(pageSize)),
        ])
    }

    static func buildActions(buildRunID: String) -> URL {
        url(path: "/v1/ciBuildRuns/\(buildRunID)/actions", query: [
            "fields[ciBuildActions]": "name,actionType,startedDate,finishedDate,executionProgress,completionStatus,isRequiredToPass",
            "limit": String(maximumPageSize),
        ])
    }

    /// Only the per-device results: a build has hundreds of test cases, their names are not needed.
    static func testResults(buildActionID: String) -> URL {
        url(path: "/v1/ciBuildActions/\(buildActionID)/testResults", query: [
            "fields[ciTestResults]": "status,destinationTestResults",
            "limit": String(maximumPageSize),
        ])
    }

    static func workflows(productID: String) -> URL {
        url(path: "/v1/ciProducts/\(productID)/workflows", query: [
            "fields[ciWorkflows]": "name,actions",
            "limit": String(maximumPageSize),
        ])
    }

    static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == host
    }

    private static func clampedPageSize(_ pageSize: Int) -> Int {
        min(max(pageSize, 1), maximumPageSize)
    }

    private static func url(path: String, query: KeyValuePairs<String, String>) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            preconditionFailure("Invalid App Store Connect URL for path \(path)")
        }
        return url
    }
}
