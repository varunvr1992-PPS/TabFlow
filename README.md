# TabFlow ⚡

**Every window, one keystroke away.**

macOS's ⌘Tab switches *apps*. I wanted to switch *windows*: all of them, across every Desktop,
with live previews, without reaching for the mouse. So I vibecoded one.

TabFlow is a tiny native Mac app: Swift + AppKit, no Xcode, no dependencies, one build script.
It's my first app, built through a lot of back-and-forth with an AI pair programmer.

Hit **⌥Tab**, tap through your windows, let go. That's it.

## Get it

1. Download `TabFlow-x.y.zip` from [**Releases**](https://github.com/varunvr1992-PPS/TabFlow/releases/latest).
2. Unzip and drag **TabFlow.app** into `/Applications`.
3. Open it and grant **Accessibility** (and **Screen Recording** for live thumbnails) when asked.

Works on macOS 13 (Ventura) or newer, on Apple Silicon and Intel.

It isn't notarized by Apple (that costs $99/yr), so macOS will say "unidentified developer" the
first time. Right-click the app → **Open** → **Open**, or run:

```bash
xattr -cr /Applications/TabFlow.app
```

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh --install     # compiles, bundles, copies to /Applications, launches
./build.sh               # just builds build/TabFlow.app
UNIVERSAL=1 ./build.sh   # Apple Silicon + Intel build (what Releases ship)
```

After granting permissions in System Settings → Privacy & Security, use *Restart TabFlow* on the
Permissions tab.

> Tip: `build.sh` signs with a self-signed code-signing certificate named **"TabFlow Local Signing"**
> if your keychain has one, so permissions survive rebuilds. Without it, it falls back to ad-hoc
> signing, and each rebuild needs TabFlow removed and re-added in Accessibility.

## Default shortcuts

| Shortcut | Shows |
|---|---|
| **⌥ Tab** | every window, all apps, all Desktops (most-recent first) |
| **⌘ `** (key above Tab — ANSI and ISO keyboards) | windows of the front app only |
| **⌘ Tab** | off by default — turn on to replace the macOS app switcher |

All three are editable (modifiers, key, and which apps/Desktops/screens each one shows).

## While the switcher is open

| Key | Action |
|---|---|
| Tab / ⇧Tab, arrows | move selection |
| release modifier | switch to selected window |
| 1–9 | jump straight to that window |
| Q / W / M / H / F | quit app / close window / minimize / hide app / full screen |
| Space or / | search mode — release keys and type to filter, ↩ to open |
| Esc | cancel |
| mouse | hover selects, click switches, × closes |

## Features

- Windows from all Desktops (Spaces), minimized windows, hidden apps, full-screen windows, optional window-less apps
- Three styles (thumbnails, app icons, list), three sizes, light/dark/system theme
- Sort by recently used, app name, or Desktop
- Shows on the screen with the mouse / active window / main screen
- Quick tap = instant flip to previous window (configurable show delay)
- Status badges (Minimized, Hidden, Desktop 2…), number hints, hint bar
- Exclusion lists: apps never shown; apps where shortcuts are turned off (games, VMs)
- Launch at login, pause, menu-bar search

## Troubleshooting

- Log: `~/Library/Logs/TabFlow.log` (launch, permission state, shortcut presses, switches).
- Test hooks (off by default): `defaults write local.tabflow.app debugCommands -bool YES`, restart
  TabFlow, then post the distributed notification `local.tabflow.debug` with a command such as
  `dump`, `open 0`, `next`, `key <keycode> <char>`, `state`, `commit`, `cancel`, `axdebug <App Name>`.

## Layout

`Sources/TabFlow/` — `WindowStore` (window discovery + recency), `HotkeyManager` (keyboard hook),
`SwitcherController` (switcher state), `SwitcherPanel` (UI), `SettingsView` (SwiftUI settings),
`PrivateAPIs` (SkyLight/AX helpers for other-Desktop windows, thumbnails, focusing).
