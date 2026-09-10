# SparkSustain

Keeps the Videri Spark displays near your desk in sync with your laptop:
awake at your desk = on at your chosen brightness; asleep, locked, away
from the office network, or off desk power = dark. Native menu bar app on
macOS, system tray app on Windows, driven entirely by Videri's public
developer APIs — nothing is installed on the Sparks.

## Install

Grab the latest release from the Releases page:
- **Mac**: unzip `SparkSustain-Mac-<version>.zip`, right-click
  `Install SparkSustain.command` → Open. The Setup Assistant handles the rest.
- **Windows**: unzip `SparkSustain-Windows-<version>.zip`, double-click
  `Install-SparkSustain.bat` (compiles on your PC — no downloads).

You'll need a Videri developer API key from
https://developer.videri.com/dashboard (API Keys tab).

## Auto-updates

Installed apps poll `updates/manifest.json` on the main branch every 4 hours
and self-update when the version differs (upgrades and rollbacks alike),
verifying the release asset's SHA-256 before installing.

**Publishing** (maintainer): bump the version in `build.sh` (and
`AppInfo.Version` in `windows/SparkSustain.cs`), then:

    ./publish.sh "release notes"

**Rolling back**: edit `updates/manifest.json` to point at an earlier
release's assets and push.

## Layout

- `Sources/` — macOS app (Swift, single file) + Control Center widget
- `windows/` — Windows app (C#, single file) + self-compiling installer
- `build.sh` — macOS build (also embeds the widget when Xcode is present)
- `publish.sh` — cut a GitHub release + update the manifest
- `dist/SparkSustain-Installer/` — Mac installer script and docs
