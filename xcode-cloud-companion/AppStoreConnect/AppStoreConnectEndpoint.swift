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
            "include": "workflow,sourceBranchOrTag,pullRequest",
            "fields[ciBuildRuns]": "number,createdDate,startedDate,finishedDate,executionProgress,completionStatus,startReason,cancelReason,isPullRequestBuild,issueCounts,sourceCommit,workflow,sourceBranchOrTag,pullRequest",
            "fields[ciWorkflows]": "name",
            "fields[scmGitReferences]": "name,kind",
            "fields[scmPullRequests]": "title,number",
            "limit": String(clampedPageSize(pageSize)),
        ])
    }

    static func buildActions(buildRunID: String) -> URL {
        url(path: "/v1/ciBuildRuns/\(buildRunID)/actions", query: [
            "fields[ciBuildActions]": "name,actionType,startedDate,finishedDate,executionProgress,completionStatus,isRequiredToPass,issueCounts",
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

    /// Everything the workflow sheet shows, with the Xcode and macOS versions and the repository included.
    static func workflowDetails(productID: String) -> URL {
        url(path: "/v1/ciProducts/\(productID)/workflows", query: [
            "include": "xcodeVersion,macOsVersion,repository",
            "fields[ciWorkflows]": "name,description,isEnabled,isLockedForEditing,clean,containerFilePath,lastModifiedDate,branchStartCondition,tagStartCondition,pullRequestStartCondition,scheduledStartCondition,manualBranchStartCondition,manualTagStartCondition,manualPullRequestStartCondition,actions,xcodeVersion,macOsVersion,repository",
            "fields[ciXcodeVersions]": "name,version",
            "fields[ciMacOsVersions]": "name,version",
            "fields[scmRepositories]": "ownerName,repositoryName",
            "limit": String(maximumPageSize),
        ])
    }

    static func issues(buildActionID: String) -> URL {
        url(path: "/v1/ciBuildActions/\(buildActionID)/issues", query: [
            "fields[ciIssues]": "issueType,message,category,fileSource",
            "limit": String(maximumPageSize),
        ])
    }

    /// Test cases with their message, file and per-device results (the cost-only variant is `testResults`).
    static func testResultDetails(buildActionID: String) -> URL {
        url(path: "/v1/ciBuildActions/\(buildActionID)/testResults", query: [
            "fields[ciTestResults]": "className,name,status,message,fileSource,destinationTestResults",
            "limit": String(maximumPageSize),
        ])
    }

    static func artifacts(buildActionID: String) -> URL {
        url(path: "/v1/ciBuildActions/\(buildActionID)/artifacts", query: [
            "fields[ciArtifacts]": "fileType,fileName,fileSize",
            "limit": String(maximumPageSize),
        ])
    }

    /// One artifact with its short-lived download address, asked right before a download.
    static func artifact(id: String) -> URL {
        url(path: "/v1/ciArtifacts/\(id)", query: [
            "fields[ciArtifacts]": "fileType,fileName,fileSize,downloadUrl",
        ])
    }

    /// The TestFlight builds a build run produced.
    static func betaBuilds(buildRunID: String) -> URL {
        url(path: "/v1/ciBuildRuns/\(buildRunID)/builds", query: [
            "fields[builds]": "version,uploadedDate,processingState",
            "limit": "10",
        ])
    }

    /// Every app with one of its builds, for the icon that build carries. Apple picks the build, and not always the newest.
    static let appIcons: URL = url(path: "/v1/apps", query: [
        "include": "builds",
        "fields[apps]": "builds",
        "fields[builds]": "iconAssetToken",
        "limit[builds]": "1",
        "limit": String(maximumPageSize),
    ])

    /// The account's newest builds with their app: where an icon that changed shows up.
    static let latestBuildIcons: URL = url(path: "/v1/builds", query: [
        "sort": "-uploadedDate",
        "include": "app",
        "fields[builds]": "iconAssetToken,app",
        "fields[apps]": "bundleId",
        "limit": String(maximumPageSize),
    ])

    /// The only write the app makes: starting or rebuilding a run.
    static let createBuildRun: URL = url(path: "/v1/ciBuildRuns", query: [:])

    static func workflowRepository(workflowID: String) -> URL {
        url(path: "/v1/ciWorkflows/\(workflowID)/repository", query: [
            "fields[scmRepositories]": "ownerName,repositoryName",
        ])
    }

    static func gitReferences(repositoryID: String) -> URL {
        url(path: "/v1/scmRepositories/\(repositoryID)/gitReferences", query: [
            "fields[scmGitReferences]": "name,canonicalName,isDeleted,kind",
            "limit": String(maximumPageSize),
        ])
    }

    /// The newest run of a workflow, to find out what an uncertain launch did.
    static func latestBuildRun(workflowID: String) -> URL {
        url(path: "/v1/ciWorkflows/\(workflowID)/buildRuns", query: [
            "sort": "-number",
            "include": "workflow,sourceBranchOrTag,pullRequest",
            "fields[ciBuildRuns]": "number,createdDate,startedDate,finishedDate,executionProgress,completionStatus,startReason,cancelReason,isPullRequestBuild,issueCounts,sourceCommit,workflow,sourceBranchOrTag,pullRequest",
            "fields[ciWorkflows]": "name",
            "fields[scmGitReferences]": "name,kind",
            "fields[scmPullRequests]": "title,number",
            "limit": "1",
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
