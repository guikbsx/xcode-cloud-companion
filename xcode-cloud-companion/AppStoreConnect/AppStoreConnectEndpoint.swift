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
            // The schedule and the Xcode version ride along: they cost no request, and the window warns about them.
            "include": "xcodeVersion",
            "fields[ciWorkflows]": "name,actions,isEnabled,isLockedForEditing,scheduledStartCondition,xcodeVersion",
            "fields[ciXcodeVersions]": "name,version",
            "limit": String(maximumPageSize),
        ])
    }

    /// Every Xcode version Xcode Cloud offers, asked once a day: nothing marks the newest, the app works it out.
    static let xcodeVersions: URL = url(path: "/v1/ciXcodeVersions", query: [
        "fields[ciXcodeVersions]": "name,version",
        "limit": String(maximumPageSize),
    ])

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

    /// An app's newest TestFlight builds with their states, review, marketing version and groups, in one request. The
    /// relations have to be named in `fields[builds]` to come with their identifiers; a page of 5 answers in about a second.
    static func testFlightBuilds(appID: String) -> URL {
        url(path: "/v1/builds", query: [
            "filter[app]": appID,
            "sort": "-uploadedDate",
            "limit": "5",
            "include": "buildBetaDetail,preReleaseVersion,betaAppReviewSubmission,betaGroups",
            "fields[builds]": "version,uploadedDate,expirationDate,expired,processingState,buildBetaDetail,preReleaseVersion,betaAppReviewSubmission,betaGroups",
            "fields[buildBetaDetails]": "internalBuildState,externalBuildState,autoNotifyEnabled",
            "fields[preReleaseVersions]": "version,platform",
            "fields[betaAppReviewSubmissions]": "betaReviewState,submittedDate",
            "fields[betaGroups]": "name,isInternalGroup",
        ])
    }

    /// One TestFlight build as `testFlightBuilds` reads it, to see what a distribution did.
    static func testFlightBuild(id: String) -> URL {
        url(path: "/v1/builds/\(id)", query: [
            "include": "buildBetaDetail,preReleaseVersion,betaAppReviewSubmission,betaGroups",
            "fields[builds]": "version,uploadedDate,expirationDate,expired,processingState,buildBetaDetail,preReleaseVersion,betaAppReviewSubmission,betaGroups",
            "fields[buildBetaDetails]": "internalBuildState,externalBuildState,autoNotifyEnabled",
            "fields[preReleaseVersions]": "version,platform",
            "fields[betaAppReviewSubmissions]": "betaReviewState,submittedDate",
            "fields[betaGroups]": "name,isInternalGroup",
        ])
    }

    /// The TestFlight groups of an app, internal and external.
    static func betaGroups(appID: String) -> URL {
        url(path: "/v1/apps/\(appID)/betaGroups", query: [
            "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled",
            "limit": String(maximumPageSize),
        ])
    }

    /// The testers of a group, by identifier only: the page's total is the number the card shows.
    static func betaGroupTesters(groupID: String) -> URL {
        url(path: "/v1/betaGroups/\(groupID)/relationships/betaTesters", query: ["limit": String(maximumPageSize)])
    }

    /// The fourth write: the groups a build is given to (`POST`) or taken from (`DELETE`), several in one request.
    static func buildBetaGroups(buildID: String) -> URL {
        url(path: "/v1/builds/\(buildID)/relationships/betaGroups", query: [:])
    }

    /// The test notes of a build, one per language.
    static func betaBuildLocalizations(buildID: String) -> URL {
        url(path: "/v1/builds/\(buildID)/betaBuildLocalizations", query: [
            "fields[betaBuildLocalizations]": "locale,whatsNew",
            "limit": "50",
        ])
    }

    static let createBetaBuildLocalization: URL = url(path: "/v1/betaBuildLocalizations", query: [:])

    static func betaBuildLocalization(id: String) -> URL {
        url(path: "/v1/betaBuildLocalizations/\(id)", query: [:])
    }

    /// The beta detail of a build, where Apple keeps whether it tells the testers by itself.
    static func buildBetaDetail(id: String) -> URL {
        url(path: "/v1/buildBetaDetails/\(id)", query: [:])
    }

    static let createBetaAppReviewSubmission: URL = url(path: "/v1/betaAppReviewSubmissions", query: [:])

    /// The fifth write: `PATCH` on a build, which only ever carries `expired: true`.
    static func updateBuild(id: String) -> URL {
        url(path: "/v1/builds/\(id)", query: [:])
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

    /// The first of the two writes the app makes: starting or rebuilding a run.
    static let createBuildRun: URL = url(path: "/v1/ciBuildRuns", query: [:])

    /// The second write: `PATCH` on a workflow, to pause or resume it. Nothing but `isEnabled` is ever sent there.
    static func updateWorkflow(id: String) -> URL {
        url(path: "/v1/ciWorkflows/\(id)", query: [:])
    }

    /// Whether one workflow is enabled right now, to learn what an unconfirmed change did.
    static func workflowState(id: String) -> URL {
        url(path: "/v1/ciWorkflows/\(id)", query: ["fields[ciWorkflows]": "isEnabled"])
    }

    /// One workflow with its versions, to learn what an unconfirmed change did.
    static func workflowDetail(id: String) -> URL {
        url(path: "/v1/ciWorkflows/\(id)", query: [
            "include": "xcodeVersion,macOsVersion",
            "fields[ciWorkflows]": "name,description,isEnabled,isLockedForEditing,clean,containerFilePath,lastModifiedDate,xcodeVersion,macOsVersion",
            "fields[ciXcodeVersions]": "name,version",
            "fields[ciMacOsVersions]": "name,version",
        ])
    }

    /// The macOS versions Xcode Cloud offers for one Xcode version.
    static func macOSVersions(xcodeVersionID: String) -> URL {
        url(path: "/v1/ciXcodeVersions/\(xcodeVersionID)/macOsVersions", query: [
            "fields[ciMacOsVersions]": "name,version",
            "limit": String(maximumPageSize),
        ])
    }

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

    /// The repository's pull requests, open and closed: Apple offers no filter, the app keeps the open ones.
    static func pullRequests(repositoryID: String) -> URL {
        url(path: "/v1/scmRepositories/\(repositoryID)/pullRequests", query: [
            "fields[scmPullRequests]": "title,number,isClosed,isCrossRepository,sourceBranchName,destinationBranchName,webUrl",
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
