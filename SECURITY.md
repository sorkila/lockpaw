# Security Policy

Lockpaw is a screen guard — it blocks input and covers your displays, but it is **not** a replacement for the macOS lock screen and does not protect against someone with physical access to an unlocked user session (no FileVault-level protection, no protection against `ssh` access or closing the app from another session). Please keep that threat model in mind when assessing impact.

## Supported versions

Only the latest release receives security fixes. Update via Sparkle (Settings → check for updates), [GitHub Releases](https://github.com/sorkila/lockpaw/releases), or `brew upgrade --cask lockpaw`.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use [GitHub private vulnerability reporting](https://github.com/sorkila/lockpaw/security/advisories/new) — it goes straight to the maintainer and stays private until a fix ships.

You can expect an initial response within a few days. If the report is valid, a fix will be released as soon as practical and you'll be credited in the release notes (unless you prefer otherwise).

## Scope

Reports especially welcome for:

- Lock bypass — interacting with apps/system while Lockpaw is locked (input not blocked, overlay dismissible, etc.)
- Authentication bypass — unlocking without the hotkey or Touch ID/password
- Anything that makes the `lockpaw` CLI or its agent hooks execute unintended commands
- The lid-closed helper (below)

## The lid-closed helper

Lid-closed mode (off by default) installs one privileged component: `LockpawHelper`, a LaunchDaemon that runs as root once you allow it in System Settings → General → Login Items. It exists because nothing short of `pmset -a disablesleep` keeps a lid-closed Mac with no external display awake, and that needs root.

What it can do, and what limits it:

- **One lever.** Its XPC interface sets system sleep on or off (`pmset -a disablesleep 1|0`) and reports the current state. Nothing else: no arbitrary commands, no file access, no network.
- **Only Lockpaw may call it.** Every connection must satisfy a code-signing requirement anchored to Lockpaw's Developer ID team and its exact bundle identifiers. Unsigned or ad-hoc builds can't use it at all.
- **Sleep always comes back.** The helper clears `disablesleep` when it starts (at boot), when it is stopped (shutdown, or turning the setting off, which unregisters it), and a minute after the app disconnects while sleep is held (crash, force quit). The app asks for the block only while the screen is locked, and lets go when the Mac runs hot (`thermalState` serious or worse) or the battery reaches 20%.
- **Removal.** Turn off "Stay awake with the lid closed" in Settings, or remove Lockpaw in Login Items.

Issues in the helper — a way to reach it from another process, to run it against a non-Lockpaw caller, or a path that leaves sleep disabled — are in scope and welcome.
