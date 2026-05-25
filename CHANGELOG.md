# Changelog

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
