# Lockpaw for Raycast

Control [Lockpaw](https://getlockpaw.com) — the macOS menu bar screen guard — directly from Raycast.

## Commands

| Command | Description |
|---------|-------------|
| **Lock Screen** | Activate the lock screen overlay (with confirmation) |
| **Unlock Screen** | Unlock via Touch ID |
| **Unlock with Password** | Unlock via macOS password |
| **Toggle Lock Screen** | Toggle lock on/off |

## Requirements

- [Lockpaw](https://getlockpaw.com) must be installed and running
- macOS 14 (Sonoma) or later

## How it works

The extension communicates with Lockpaw via its URL scheme (`lockpaw://`). All commands are instant, no-view actions that run in the background.
