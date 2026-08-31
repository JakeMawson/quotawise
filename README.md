# QuotaWise

Current local release: **1.1.0 (build 2)**.

QuotaWise is an open-source, native macOS menu-bar utility and desktop analytics app for Codex and Claude Code.

The menu-bar panel answers the immediate questions: how much of each reported usage window remains, when it resets, whether the value is exact or estimated, and how many API-equivalent credits the last 30 days represent. The full QuotaWise Studio adds provider switching, project search, 5-hour/1-day/7-day/30-day ranges, reset markers, shaded usage plots, model cost bars, and a daily model/project ledger.

## Data sources

All processing happens on this Mac.

* Live Codex limits: the local, authenticated `codex app-server` protocol (`account/rateLimits/read`). It natively supports missing rolling windows and multiple limit IDs, including a separate Spark bucket when the account exposes one.
* Codex history: the latest 35 days from `~/.codex/sessions` and `~/.codex/archived_sessions`. Cumulative token counters are converted into non-negative event deltas and grouped by the recorded model and project. A versioned per-file index caps raw event retention, compacts high-cardinality older history into hourly totals, and keeps a checkpoint so growing sessions resume from their last byte offset without retaining expired events.
* Claude Code history: a rolling 63-day window from `~/.claude/projects`. Streamed copies are deduplicated by Claude message ID; high-cardinality older history is compacted with the same bounded index policy. Project path, model, input/output/cache usage, and explicit limit-reset messages are retained.
* Claude quota: exact subscription utilization is read in priority order from Claude Code's authenticated OAuth usage response, compatible exact usage caches/status-line output, and Claude Desktop's `~/Library/Application Support/Claude/plan-usage-history.json`. The desktop file is written from Claude's own `/api/organizations/{org}/usage` response. Fresh data is labelled `LIVE · EXACT`; a last-known exact file sample remains usable for up to 24 hours as `EXACT · CACHED`, then transcript-derived estimates are the final fallback.
* Reset history: provider-written Claude boundaries and any tracked limit whose remaining percentage increases between persisted observations are exact. The app timestamps an observed rollover midway between those two observations, so it also detects resets that occur while it is closed. Before the first actual weekly seam, it draws provisional dashed seven-day seams; when the first actual seam arrives, it re-anchors the historical estimates backward from that seam once and then freezes them. From the newest known primary weekly seam, it also fills each elapsed seven-day interval forward only when no weekly seam is already there; a later exact observation replaces that scheduled estimate. App-owned snapshots and frozen anchors are stored in `~/Library/Application Support/QuotaWise/limit-snapshots.json`, outside the app bundle so normal app updates retain them.

The app does not upload prompts, responses, account identifiers, project names, or usage data.

## Exact values and estimates

Codex limit percentages are exact when the local App Server responds. If it is unavailable, the newest local Codex session snapshot is used.

Claude Code's local history does not expose a continuously updated account percentage. The app therefore:

* treats provider-written session/weekly reset messages as exact reset boundaries;
* calibrates a 5-hour estimate from prior completed limit-hit sessions, or from the 90th percentile of prior completed 5-hour windows;
* estimates weekly progress against prior active calendar weeks when no exact weekly boundary exists; and
* labels every inferred percentage and boundary as `Estimated`, while leaving the limit unavailable until enough prior activity exists to establish a baseline.

Optional limits remain optional. If OpenAI removes a 5-hour window, the app shows the weekly bucket without fabricating a 5-hour percentage. If the provider restores it later, it appears automatically from the same nullable protocol model.

## Credits and API-equivalent cost

One credit is defined as **USD $0.01** of estimated API-equivalent usage. This matches Anthropic's documented Claude Consumption Unit conversion and provides one comparable unit across both providers.

These values answer “what would these recorded tokens roughly cost through the provider API?” They are not subscription charges, invoices, or a claim that subscription quota is token-priced. Current known models use bundled official per-token rates; unknown or non-API models use an explicitly estimated nearest-family mapping. Priority/fast service tiers apply a premium where recorded.

## Run

Requirements: macOS 15 or later and Xcode 16/Swift 6 or later.

```sh
swift run QuotaWise
```

To build and install the standard local app bundle used by Launch Services and the terminal helper, provide the signing identity for your own Apple development certificate:

```sh
QUOTAWISE_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/install-app-bundle
```

The installed bundle lives at `/Applications/QuotaWise.app`, uses launcher bundle identifier `com.jakemawson.quotawise.launcher`, and contains the resident `com.jakemawson.quotawise.menuagent` login item plus the native `codexusage-native` report executable. The interactive `codexusage` shell helper consumes that local executable and does not need npm or network access. It reports the same indexed 35-day local-history window as the app, which spans the current and prior subscription periods without rescanning an unbounded archive on every shell invocation. Project filters now match the native event project label/path directly and do not create temporary copied session homes. Scanner cache version 4 uses bounded direct metadata batches, retries failed files instead of caching them as empty, preserves exact event timestamps for rolling ranges and calendar days, uses high-water deltas so stale concurrent snapshots cannot inflate totals, and retains recorded per-event service-tier changes.

The app launches as a menu-bar accessory. Choose **Open QuotaWise Studio** in the panel for the full desktop window.

Press **Command-comma** to configure the menu-bar icon. The live icon has independent **Top** and **Bottom** layers; each can show Codex or Claude Code as either a locally scaled usage graph or a remaining-usage bar for the latest 5h or week. Each layer defaults to **Auto** (light in dark mode, dark in light mode) and can independently use its provider colour instead—blue for Codex or yellow for Claude Code. Turning the live icon off restores the classic chart icon and percentage label.

Settings also includes quota-reset notifications. Choose a standard macOS notification or a persistent alert that remains visible until dismissed. QuotaWise keeps a baseline for each provider's primary tracked quota windows and notifies only when a previously used window returns to 100% remaining; the first observation and repeated full refreshes do not create duplicate alerts.

For a weekly limit set to **Pause active threads**, QuotaWise sends `SIGSTOP` only to provider processes that are live at the trigger moment, then stores each PID with its process-start identity outside the app bundle. The limit control becomes **Paused · click to resume**. Resume sends `SIGCONT` only to those exact still-matching processes; exited or PID-reused processes are discarded rather than signalled. This pause record survives normal app updates and restarts.

On a first launch with a very large history, the rolling index may take several minutes in the background; live Codex limits appear first. Later launches use the compact index, skip no-op cache writes, and resume growing sessions from saved checkpoints.

## Build and test

```sh
swift build
swift test
swift build -c release
Scripts/build-app-bundle release
```

## Licence

QuotaWise is available under the [MIT License](LICENSE).

## Current limitations

* Claude exact quota data is only available while an authenticated Claude usage response, compatible cache, or Claude Desktop plan-usage history is present. A file sample older than 24 hours falls back to a clearly labelled local-history estimate.
* API prices are bundled at build time; models without a public API price use a clearly marked family estimate.
* Project names use the Codex Desktop label registry where available and fall back to the folder name.
* Historical weekly seams remain estimates until the first exact provider/observed boundary is available. The first exact weekly seam re-anchors the prior seven-day estimates once; QuotaWise does not rewrite that frozen backfill afterward. A separate forward schedule fills only elapsed weekly positions after the newest primary seam, skipping any position that already has a nearby weekly line.
