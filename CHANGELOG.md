# Changelog

## [1.0.3] - 2026-03-30

### Fixed

- Fixed lock screen disappearing when connecting an external monitor during an active lock session. The screen change handler was calling `window.close()` on overlay windows that could still be mid-animation, causing a crash (`EXC_BAD_ACCESS` in `_NSWindowTransformAnimation dealloc`). Replaced with safe `orderOut` + `contentView = nil` cleanup.
- Fixed fake debounce in screen change handler. macOS fires multiple `didChangeScreenParametersNotification` events when a display connects — the old delay-based approach queued redundant handlers that could race. Now uses a proper cancellable debounce so only the last event in a burst triggers window recreation.

## [1.0.2] - 2025-05-25

- Initial public release with CI, DMG pipeline, Sparkle auto-updates, and Homebrew cask.
