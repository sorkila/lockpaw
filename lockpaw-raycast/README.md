# Lockpaw for Raycast

Control [Lockpaw](https://getlockpaw.com) — the macOS menu bar screen guard — directly from Raycast.

## Commands

| Command | Description |
|---------|-------------|
| **Lock Screen** | Activate the lock screen overlay |
| **Unlock Screen** | Unlock via Touch ID |
| **Unlock with Password** | Unlock via macOS password |
| **Toggle Lock Screen** | Toggle lock on/off |

## Assign custom hotkeys

The main reason to use this extension: Raycast lets you assign a hotkey to any command. Go to the extension settings and bind your preferred shortcuts — giving you additional global hotkeys beyond Lockpaw's built-in one.

For example, set `Ctrl+L` for lock and `Ctrl+U` for unlock, or use a single `Hyper+L` for toggle.

## Requirements

- [Lockpaw](https://getlockpaw.com) must be installed and running
- macOS 14 (Sonoma) or later

## How it works

The extension communicates with Lockpaw via its URL scheme (`lockpaw://`). All commands are instant, no-view actions that run in the background.
