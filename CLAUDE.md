# Lockpaw

macOS menu bar screen guard. Lock/unlock with a hotkey. Dog mascot.

## Quick reference

- **App name:** Lockpaw
- **Bundle ID:** `com.eriknielsen.lockpaw`
- **URL scheme:** `lockpaw://`
- **Website:** getlockpaw.com
- **Repo:** git@github.com:sorkila/lockpaw.git
- **Requires:** macOS 14+, Xcode 16+, XcodeGen, create-dmg
- **Dependencies:** Sparkle (SPM, auto-updates)

## Build

```bash
xcodegen generate
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug build
```

After each rebuild, reset TCC (binary signature changes invalidate accessibility permission):
```bash
tccutil reset Accessibility com.eriknielsen.lockpaw
```

## Test

```bash
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug test
```

34 unit tests covering LockState transitions, Constants formatting, and HotkeyConfig conflict detection.

## Release

```bash
./scripts/build-release.sh
```

Builds unsigned → copies to `/tmp` for signing → signs with Developer ID → creates branded DMG (via `create-dmg`) → notarizes → staples → sets custom DMG file icon. Output: `build/Lockpaw.dmg`. Requires `lockpaw-notarize` keychain profile (already stored) and `create-dmg` (`brew install create-dmg`).

**Signing:** The build script copies the app to `/tmp` via `ditto --norsrc` before signing. This is required because the repo lives in iCloud-synced `~/Documents` which adds irremovable `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P` xattrs that cause codesign to fail with "resource fork, Finder information, or similar detritus not allowed". Signing is done inside-out with `--timestamp`: XPC service binaries → XPC bundles → Autoupdate → Updater.app binary → Updater.app → Sparkle.framework → main app.

**DMG assets** in `scripts/`:
- `dmg-background.png` / `dmg-background@2x.png` — dark background with teal arrow (660x400 / 1320x800)
- `dmg-volume-icon.icns` — dog mascot icon shown on mounted volume and DMG file in Finder

## Project structure

```
Lockpaw/
├── LockpawApp.swift                Entry point, MenuBarExtra, AppDelegate, onboarding
├── Controllers/
│   ├── LockController.swift        State machine, lock/unlock orchestration, toggle observer
│   ├── Authenticator.swift         LAContext (Touch ID / password fallback)
│   ├── InputBlocker.swift          CGEventTap — blocks keyboard/scroll while locked
│   ├── HotkeyManager.swift         CGEventTap on dedicated background thread — global hotkey
│   ├── OverlayWindowManager.swift  NSWindow per screen at CGShieldingWindowLevel
│   └── SleepPreventer.swift        IOKit sleep assertion
├── Models/
│   ├── LockState.swift             .unlocked → .locking → .locked → .unlocking
│   └── HotkeyConfig.swift          Centralized hotkey UserDefaults + system conflict detection
├── Views/
│   ├── LockScreenView.swift        Lock screen — dog, message, time, fallback auth
│   ├── MenuBarView.swift           Menu bar dropdown
│   ├── SettingsView.swift          Native Form, hotkey recorder, appearance, Sparkle updates
│   └── OnboardingView.swift        4 steps: welcome, hotkey, accessibility, menu bar
├── Utilities/
│   ├── Constants.swift             App constants, Timing enum, animation presets, formatting
│   ├── Notifications.swift         All Notification.Name in one place
│   └── AccessibilityChecker.swift  AXIsProcessTrusted + System Settings opener
├── Resources/
│   └── Assets.xcassets             App icon, mascot, menu bar icon (template), colors
└── LockpawTests/
    ├── LockStateTests.swift        State transition validation (16 tests)
    ├── ConstantsTests.swift         Time formatting (11 tests)
    └── HotkeyConfigTests.swift      System shortcut conflict detection (7 tests)
```

## Repo-level directories

- **`assets/`** — `demo.gif` hero GIF for README (lock/unlock flow, 800px wide)
- **`scripts/`** — `build-release.sh`, DMG background PNGs, volume icon
- **`homebrew/`** — Homebrew tap with `Casks/lockpaw.rb`
- **`lockpaw-raycast/`** — Raycast extension (TypeScript, 4 commands: lock, unlock, unlock-password, toggle via URL scheme)
- **`website/`** — getlockpaw.com marketing site (untracked)

## Architecture decisions

- **Hotkey is the primary unlock** — no auth required. Touch ID / password is the fallback for forgotten hotkeys.
- **HotkeyManager uses CGEventTap on a dedicated background thread** — Carbon RegisterEventHotKey is unreliable in LSUIElement (menu bar-only) apps because the Carbon event dispatch doesn't activate until user interaction. The background thread with its own CFRunLoop bypasses this entirely.
- **Toggle observer lives in LockController.init()** — NOT in MenuBarExtra's `.onReceive`. SwiftUI lazily initializes MenuBarExtra content, so the observer wouldn't exist until the user clicks the menu bar icon.
- **Hotkey not registered until onboarding completes** — CGEventTap requires Accessibility permission. Registering before permission is granted creates a dead tap. OnboardingView posts `lockpawHotkeyPreferenceChanged` on completion, which triggers registration.
- **After onboarding, Settings opens automatically** — via `@Environment(\.openSettings)`. This activates the SwiftUI event pipeline so the hotkey works immediately.
- **InputBlocker only blocks keyboard + scroll** — mouse events pass through to the overlay window (SwiftUI buttons need clicks). The fullscreen overlay at CGShieldingWindowLevel blocks mouse access to other apps.
- **InputBlocker caches hotkey values** — reads HotkeyConfig once on startBlocking(), not per keystroke. Refreshes via notification observer.
- **Overlay windows drop to .statusBar during auth** — so the system Touch ID dialog can appear above them. Re-shields after auth completes or fails.
- **Overlay dismiss does NOT call window.close()** — only `orderOut` + clear `contentView`. Calling `close()` during animated dismiss causes EXC_BAD_ACCESS in `_NSWindowTransformAnimation dealloc` (autorelease pool timing).
- **HotkeyConfig centralizes all hotkey UserDefaults** — private static key constants, computed properties for reads, static methods for writes. Eliminates raw string literals across 5 files.
- **All timing magic numbers in Constants.Timing** — inputBlockerDelay, unlockSuccessAnim, errorDisplay, authRateLimit, etc.
- **All notifications consolidated** in `Notifications.swift` — not scattered across files.
- **@MainActor on LockController and Authenticator** — all Task blocks use explicit `Task { @MainActor [weak self] in }`.
- **LAContext.evaluatePolicy runs via Task.detached** to avoid MainActor deadlock.
- **Accessibility revocation while locked** → shows error message for 1.5s then force unlocks.
- **Fast User Switching** → cancels in-flight auth, keeps lock, re-blocks on session return.
- **Auth rate limiting** → 30s cooldown after 3 failed attempts.
- **Lock screen is always dark mode** regardless of appearance setting.
- **Breathing cycle** is 12 seconds (single master phase drives all animation).
- **Two color pools** only: teal (upper-left) + amber (lower-right). Violet was removed for clarity.
- **Settings toggles NSApp activation policy** — `.regular` on appear (shows in Cmd+Tab), `.accessory` on disappear.
- **Hotkey conflict detection** — HotkeyConfig.systemConflict() checks against ~20 common system shortcuts. Shown in both OnboardingView and SettingsView hotkey recorders.

## Design principles

- Minimal, whisper-quiet aesthetic. Low opacities, light font weights, generous negative space.
- The dog is the hero. Everything else recedes.
- Dog + message + time grouped as a tight cohesive unit, positioned at ~40% from top (slightly below center).
- Progressive disclosure — lock screen shows chevron + hint, tap reveals fallback auth with glass material button.
- Unlock success animation: dog scales up 1.15x with teal bloom and fades.
- No information on screen that would help someone bypass the lock (hotkey is not shown).
- Error states use `LockpawError` (red), not amber. Semibold weight.
- Settings follow native macOS Form with .formStyle(.grouped). No custom card UI.
- Onboarding includes security disclaimer ("visual privacy tool, not a security lock").
- Menu bar icon uses template rendering with opacity change: 100% when locked, 55% when unlocked.

## Color assets

- `LockpawTeal` — primary brand, shadows, glows, interactive elements (#00D4AA)
- `LockpawAmber` — secondary, warm accent in color pool (#FF9F43)
- `LockpawViolet` — removed from lock screen, kept in assets
- `LockpawError` — auth failures (#FF3B30)
- `LockpawSuccess` — available but unused currently

## CI / Distribution

- **GitHub Actions CI** — build + 34 tests on `macos-15` runners (Xcode 16) on push to main and PRs (`.github/workflows/ci.yml`)
- **Release workflow** — tag `v*` → build → conditional sign/notarize → GitHub Release (`.github/workflows/release.yml`). Uses `macos-15` runners. Creates temporary keychain for CI signing. Uploads DMG if signing secrets are configured.
- **Sparkle auto-updates** — appcast at `https://getlockpaw.com/appcast.xml`, SPUStandardUpdaterController in AppDelegate
- **Homebrew cask** — tap repo at `sorkila/homebrew-lockpaw`, install via `brew tap sorkila/lockpaw && brew install --cask lockpaw`
- **Raycast extension** — `lockpaw-raycast/`, controls app via URL scheme, 4 commands (lock, unlock, unlock-password, toggle)
- **DMG** — built locally with `create-dmg` (branded background, teal arrow, volume icon). CI uses `hdiutil` for simpler unsigned builds.
- **GitHub Sponsors** — `.github/FUNDING.yml` links to Buy Me a Coffee (eriknielsen)
