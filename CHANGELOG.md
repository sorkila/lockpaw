# Changelog

## [1.1.1] - 2026-06-10

### Added

- Settings: one-click agent setup — connect Claude Code or Codex with a single button, with a proper loading state and inline error messages (Gemini still copies a snippet). The CLI installs automatically when you connect an agent.
- Lock screen: after the agent-ping glow finishes its breaths, a quiet "Your agent needs you" hint (with a faint resting glow) stays on screen until you unlock.

### Changed

- The agent-ping glow is now two slow breaths in saturated brand green, instead of one quick pale flash.
- The mouse pointer hides while the screen is locked — it reappears when you move the mouse and slips away again after a few seconds of stillness.
- The fallback Touch ID / password button is always visible on the lock screen (the "Tap for help" disclosure is gone).
- Lock-screen typography consolidated to the four roles of the design system (body / label / caption / mono).
- Removed the redundant "Lockpaw Settings" heading inside the Settings window.

### Fixed

- Agent notifications are cleared from Notification Center when you unlock — no stale "Your agent needs you" banners.
- `lockpaw install-hook` is now self-contained: it installs the `~/.local/bin/lockpaw` symlink itself and writes hooks that reference it by path, so agent pings no longer fail silently when `install-cli` was skipped or `~/.local/bin` isn't on PATH. Re-running upgrades older hook entries in place.
- `lockpaw install-hook claude` honors `$CLAUDE_CONFIG_DIR`, so multi-profile Claude Code setups get the hook in the right `settings.json`.

## [1.1.0] - 2026-06-09

### Added

- **Agent alerts** — the locked screen glows (and, optionally, a sound plays) when an AI coding agent needs you. Works with Claude Code, Codex, Gemini, or any CLI agent.
- A bundled `lockpaw` command-line tool (`ping`, `install-cli`, `install-hook`) so agents can signal Lockpaw.
- Settings: a "Play a sound on agent ping" toggle (off by default for shared spaces), a test-ping button, and one-click copy of the CLI command and per-agent hook snippets.
- Onboarding: a breathing mascot welcome and a step previewing agent alerts.

### Changed

- Unified motion across the app and website (shared easing curves), a smoother lock-screen mascot entrance, and cross-fading Settings sections.
- Restyled onboarding buttons and Settings segmented controls for one coherent look.

### Fixed

- Fixed the lock-screen mascot drifting upward every 12 seconds (the breathing animation no longer resets at its loop boundary).
- Agent notification banners now appear even when Lockpaw is the frontmost app.

## [1.0.9] - 2026-05-25

### Added

- Added a cat mascot option for the lock screen takeover.

### Changed

- Refined Settings with a cleaner macOS-native layout, consistent controls, improved light/dark appearance, and clearer release/update metadata.

## [1.0.8] - 2026-05-19

### Added

- Added a setting to require Touch ID or password when unlocking from the hotkey.
- Added a Buy Me a Coffee button in Settings.

### Fixed

- Fixed display sleep, screensaver, and macOS lock activating behind Lockpaw while the screen is covered.

## [1.0.4] - 2026-03-30

### Fixed

- Fixed "Check for Updates" button not responding. Sparkle's standard update dialogs don't surface in menu bar (LSUIElement) apps. Replaced with inline feedback: spinner while checking, green checkmark for up-to-date, version badge for available updates, and error display.
- Deferred Sparkle updater startup to `applicationDidFinishLaunching` to prevent silent initialization failures.

## [1.0.3] - 2026-03-30

### Fixed

- Fixed lock screen disappearing when connecting an external monitor during an active lock session. The screen change handler was calling `window.close()` on overlay windows that could still be mid-animation, causing a crash (`EXC_BAD_ACCESS` in `_NSWindowTransformAnimation dealloc`). Replaced with safe `orderOut` + `contentView = nil` cleanup.
- Fixed fake debounce in screen change handler. macOS fires multiple `didChangeScreenParametersNotification` events when a display connects — the old delay-based approach queued redundant handlers that could race. Now uses a proper cancellable debounce so only the last event in a burst triggers window recreation.

## [1.0.2] - 2025-05-25

- Initial public release with CI, DMG pipeline, Sparkle auto-updates, and Homebrew cask.
