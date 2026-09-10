# SparkSustain — Setup Guide

SparkSustain is a tiny macOS menu bar app that ties the Spark canvases around your
desk to your MacBook. When your Mac is awake **at the office**, your Sparks run
at 70% brightness. When your Mac sleeps — or you leave the office — they drop
to 0% and stay dark until you're back.

Everything runs through Videri's own developer APIs. Nothing is installed on
the Sparks themselves.

Setup is three steps. The app's built-in **Setup Assistant** does the rest.

---

## 1. Install

1. Unzip `SparkSustain-Installer.zip` and open the folder.
2. **Right-click `Install SparkSustain.command` → Open → Open.**
   (Right-click is needed the first time because the installer arrived as a
   download; it copies SparkSustain to `~/Applications`, clears the quarantine
   flag, and launches it.)
3. A **sun icon** appears in your menu bar and the Setup Assistant opens.

## 2. Get your API key

The one thing the app can't do for you:

1. Go to **https://developer.videri.com/dashboard** (the Setup Assistant has a
   button that opens it) and log in with your Videri developer account. No
   account? Ask the platform team to enable developer access for you.
2. In the dashboard, open the **API Keys** tab → create a new key.
3. **Copy the full key immediately** — Videri shows it only once.

## 3. Follow the Setup Assistant

The assistant walks you through everything else:

- **Pair your API key** — paste your developer username, password, and the
  API key. The app verifies them against Videri right away, so typos are
  caught on the spot. Credentials are stored only on your Mac, in a file
  readable only by you.
- **Pick your Sparks** — it fetches every canvas your account can see and
  shows a searchable checklist (online canvases first). Check the ones near
  your desk.
- **Remember the office network** — if you're at the office, one click
  records the network so brightness only comes up when your Mac is actually
  there. Not at the office? Skip it and use **Set Current Network as Office**
  from the menu later.
- **Start at login + first sync** — the app registers itself as a login item
  and immediately syncs your Sparks to your Mac's current state.

Closed it early, or want to redo anything? Menu bar icon →
**Run Setup Assistant…** — it's safe to re-run any time.

---

## How the automation behaves

| Your MacBook | At the office? | Your Sparks |
|---|---|---|
| Awake | Yes | 70% |
| Awake | No | 0% — stays dark |
| Asleep / lid closed | anywhere | 0% |

Menu bar icon at a glance: ☀️ awake at office · 🚫 awake but away · 🌙 asleep.
Automation can be paused any time from the menu, and you can trigger either
brightness manually with **Set Wake/Sleep Brightness Now**. Pick your preferred
wake level (10–100%) under **Wake Brightness** in the menu, and toggle all your
Sparks on/off from anywhere with the global shortcut **⌃⌥S**.

## Troubleshooting

- **"Couldn't sign in" during setup** — recheck username, password, and API
  key; keys expire if you set an expiry date when creating them.
- **Commands succeed but nothing changes** — make sure the right Sparks are
  checked (Run Setup Assistant… to adjust) and that they show as `online`.
- **Log file** — menu → **View Log** (`~/Library/Logs/SparkSustain.log`) shows
  every event and API response.
- **macOS blocks the app itself** — System Settings → Privacy & Security →
  "Open Anyway", or re-run the installer.
