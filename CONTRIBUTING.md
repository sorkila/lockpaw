# Contributing to Lockpaw

Thanks for your interest in contributing to Lockpaw. This guide will help you
get started.

## Quick start

Requirements: macOS 14+, Xcode 16+, XcodeGen.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug build
```

After each rebuild, reset TCC (the binary signature changes invalidate
accessibility permission):

```bash
tccutil reset Accessibility com.eriknielsen.lockpaw
```

## Running tests

```bash
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug test
```

There are 34 unit tests covering LockState transitions, Constants formatting,
and HotkeyConfig conflict detection. All tests must pass before submitting a PR.

## Pull request expectations

- Keep PRs focused: one logical change per PR.
- Include tests for any new logic.
- Follow the existing code style and conventions.
- Make sure all tests pass locally before opening a PR.
- Write a clear description of what your change does and why.

## Architecture overview

The project structure is documented in the README. A few key decisions worth
knowing before diving in:

- **State machine** -- LockState defines explicit transitions:
  `.unlocked -> .locking -> .locked -> .unlocking`.
- **CGEventTap on a dedicated background thread** -- Carbon
  RegisterEventHotKey is unreliable in menu bar-only apps, so HotkeyManager
  runs its own CFRunLoop on a background thread.
- **Toggle observer in LockController.init()** -- not in SwiftUI's
  `.onReceive`, because MenuBarExtra content is lazily initialized.
- **All timing constants in Constants.Timing** and all notifications in
  `Notifications.swift` -- no magic numbers or scattered string literals.
- **@MainActor on controllers** with `Task.detached` for LAContext to avoid
  MainActor deadlock.

See the CLAUDE.md file for the full list of architecture decisions.

## What makes a good contribution

Good candidates for contribution:

- Bug fixes with a clear reproduction case.
- Additional test coverage.
- Accessibility improvements.
- Performance or reliability improvements.

The design of Lockpaw is intentionally minimal and restrained. If you are
considering UI changes or new features, please open an issue first to discuss
the approach before writing code.

## Reporting issues

If you find a bug, please open a GitHub issue with:

- macOS version and hardware (Intel or Apple Silicon).
- Steps to reproduce.
- Expected vs. actual behavior.
