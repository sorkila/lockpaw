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
