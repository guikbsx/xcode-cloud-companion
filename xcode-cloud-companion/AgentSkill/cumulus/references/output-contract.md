# `cumulus` output contract

## Envelope

Every successful answer, on standard output:

```json
{
  "data": { },
  "meta": {
    "lastSuccessfulSync": "2026-10-10T09:55:00Z",
    "generatedAt": "2026-10-10T10:00:00Z",
    "cliVersion": "1.0",
    "appRunning": true,
    "isEstimate": true
  }
}
```

- `lastSuccessfulSync`: when the Cumulus app last synced with App Store Connect; `null` before its first sync.
- `appRunning`: whether the app answered on its socket. When false, the cache only gets older, and `cumulus refresh` starts the app.
- `isEstimate`: present and true when the answer contains minutes estimated by Cumulus. Absent otherwise.
- Dates are ISO 8601 in UTC. Durations are whole seconds. Minutes are decimal, to one decimal.
- A key whose value is unknown is left out, not set to `null` (except `lastSuccessfulSync`).

## Errors

On standard error, with a non-zero exit code:

```json
{ "error": { "code": "NOT_FOUND", "message": "Alpha has no build 999 in the cache.", "suggestions": ["Run 'cumulus builds --app \"Alpha\"' to list its recent builds."] } }
```

| Exit | `code` | Meaning | What to do |
|---|---|---|---|
| 0 | - | Success | |
| 1 | `INTERNAL` | The command failed for a reason of its own | Report it; do not retry |
| 2 | `USAGE` | Unknown command, option or value | Read `cumulus help <command>` |
| 3 | `NO_CACHE` | The app never synced, or has no API key | Ask the user to open Cumulus and add their App Store Connect API key |
| 4 | `APP_UNREACHABLE` | `refresh` could not reach or start the app | Ask the user to open Cumulus |
| 5 | `NOT_FOUND`, `AMBIGUOUS` | No app or build matches, or several do | `suggestions` lists what exists or the candidates; pick one and retry |
| 6 | `TIMEOUT` | `refresh --wait` waited past `--timeout` | The sync goes on in the app; run `cumulus status` later |

Through MCP, the same `error` object comes back as the text of a result with `isError: true`.

## `status`

`data`: `planConfigured`, `usage` (below; absent when no plan is set), `runningBuilds`, `appCount`, `hint` (only when something is missing).

`usage`: `planHours`, `quotaMinutes`, `billedMinutes`, `estimatedMinutes`, `usedMinutes`, `remainingMinutes`, `fractionUsed` (0 to 1), `cycleStart`, `resetDate`, `projectedMinutes` (at the reset, at the current pace; absent in the first day of a cycle), `exhaustionDate` (only when the plan runs out before the reset), `estimatedBuildCount`, `lastImport` (of a usage export), `importIsStale`, `measurement` (`isMeasuring`, `pendingBuilds`, `measuredActions`, `totalActions`, `unmeasurableActions`), `note`.

While `measurement.isMeasuring` is true, the app is still reading the test results of some builds: `estimatedMinutes` is incomplete and will grow.

## `apps`

`data` is an array of: `id`, `name`, `bundleID`, `type`, `latestBuild` (`id`, `reference`, `number`, `status`, `createdDate`, `finishedDate`), `runningBuilds`, `cycle` (`billedMinutes`, `estimatedMinutes`, `totalMinutes`; absent when no plan is set).

## `builds`

`data` is an array of builds, newest first:

- `id`, `reference` (`App#42`), `app`, `productID`, `number`
- `workflow`, `workflowID`
- `source`: `kind` (`branchOrTag` or `pullRequest`), `name`, `pullRequestNumber`, `pullRequestTitle`
- `status`: one word - `pending`, `running`, `succeeded`, `failed`, `errored`, `canceled`, `skipped`, `finished`
- `executionProgress` (`PENDING`, `RUNNING`, `COMPLETE`) and `completionStatus` (`SUCCEEDED`, `FAILED`, `ERRORED`, `CANCELED`, `SKIPPED`), as Apple gives them
- `startReason`, `cancelReason`
- `createdDate`, `startedDate`, `finishedDate`, `durationSeconds` (up to now for a running build)
- `commit`: `sha`, `shortSha`, `message`, `author`, `url`
- `issueCounts`: `errors`, `warnings`, `testFailures`, `analyzerWarnings`
- `billedMinutes` (Apple's, from a usage export) or `estimatedMinutes` (Cumulus's); neither while the build's test results are still being measured

## `build`

`data`:

- `build`: the build, as in `builds`
- `actions`: `id`, `name`, `type` (`BUILD`, `ANALYZE`, `TEST`, `ARCHIVE`), `status`, `executionProgress`, `completionStatus`, `isRequiredToPass`, `startedDate`, `finishedDate`, `durationSeconds`, `issueCounts`, `testDevices` (`deviceName`, `osVersion`, `testCount`, `failedCount`, `seconds`)
- `detailsAvailable`: whether issues, tests and artifacts were read for this build; `detailsLoaded` says which (`issues`, `tests`, `artifacts`)
- `issues`: `actionID`, `action`, `type` (`ERROR`, `TEST_FAILURE`, `WARNING`, `ANALYZER_WARNING`), `category`, `message`, `file` (`path`, `line`). Errors and test failures first, all of them; then at most 50 warnings
- `omittedWarnings`: how many warnings were left out
- `failedTests`: `actionID`, `className`, `name`, `status`, `message`, `file`, `devices` (`deviceName`, `osVersion`, `status`, `durationSeconds`)
- `testSummary`: `total`, `failed`, `skipped`, `passed`
- `artifacts`: `actionID`, `fileName`, `fileType`, `fileSize` (bytes). No download address: the user downloads them from the app
- `testFlightBuilds`: `id`, `version`, `uploadedDate`, `processingState`
- `links`: `appStoreConnect`, `cumulus` (`cumulus://build/<id>`, opens the build in the app)
- `hint`: what to do when details are missing

## `workflows`

`data` is an array of: `id`, `name`, `app`, `productID`, `isEnabled`, `description`, `testDestinations`, `actions`, `repository`, `xcodeVersion`, `macOSVersion`, `lastBuild`, `cycle` (`buildCount`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`, `averageMinutes`).

`isEnabled`, `description`, `actions`, `repository` and the versions are only known for workflows the user opened in the app.

## `usage`

`data`: `planConfigured`, `summary` (the `usage` object of `status`), `costliestBuild` (`app`, `number`, `reference`, `workflow`, `minutes`, `isEstimated`), and one of:

- `byApp` (`--by-app`): `app`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`
- `byWorkflow` (`--by-workflow`): `app`, `workflow`, `buildCount`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`, `averageMinutes`
- `daily` (`--daily`): the last 30 days, `day` (`2026-10-10`), `billedMinutes`, `estimatedMinutes`, `totalMinutes`

## `refresh`

`data`: `accepted`, `reason` (`recent`: a sync ended less than 30 seconds ago; `syncing`: one was already running), `outcome` (`succeeded`, `failed`, `rateLimited`, `notConfigured`; only with `--wait`), `waited`, `appLaunched`, `status` (the `status` answer, only with `--wait`).

`accepted: false` with `reason: "recent"` or `"syncing"` is not a failure: the data is fresh, or about to be.

## MCP tools

`cumulus mcp` serves the same answers over the Model Context Protocol (stdio). Each tool returns the JSON above as text and as `structuredContent`.

| Tool | Arguments | Same as |
|---|---|---|
| `get_status` | - | `status` |
| `list_apps` | - | `apps` |
| `list_builds` | `app`, `failed`, `running`, `limit`, `since` | `builds` |
| `get_build` | `reference` (required), `fetchDetails` (default true) | `build` |
| `list_workflows` | `app` | `workflows` |
| `get_usage` | `breakdown`: `summary`, `byApp`, `byWorkflow`, `daily` | `usage` |
| `refresh` | `wait` (default true), `timeoutSeconds` (default 120) | `refresh` |
