# QuotaWise

**Local AI usage intelligence for macOS.**

QuotaWise is a native macOS menu-bar app for people who use Codex and Claude
Code throughout the day. It makes the practical questions easy to answer:
what is left, when does it reset, and where did the work go?

## Why QuotaWise

AI usage limits are easy to lose track of while you are in the middle of a
task. QuotaWise keeps a clear, always-available view of your available usage
alongside a deeper picture of recent activity—without turning your work into a
cloud dashboard.

## Features

- **Menu-bar status at a glance** — See remaining usage, reset timing, compact
  history graphs, or remaining-usage bars without leaving your current task.
- **QuotaWise Studio** — Explore usage over 5-hour, daily, weekly, and monthly
  views, with trends, reset markers, model summaries, and project breakdowns.
- **Codex and Claude Code in one place** — Switch between providers while
  keeping the same calm, consistent view of your usage.
- **Honest signals** — QuotaWise clearly distinguishes values it can confirm
  from values it has estimated from available local history.
- **Notifications and limits** — Receive reset notifications, or set optional
  thresholds that can notify you, pause active provider work, or quit a
  provider when a chosen limit is reached.
- **A configurable menu-bar icon** — Choose the providers, periods, colours,
  and chart/bar treatments that make sense for your workflow.

## Private by design

QuotaWise works with usage information available on your Mac and processes it
locally. It does not operate a QuotaWise account, sync service, or analytics
backend, and it does not upload your prompts, responses, project names, or
usage history to one.

Some provider data can be unavailable or incomplete. When that happens,
QuotaWise favours a clearly labelled estimate or an unavailable state over a
misleadingly precise answer.

## Getting started

### Requirements

- macOS 15 or later
- Xcode 16 / Swift 6 or later

### Run from source

```sh
swift run QuotaWise
```

The app launches as a menu-bar accessory. Open **QuotaWise Studio** from its
menu-bar panel for the full desktop view.

### Build and test

```sh
swift build
swift test
swift build -c release
```

To create and install a signed local application bundle, provide your own
Apple development signing identity:

```sh
QUOTAWISE_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/install-app-bundle
```

### Release distribution

For the Developer ID signing, notarization, GitHub Release, and Homebrew Cask
workflow, see [the macOS release guide](docs/releasing-macos.md). Release
artifacts are generated under `build/release/` and are intentionally not
committed to this repository.

## Project status

QuotaWise is actively evolving. Provider integrations and the information
available from them can change, so feedback, bug reports, and contributions
are welcome.

## Licence

QuotaWise is available under the [MIT License](LICENSE).
