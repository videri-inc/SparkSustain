# SparkSustain — Release Notes

## Version 1.12 — October 24, 2026

### Fixed: screens waking on their own overnight
- macOS performs hundreds of **dark wakes** a day — maintenance wakes where
  the machine briefly runs with the display still off (Power Nap, network
  upkeep, backups). On one machine: 920 dark wakes and 2,317 maintenance
  wakes in three days, against 10 real wakes.
- `didWake` fires for those exactly as it does for a real wake, and
  SparkSustain believed it — turning the Sparks on at 3am with the lid shut.
- The app now asks the window server whether the displays are genuinely lit
  rather than inferring it from a notification, and re-checks every three
  seconds, so a missed or misleading notification can no longer strand it in
  the wrong state.
- Windows: the same flaw on modern-standby resume is fixed the same way —
  resume no longer asserts the displays are on.
- Every state change now records *why* in the log
  (`State 70% → 0% (screens slept)`), which is what made this diagnosable.

## Version 1.11 — October 21, 2026

- Support now points at GitHub Issues rather than a personal email address.
- The app's bundle identifier drops its personal segment:
  `com.videri.jay.sparksustain` becomes `com.videri.sparksustain`.
  **After updating, re-tick "Start at Login" from the menu** — macOS keys
  login items to the bundle identifier, so the old registration doesn't
  carry over. Your settings, credentials and Spark selections are kept.

## Version 1.10 — October 21, 2026

- **Share SparkSustain** added to the menu: copy a ready-to-send invite
  message, copy the download link, or open the download page.
- **Quieter and kinder when offline.** The app no longer fires commands at
  the API when the machine has no network route — it holds the intended
  state and applies it the moment connectivity returns. A month of logs was
  dominated by timeouts from the laptop being asleep or away.
- **Recover from a stale token on 403 as well as 401.** One 403 in a month
  of running traced to a platform auth hiccup; the app now re-authenticates
  instead of waiting for the next cycle.
- **Background update checks now log their failures** instead of failing
  silently, so a fleet that has quietly stopped updating is diagnosable.

## Version 1.9 — September 24, 2026

- **New menu bar / tray icon.** The old sun glyph was the same SF Symbol most
  weather apps use. It's now the Videri V mark from the app icon — solid when
  your Sparks are lit, dimmed when they're dark. Hover for the reason.
- **Fixed: the app could refuse to launch after a macOS upgrade.** Builds had
  no pinned deployment target, so the compiler inferred one from the build
  machine — which could land above the macOS version being shipped to, and
  LaunchServices then rejected the app (error -10825). The target is now
  pinned to macOS 13, matching what the bundle advertises.

## Version 1.8 — September 14, 2026

- Update hosting moved to the Videri organization repo
  (github.com/videri-inc/SparkSustain). Installs poll that repo's update
  manifest; release zips are GitHub Release assets, verified by SHA-256
  before installing.

## Version 1.7 — September 10, 2026

### Auto-update now hosted on GitHub
- Updates moved from the OneDrive-synced folder to GitHub: each app polls
  the repo's update manifest over HTTPS on launch and every 4 hours — no
  folder syncing required on any machine.
- Release zips are GitHub Release assets; every install verifies the
  SHA-256 from the manifest before installing. Rollback remains a
  one-file change (repoint the manifest at an earlier release).
- Fixed a v1.6 Windows compile error (missing version constant).

## Version 1.6 — August 27, 2026

### Auto-update via SharePoint (Option A)
- SparkSustain now updates itself from the shared **SparkSustain-Updates**
  SharePoint folder (synced through OneDrive). Each app locates the synced
  folder automatically, checks `manifest.json` on launch and every 4 hours,
  verifies the download's SHA-256, installs, and relaunches.
- **Rollback built in**: the updater matches on *different*, not *newer* —
  pointing the manifest back at an archived version rolls the whole fleet
  back within hours. All versioned zips stay in the folder.
- New menu items: **Check for Updates Now**, the running version number, and
  **Locate Update Folder…** when the synced folder can't be found.
- Publishing is one command for the maintainer (`publish.sh`), which builds
  both platforms, hashes them, and writes the manifest.
- Requirement per user: sync the SparkSustain-Updates folder once
  (SharePoint → Sync, or Add shortcut to OneDrive).

## Version 1.5 — August 27, 2026

### Verified desk signatures (Sales Engineering feedback)
- A Windows tester found that anchoring "at my desk" to a monitor didn't
  react when the monitor was merely powered off — HDMI/DisplayPort screens
  can stay registered with Windows while off, so only unplugging the cable
  changed anything.
- Setup now **verifies your desk signature live**: after you choose your
  desk power source (Mac) or desk device (Windows), the assistant asks you
  to power it off/unplug it, confirms SparkSustain noticed, then confirms
  it sees the reconnect. A signature that doesn't track your presence is
  caught on the spot, with guidance to pick a better anchor.
- Windows: the device picker now lists USB devices first and warns against
  [Monitor] entries; device detection also requires the device to be fully
  healthy, so power-off states register as absent wherever drivers report
  them.
- Mac behavior is unchanged in principle — it reads the actual power source
  identity — and gains the same verification step for confidence.

## Version 1.4 — August 24, 2026

### Manual holds (fixes automation overriding ad-hoc commands)
- Previously, a manual "Set Sleep/Wake Brightness Now" was undone within
  seconds by the automation rules. Manual commands are now **holds**: pick a
  duration — 30 minutes, 1 hour, 2 hours, until end of day, or until you
  resume automation — and the state is pinned for that long.
- While a hold is active, automation **enforces the hold** (re-asserting it,
  surviving laptop sleep and network changes) instead of fighting it, then
  resumes its own rules when the hold expires.
- The menu shows the active hold ("Manual hold: 0% until 3:45 PM") with a
  **Resume Automation Now** item to end it early.
- The keyboard toggle (Ctrl+Alt+S on Windows, ⌃⌥S on Mac) and the Control
  Center toggle hold their state for a default 60 minutes (configurable via
  default_override_minutes).

## Version 1.3 — August 24, 2026

### Workspace scoping with sub-workspace tree (Sales Engineering feedback)
- Accounts with access to many Videri workspaces were seeing every workspace's
  canvases in the Spark picker. The Setup Assistant now shows your accessible
  workspaces as a **tree — including nested sub-workspaces, however deep** —
  and asks you to check what's yours. No IDs to type.
- Check a workspace to include everything inside it, or check just the
  sub-workspace(s) you need (e.g. your own office inside a large tenant).
  Multiple selections across workspaces are supported.
- SparkSustain will only show, and only ever send commands to, displays under
  what you checked — it cannot touch anyone else's Sparks.
- Re-run the Setup Assistant any time to change the selection.
- Available on both macOS and Windows.

## Version 1.2 — August 24, 2026

### Brightness schedule takeover
- When you confirm your Spark selection (and once on first launch for existing
  setups), SparkSustain warns you and then **permanently deletes any existing
  brightness schedules** on the displays it manages from the Videri platform,
  so platform schedules can no longer override the app's on/off control.
  Other displays are not affected.
- Immediately after takeover, managed displays are set to their new **default
  state: 0% brightness / display off**. They only light up while your MacBook
  meets the wake conditions.

### Perpetual state enforcement
- The wake/sleep state SparkSustain decides on is now standing law: in
  addition to reacting instantly to sleep/wake, network, and power events,
  the app **re-asserts the desired state every 10 minutes**. A Spark that
  rebooted, missed a command while offline, or was adjusted in the portal is
  pulled back to SparkSustain's state automatically.
- Displays remain in their applied state until the MacBook is connected to
  the correct power source and in a defined wake state — there is no path
  back to "on" except meeting the conditions.

### Desk power source requirement
- New optional wake condition: the Mac must be **drawing power from your
  captured desk source** (e.g. a USB-C monitor or dock, identified by its
  USB vendor/product and wattage). On battery, MagSafe, or any other
  charger the Sparks stay dark — even on the office network.
- **Disconnecting the desk power source darkens the Sparks within ~3
  seconds**; reconnecting restores them just as fast. Transitions are logged.
- The Setup Assistant now includes a desk-power step: if you're plugged in,
  it shows the detected source and offers to require it; if not, you can
  connect it and click **Detect Now**, or decide later via
  **Require Current Power Source (Desk)** in the menu.

### Setup Assistant
- New steps: brightness-schedule takeover warning and desk power
  confirmation, in addition to credential pairing (verified live),
  Spark selection, office network capture, login item, and first sync.

## Version 1.1 — August 22, 2026

- Renamed SparkSync → SparkSustain; new icon (Videri V, sync arrows, power badge).
- Setup Assistant: guided first-run — paste API key/credentials with live
  validation, searchable multi-tenant canvas picker, office network capture.
- Office-network condition: wake brightness only on the captured subnet.
- Verified device control: real backlight via Videri's command API; panel
  off for true dark screens; multi-tenant command routing.
- Wake Brightness menu (10–100%), global toggle shortcut **⌃⌥S**,
  Help menu opening the bundled manual, Control Center widget
  (gallery appearance pending an Apple macOS Tahoe bug fix).
- Distribution: DMG installer with app icon, bundled Setup Guide and Manual.
