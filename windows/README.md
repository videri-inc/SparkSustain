# SparkSustain for Windows

The Spark canvases near your desk follow your Windows laptop: awake at the
office = on at your chosen brightness; asleep, locked, away, or off desk
power = dark. Same behavior as the Mac version, adapted to Windows.

## Install

1. Unzip `SparkSustain-Windows.zip` into any folder.
2. Double-click **`Install-SparkSustain.bat`**. (If Windows SmartScreen warns,
   click *More info → Run anyway*.) The installer compiles SparkSustain on
   your PC using the compiler built into Windows — no downloads — and
   installs it to `%LOCALAPPDATA%\SparkSustain`.
3. A **sun icon** appears in your system tray (near the clock; click the `^`
   arrow if hidden) and the Setup Assistant opens.

## Setup

You need a Videri developer API key: log in at
<https://developer.videri.com/dashboard> → **API Keys** tab → create a key →
**copy it immediately** (shown once). The Setup Assistant handles the rest:
credentials (verified live), picking your Sparks from a searchable list,
the brightness-schedule takeover warning, office network capture, and the
optional desk power/dock requirement.

## Windows-specific notes

- **Sleep/wake detection**: reacts to system suspend/resume, session
  lock/unlock, and the display turning on/off.
- **Desk power**: instead of reading the power adapter's identity (a macOS
  feature), the Windows version anchors on a **device you pick** — your USB-C
  dock or desk monitor. "At my desk" = on AC power AND that device connected.
  Disconnecting it darkens the Sparks within ~3 seconds.
- **Global shortcut**: **Ctrl+Alt+S** toggles the Sparks from anywhere.
- **Start with Windows**: registered automatically at setup; toggle from the
  tray menu.
- Config and log live in `%APPDATA%\SparkSustain\`.

## Status

This Windows port is **feature-complete but young** — the Mac version has been
exercised against real Sparks; the Windows build compiles on first install and
any error is shown in the installer window. If something misbehaves, send
Jay (jay.leedy@videri.com) the text from the installer window or from
**View Log** in the tray menu.
