# Lockpaw

macOS menu bar screen guard. Lock/unlock with a hotkey. Dog mascot.

## Quick reference

- **App name:** Lockpaw
- **Bundle ID:** `com.eriknielsen.lockpaw`
- **URL scheme:** `lockpaw://`
- **Website:** getlockpaw.com
- **Repo:** git@github.com:sorkila/lockpaw.git
- **Requires:** macOS 14+, Xcode 15+, XcodeGen

## Build

```bash
xcodegen generate
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug build
```

After each rebuild, reset TCC (binary signature changes invalidate accessibility permission):
```bash
tccutil reset Accessibility com.eriknielsen.lockpaw
```

## Release

```bash
./scripts/build-release.sh
```

Builds unsigned → signs with Developer ID → creates DMG → notarizes → staples. Output: `build/Lockpaw.dmg`. Requires `lockpaw-notarize` keychain profile (already stored).

## Project structure

```
Lockpaw/
├── LockpawApp.swift                Entry point, MenuBarExtra, AppDelegate, onboarding
├── Controllers/
│   ├── LockController.swift        State machine, lock/unlock orchestration
│   ├── Authenticator.swift         LAContext (Touch ID / password fallback)
│   ├── InputBlocker.swift          CGEventTap — blocks keyboard/scroll while locked
│   ├── HotkeyManager.swift         CGEventTap on background thread — global hotkey
│   ├── OverlayWindowManager.swift  NSWindow per screen at CGShieldingWindowLevel
│   └── SleepPreventer.swift        IOKit sleep assertion
├── Models/
│   ├── LockState.swift             .unlocked → .locking → .locked → .unlocking
│   └── HotkeyConfig.swift          Centralized hotkey UserDefaults access + conflict detection
├── Views/
│   ├── LockScreenView.swift        Lock screen — dog, message, time, fallback auth
│   ├── MenuBarView.swift           Menu bar dropdown
│   ├── SettingsView.swift          Native Form, appearance toggle, hotkey display
│   └── OnboardingView.swift        4 steps: welcome, hotkey, accessibility, menu bar
├── Utilities/
│   ├── Constants.swift             App constants, animation presets, time formatting
│   ├── Notifications.swift         All Notification.Name in one place
│   └── AccessibilityChecker.swift  AXIsProcessTrusted + System Settings opener
└── Resources/
    └── Assets.xcassets             App icon, mascot, colors (Teal, Amber, Violet, Error, Success)
```

## Architecture decisions

- **Hotkey is the primary unlock** — no auth required. Touch ID / password is the fallback for forgotten hotkeys.
- **InputBlocker only blocks keyboard + scroll** — mouse events pass through to the overlay window (SwiftUI buttons need clicks). The fullscreen overlay at CGShieldingWindowLevel blocks mouse access to other apps.
- **Overlay windows drop to .statusBar during auth** — so the system Touch ID dialog can appear above them. Re-shields after auth completes or fails.
- **Custom hotkeys persist** in UserDefaults: `hotkeyKeyCode`, `hotkeyModifiers`, `hotkeyDisplay`. Read by HotkeyManager and InputBlocker.
- **All notifications consolidated** in `Notifications.swift` — not scattered across files.
- **@MainActor on LockController and Authenticator** — all Task blocks use explicit `Task { @MainActor [weak self] in }`.
- **LAContext.evaluatePolicy runs via Task.detached** to avoid MainActor deadlock.
- **Accessibility revocation while locked** → shows error message for 1.5s then force unlocks.
- **Fast User Switching** → cancels in-flight auth, keeps lock, re-blocks on session return.
- **Auth rate limiting** → 30s cooldown after 3 failed attempts.
- **Lock screen is always dark mode** regardless of appearance setting.
- **Breathing cycle** is 12 seconds (single master phase drives all animation).
- **Two color pools** only: teal (upper-left) + amber (lower-right). Violet was removed for clarity.

## Design principles

- Minimal, whisper-quiet aesthetic. Low opacities, light font weights, generous negative space.
- The dog is the hero. Everything else recedes.
- Progressive disclosure — lock screen shows chevron + hint, tap reveals fallback auth.
- No information on screen that would help someone bypass the lock (hotkey is not shown).
- Error states use `LockpawError` (red), not amber. Semibold weight.
- Settings follow native macOS Form with .formStyle(.grouped). No custom card UI.

## Color assets

- `LockpawTeal` — primary brand, shadows, glows, interactive elements
- `LockpawAmber` — secondary, warm accent in color pool + error state removed
- `LockpawViolet` — removed from lock screen, kept in assets
- `LockpawError` — auth failures
- `LockpawSuccess` — available but unused currently
