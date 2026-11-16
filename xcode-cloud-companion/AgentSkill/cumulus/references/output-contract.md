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
    "isEstimate": true,
    "account": "Personal"
  }
}
```

- `lastSuccessfulSync`: when the Cumulus app last synced with App Store Connect; `null` before its first sync.
- `appRunning`: whether the app answered on its socket. When false, the cache only gets older, and `cumulus refresh` starts the app.
- `isEstimate`: present and true when the answer contains minutes estimated by Cumulus. Absent otherwise.
- `account`: the name of the App Store Connect account the answer is about: the one shown in the app, or the one named with `--account`.
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
| 5 | `NOT_FOUND`, `AMBIGUOUS` | No app, build, group or account matches, or several do | `suggestions` lists what exists or the candidates; pick one and retry |
| 6 | `TIMEOUT` | `refresh --wait` waited past `--timeout`, or `run` got no answer | The sync goes on in the app; run `cumulus status` later. After `run`, check `cumulus builds --limit 1` before anything else |
| 7 | `NOT_ALLOWED` | `run`, `testflight give`, `testflight expire`: the key is read-only in the app, or Apple answered 403 | Ask the user to set the key to “Read + Build” in Cumulus › Settings › Accounts (TestFlight also needs an Admin or App Manager key); do not retry |
| 8 | `RATE_LIMITED` | `run`: three launches by agents already this hour; `testflight give` and `expire`: ten changes already this hour; or Apple's hourly limit | Ask the user to make the change from the app, or wait |
| 1 | `REFUSED` | `run`, `testflight give`, `testflight expire`: Apple refused, or the TestFlight build is in a state that does not allow it (still processing, expired); the words are in `message` | Report them; do not retry |

Through MCP, the same `error` object comes back as the text of a result with `isError: true`.

## `accounts`

`data` is an array of: `name` (what `--account` takes), `selected` (true for the account shown in the app, the one every other command answers for by default), `lastSuccessfulSync` (absent before the account's first sync), `appCount`.

Every account syncs in the background, whichever one is selected. `meta` is about the selected account.

## `status`

`data`: `planConfigured`, `usage` (below; absent when no plan is set), `runningBuilds`, `appCount`, `hint` (only when something is missing).

`usage`: `planHours`, `quotaMinutes`, `billedMinutes`, `estimatedMinutes`, `usedMinutes`, `remainingMinutes`, `fractionUsed` (0 to 1), `cycleStart`, `resetDate`, `projectedMinutes` (at the reset, at the current pace; absent in the first day of a cycle), `exhaustionDate` (only when the plan runs out before the reset), `estimatedBuildCount`, `lastImport` (of a usage export), `importIsStale`, `measurement` (`isMeasuring`, `pendingBuilds`, `measuredActions`, `totalActions`, `unmeasurableActions`), `note`.

While `measurement.isMeasuring` is true, the app is still reading the test results of some builds: `estimatedMinutes` is incomplete and will grow.

## `apps`

`data` is an array of: `id`, `name` (the Xcode Cloud product name: what `--app` and build references use), `storeName` (the app's App Store name, when the product is an app that has one), `bundleID`, `type`, `latestBuild` (`id`, `reference`, `number`, `status`, `createdDate`, `finishedDate`), `runningBuilds`, `cycle` (`billedMinutes`, `estimatedMinutes`, `totalMinutes`; absent when no plan is set).

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

`data` is an array of: `id`, `name`, `app`, `productID`, `isEnabled`, `description`, `testDestinations`, `actions`, `repository`, `xcodeVersion`, `macOSVersion`, `lastBuild`, `cycle` (`buildCount`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`, `averageMinutes`), `trends` (`sampleSize`, `medianDurationMinutes`, `medianQueueWaitMinutes`, `successRate` from 0 to 1; over the newest 30 finished builds of the cache, canceled and skipped ones left out; absent without a finished build), `nextScheduledRun` (ISO 8601; only for an enabled workflow with a schedule; `cycle.averageMinutes` says what one run is expected to cost), `latestXcodeVersion` (the newest public Xcode that Xcode Cloud offers, to compare with `xcodeVersion`; absent until the app read the list).

`isEnabled`, `description`, `actions`, `repository` and the versions are only known for workflows the user opened in the app.

## `usage`

`data`: `planConfigured`, `summary` (the `usage` object of `status`), `costliestBuild` (`app`, `number`, `reference`, `workflow`, `minutes`, `isEstimated`), and one of:

- `byApp` (`--by-app`): `app`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`
- `byWorkflow` (`--by-workflow`): `app`, `workflow`, `buildCount`, `billedMinutes`, `estimatedMinutes`, `totalMinutes`, `averageMinutes`
- `daily` (`--daily`): the last 30 days, `day` (`2026-10-10`), `billedMinutes`, `estimatedMinutes`, `totalMinutes`

## `refresh`

`data`: `accepted`, `reason` (`recent`: a sync ended less than 30 seconds ago; `syncing`: one was already running), `outcome` (`succeeded`, `failed`, `rateLimited`, `notConfigured`; only with `--wait`), `waited`, `appLaunched`, `status` (the `status` answer, only with `--wait`).

`accepted: false` with `reason: "recent"` or `"syncing"` is not a failure: the data is fresh, or about to be.

## `run`

`data`: `buildRunID`, `number`, `reference` (`App#42`, what `cumulus build` takes), `app`, `workflow`, `source` (`kind`: `branch`, `tag` or `pullRequest`; `name`; `pullRequestNumber`), `clean`, `appLaunched`.

Errors on standard error: `NOT_ALLOWED` (exit 7: the key is read-only in the app, or Apple answered 403), `RATE_LIMITED` (exit 8: the app's cap of three launches by agents an hour per account, or Apple's hourly limit), `REFUSED` (exit 1: Apple refused, its words in `message`; a paused workflow, a source no manual condition covers), `NOT_FOUND` (no such workflow, branch, tag or open pull request), `USAGE` (no source given and no earlier build to take the branch from). Never retry `run` on your own after any of these.

## `testflight`

`cumulus testflight <build>` — `data`: `buildRunID`, `reference` (`App#42`), `app`, `build`, `groups`, `hint`.

- `build` (absent when Cumulus knows no TestFlight build for the Xcode Cloud build; then `hint` says why): `id`, `label` (`1.4 (412)`), `version`, `buildNumber`, `platform`, `status` (one word: `processing`, `processingFailed`, `waitingForReview`, `inReview`, `rejected`, `available`, `ready`, `expired`, `unknown`), `processingState`, `internalState`, `externalState` (`processing`, `readyForSubmission`, `waitingForReview`, `inReview`, `rejected`, `approved`, `ready`, `testing`, `expired`, `missingCompliance`, `unknown`), `betaReview` (only once the build was sent to the beta review), `uploadedDate`, `expirationDate`, `daysLeft` (until it stops working; absent once expired), `notifiesTesters` (whether Apple tells the testers by itself), `needsExportCompliance`.
- `groups` (absent until the app read the groups of the app): `id`, `name`, `kind` (`internal` or `external`), `receivesEveryBuild` (an internal group that gets every build by itself: it can be neither named in `give` nor taken from), `testerCount` (when known), `hasBuild`.
- The command reads what the app keeps. When the shared folder lacks the TestFlight build or the groups, the running app reads them once; `--cached` never asks it.

`cumulus testflight give` and `cumulus testflight expire` — `data`: `action` (`give` or `expire`), `buildRunID`, `reference`, `app`, `changed` (false when the groups were already as asked, or the build already expired: nothing was sent), and for `give` `added`, `removed` and `unchanged` (group names), `steps` (what Apple accepted: `notes`, `notification`, `addGroups`, `removeGroups`, `betaReview`), `build` (the TestFlight build as Apple has it after the write, as above; absent when it could not be read back), `notifiesTesters`, `appLaunched`, `message`.

`--group` and `--remove` repeat, one name each; a group is named once in the whole command. `--notes` needs `--locale` and at least one `--group`; `--notify` and `--no-notify` need one too.

Errors on standard error: `NOT_ALLOWED` (exit 7), `RATE_LIMITED` (exit 8: ten changes an hour per account, give and expire together), `REFUSED` (exit 1), `NOT_FOUND` or `AMBIGUOUS` (exit 5: no such build, no TestFlight build for it, or a group name unknown or shared by two groups; `suggestions` lists the groups that exist), `USAGE` (exit 2: a group that receives every build by itself, or arguments that do not go together), `INTERNAL` (exit 1: Apple did not confirm the change). **Never retry after any of these**: run `cumulus testflight <build> --json` and read what Apple has.

## MCP tools

`cumulus mcp` serves the same answers over the Model Context Protocol (stdio). Each tool returns the JSON above as text and as `structuredContent`.

Every tool except `list_accounts` also takes `account`, an account's name: the same as `--account`.

| Tool | Arguments | Same as |
|---|---|---|
| `get_status` | - | `status` |
| `list_apps` | - | `apps` |
| `list_builds` | `app`, `failed`, `running`, `limit`, `since`, `branch`, `pull_request` | `builds` |
| `get_build` | `reference` (required), `fetchDetails` (default true) | `build` |
| `list_workflows` | `app` | `workflows` |
| `get_usage` | `breakdown`: `summary`, `byApp`, `byWorkflow`, `daily` | `usage` |
| `refresh` | `wait` (default true), `timeoutSeconds` (default 120) | `refresh` |
| `start_build` | `workflow` (required), `branch`, `tag`, `pull_request`, `clean` | `run` |
| `get_testflight` | `reference` (required), `fetchDetails` (default true) | `testflight <build>` |
| `give_testflight_build` | `reference` (required), `groups`, `remove_groups` (lists of group names), `notes`, `locale`, `notify` | `testflight give` |
| `expire_testflight_build` | `reference` (required) | `testflight expire` |
| `list_accounts` | - | `accounts` |
