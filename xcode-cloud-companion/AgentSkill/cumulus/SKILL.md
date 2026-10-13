---
name: cumulus
description: Use this skill whenever the task involves Xcode Cloud builds or usage on this Mac - why a build failed, which builds are running, the latest build of an app or a branch, compiler errors and failing tests of a build, how many Xcode Cloud minutes or hours are left in the billing cycle, which workflow costs the most - or whenever the user mentions Cumulus or the `cumulus` command. Cumulus answers from the cache of the Cumulus menu bar app, in JSON, without calling Apple.
---

# `cumulus`

`cumulus` is the command-line side of Cumulus, a macOS menu bar app that watches a team's Xcode Cloud builds and usage. The command reads the cache the app keeps, so it is fast, works offline, and costs nothing of the App Store Connect API rate limit. It is read-only: no command starts, cancels or changes a build.

## Find the command

Resolve it once, then use that path for every call in the session:

1. `command -v cumulus`
2. `/opt/homebrew/bin/cumulus`, then `/usr/local/bin/cumulus`
3. `/Applications/Cumulus.app/Contents/Helpers/cumulus`, then `~/Applications/Cumulus.app/Contents/Helpers/cumulus`

If none exists, tell the user to install the command from **Cumulus › Settings › Agents**, and stop.

## Commands

| Command | Answers |
|---|---|
| `cumulus status` | Usage of the billing cycle (minutes used, remaining, reset date, projection) and how many builds run now |
| `cumulus accounts` | The App Store Connect accounts the app follows, when there are several |
| `cumulus apps` | The account's apps with their latest build and their minutes this cycle |
| `cumulus builds [--app <app>] [--failed] [--running] [--limit <n>] [--since <when>] [--branch <name> \| --pr <number>]` | Recent builds, newest first |
| `cumulus build <build> [--cached]` | One build: actions, compiler errors and warnings, failed tests, artifacts, TestFlight builds, links |
| `cumulus workflows [--app <app>]` | Workflows with their last build and their cost this cycle |
| `cumulus usage [--by-app \| --by-workflow \| --daily]` | Minutes of the cycle, broken down |
| `cumulus refresh [--wait] [--timeout <seconds>]` | Asks the app to sync with App Store Connect now |
| `cumulus run <workflow> [--branch <name> \| --tag <name> \| --pr <number>] [--clean] [--yes]` | Starts a build of a workflow through the app; answers with the new build's `reference` |
| `cumulus open <build>` | Opens the build in the Cumulus app, for the user to look at |

- `<app>` is an app's name, bundle ID or product id. Case does not matter.
- `<build>` is `App#42`, a build number alone when only one app has it, or a build run id. `cumulus builds` gives both `reference` and `id`.
- `--limit` goes from 1 to 100 (default 10). `--since` takes an ISO 8601 date or a span: `7d`, `24h`, `30m`.
- `--failed` keeps builds that failed or errored, `--running` those pending or running; together, builds in either state.
- `--branch <name>` keeps the builds of one branch or tag (a pull request's builds are not its branch's), `--pr <number>` those of one pull request. Not both.
- `--account <name>` goes with every command above except `accounts`: it answers for that account instead of the one shown in the app.
- `cumulus help <command>` prints a command's options.

## Rules

- **Pass `--json`.** Output is JSON anyway when it is not a terminal, but being explicit costs nothing. Keep each call self-contained: no `jq`, no pipelines; read the JSON directly.
- **Check freshness.** Every answer has `meta.lastSuccessfulSync` (when the app last synced, or `null`) and `meta.appRunning`. If the data is too old for the question, or the user just pushed, run `cumulus refresh --wait --json` first. It starts the app if needed and returns the fresh status. A sync less than 30 seconds old is not repeated (`reason: "recent"`): that is a success.
- **One account per answer.** The app may follow several App Store Connect accounts (teams), each with its own apps, builds and plan. An answer is about the account named in `meta.account`: the one shown in the app, unless `--account <name>` names another. Most setups have one account and need nothing. If the app or build the user means is not found, run `cumulus accounts --json` and ask again with `--account`; say which account a figure is about when there are several.
- **Minutes are estimates.** `estimatedMinutes` is computed by Cumulus from the builds' machines; Apple publishes no usage figure through its API. Only `billedMinutes` come from Apple, when the user imported a usage export. When `meta.isEstimate` is true, say "about" or "estimated", never present the figure as official.
- **To explain a failure**, run `cumulus build <build> --json` and read, in order: `issues` of type `ERROR` and `TEST_FAILURE`, then `failedTests`, then the `actions` that did not succeed. If `detailsAvailable` is false, follow the `hint`: the app has to be running to fetch a finished build's details, which it does once.
- **Do not retry a failed command blindly.** Read `error.code` and `error.suggestions` on standard error; see `references/output-contract.md`.
- **Start a build only when the user asked for one.** `cumulus run` (and the `start_build` tool) spends compute hours of the user's plan: never call it to retry on your own, and never in a loop. The app allows three launches by agents an hour per account (`RATE_LIMITED`, exit 8), and the key must be set to “Read + Build” in Cumulus (`NOT_ALLOWED`, exit 7). Apple's own refusal comes back as `REFUSED` with its words. At a terminal the command asks the person to confirm; pass `--yes` only when they already did. Then follow the build with `cumulus build <reference>`. If the launch ends in `INTERNAL` because Apple did not confirm it, or with an empty `buildRunID`, a build may well have started: do not launch again; run `cumulus refresh --wait --json`, then `cumulus builds --limit 1 --json`, and tell the user what you see.

## Typical flows

- *"Why did my last build fail?"* - `cumulus builds --failed --limit 1 --json`, then `cumulus build <reference> --json`.
- *"Is the build of the branch I just pushed done?"* - `cumulus refresh --wait --json`, then `cumulus builds --branch <name> --limit 1 --json` and match `commit.sha` to the commit.
- *"Is my pull request green?"* - `cumulus builds --pr <number> --limit 1 --json`: its `status`, then `cumulus build <reference> --json` if it failed.
- *"How much of the plan is left?"* - `cumulus status --json`: `usage.remainingMinutes`, `usage.resetDate`, `usage.projectedMinutes`.
- *"Which workflow eats the minutes?"* - `cumulus usage --by-workflow --json`.

## MCP instead of the command

The same answers are available as MCP tools (`get_status`, `list_apps`, `list_builds`, `get_build`, `list_workflows`, `get_usage`, `refresh`, `start_build`, `list_accounts`) by running `cumulus mcp`, a stdio server. When those tools are present in the session, use them rather than the shell: they return the same JSON. To register the server:

- Claude Code: `claude mcp add --scope user cumulus -- /Applications/Cumulus.app/Contents/Helpers/cumulus mcp`
- Codex: `codex mcp add cumulus -- /Applications/Cumulus.app/Contents/Helpers/cumulus mcp`

**Cumulus › Settings › Agents** gives the exact line for the installed app, and the configuration for Xcode's agents and Claude Desktop.

## References

- `references/output-contract.md`: the JSON shape of every answer, the error codes and the exit codes.
