# Lockpaw for Raycast

Guard your Mac screen with a hotkey while AI agents keep running. Touch ID to unlock.

Control [Lockpaw](https://getlockpaw.com) — the macOS menu bar screen guard — directly from Raycast.

## Commands

| Command | Description |
|---------|-------------|
| **Guard Screen** | Let the watchdog guard your screen while agents work |
| **Call off Guard** | Unlock with Touch ID — the watchdog stands down |
| **Call off Guard (Password)** | Unlock with your Mac password |
| **Toggle Guard** | Toggle the watchdog on or off |

## Assign custom hotkeys

The main reason to use this extension: Raycast lets you assign a hotkey to any command. Go to the extension settings and bind your preferred shortcuts — giving you additional global hotkeys beyond Lockpaw's built-in one.

For example, set `Ctrl+L` to guard your screen and `Ctrl+U` to call off the guard.

## Deeplinks

Trigger commands from scripts, other extensions, or the terminal:

```
raycast://extensions/eriknielsen/lockpaw/lock
raycast://extensions/eriknielsen/lockpaw/unlock
raycast://extensions/eriknielsen/lockpaw/unlock-password
raycast://extensions/eriknielsen/lockpaw/toggle
```

## Requirements

- [Lockpaw](https://getlockpaw.com) must be installed and running
- macOS 14 (Sonoma) or later

## How it works

The extension communicates with Lockpaw via its URL scheme (`lockpaw://`). All commands are instant, no-view actions that run in the background.
