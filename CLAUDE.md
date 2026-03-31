# Lockpaw

macOS menu bar screen guard. Lock/unlock with a hotkey. Dog mascot.

## Quick reference

- **App name:** Lockpaw
- **Bundle ID:** `com.eriknielsen.lockpaw`
- **URL scheme:** `lockpaw://`
- **Website:** getlockpaw.com (hosted on Inleed, deployed via FTP from `sorkila/lockpaw-web`)
- **Repo:** git@github.com:sorkila/lockpaw.git
- **Requires:** macOS 14+, Xcode 16+, XcodeGen
- **Dependencies:** Sparkle (SPM, auto-updates with EdDSA signing)
- **Current version:** 1.0.7

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

Builds unsigned → copies to `/tmp` for signing → signs with Developer ID → creates DMG → notarizes → staples → sets custom DMG file icon. Output: `build/Lockpaw.dmg`.

**Requires:** `lockpaw-notarize` keychain profile (already stored), Sparkle EdDSA signing key in Keychain.

**Signing:** The build script copies the app to `/tmp` via `ditto --norsrc` before signing. This is required because the repo lives in iCloud-synced `~/Documents` which adds irremovable `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P` xattrs that cause codesign to fail with "resource fork, Finder information, or similar detritus not allowed". Signing is done inside-out with `--timestamp`: XPC service binaries → XPC bundles → Autoupdate → Updater.app binary → Updater.app → Sparkle.framework → main app.

**DMG pipeline:** Builds a R/W DMG via `hdiutil`, copies app + Finder alias (not symlink) to `/Applications`, applies AppleScript window styling (background, icon positions, hide dotfiles), copies volume icon AFTER AppleScript (the `update` command deletes `.VolumeIcon.icns`), then converts once to compressed UDZO. No intermediate conversions.

**After building a release:**
1. Tag: `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`
2. Create GitHub Release with DMG: `gh release create vX.Y.Z build/Lockpaw.dmg#Lockpaw.dmg --repo sorkila/lockpaw`
3. Update appcast: `generate_appcast build/appcast/` → fix download URL to GitHub Releases → push `appcast.xml` to `sorkila/lockpaw-web`
4. Update Homebrew cask SHA256 in both `sorkila/homebrew-lockpaw` and `homebrew/Casks/lockpaw.rb`

**DMG assets** in `scripts/`:
- `dmg-background.png` / `dmg-background@2x.png` — light background with teal arrow (660x480 / 1320x960)
- `dmg-volume-icon.icns` — dog mascot icon shown on mounted volume and DMG file in Finder

**DMG design notes:**
- Uses Finder alias (not symlink) for Applications — symlinks show broken icon on Sonoma+
- AppleScript's `update without registering applications` deletes `.VolumeIcon.icns` — must copy icon AFTER AppleScript
- Dotfiles (`.background`, `.fseventsd`) pushed off-screen via AppleScript positioning
- Light background for readable dark text labels in Finder light mode

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
│   ├── AmbientScreenView.swift     Secondary display — morphing gradient blobs
│   ├── MenuBarView.swift           Menu bar dropdown
│   ├── SettingsView.swift          Native Form, hotkey recorder, appearance, UpdateCheckViewModel
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
- **`homebrew/`** — Local copy of Homebrew cask (canonical version in `sorkila/homebrew-lockpaw`)
- **`lockpaw-raycast/`** — Raycast extension (TypeScript, 4 commands: Lock Screen, Unlock with Touch ID, Unlock with Password, Toggle Lock)
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
- **Overlay dismiss does NOT call window.close()** — only `orderOut` + clear `contentView`. Calling `close()` during animated dismiss causes EXC_BAD_ACCESS in `_NSWindowTransformAnimation dealloc` (autorelease pool timing). This applies everywhere: animated dismiss, screen change recreation, etc.
- **NSHostingView requires explicit autoresizingMask** — defaults to 0 (no flex), which causes SwiftUI content to not fill the window on external/scaled displays. Must set `[.width, .height]` and `frame = window.contentLayoutRect`.
- **Screen change handler uses true debounce** — cancels pending `DispatchWorkItem` before scheduling a new one, so only the last `didChangeScreenParametersNotification` in a burst triggers window recreation. 300ms delay for `NSScreen.screens` to settle.
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
- **Sparkle updater deferred to applicationDidFinishLaunching** — `SPUStandardUpdaterController` created with `startingUpdater: false`, then `updater.start()` called manually in `applicationDidFinishLaunching` with error logging. Starting during property init (before app launch) can silently fail.
- **Sparkle uses inline update UI** — `UpdateCheckViewModel` (SPUUpdaterDelegate) in SettingsView shows spinner, checkmark, or error inline. Sparkle's standard dialogs don't surface in LSUIElement (menu bar) apps because they appear behind other windows.
- **HotkeyManager re-enables its event tap** when the system disables it (tapDisabledByTimeout / tapDisabledByUserInput). Uses `userInfo` to pass `self` to the C callback, matching InputBlocker's pattern.
- **Accessibility prompt only on lock attempt** — NOT on app launch. Prompting on launch caused an infinite dialog loop when the TCC entry was stale (toggle ON but trust invalidated after binary change). The `lock()` method handles prompting when the user actually tries to lock.
- **AccessibilityChecker uses `takeUnretainedValue()`** on `kAXTrustedCheckOptionPrompt` — it's a global CF constant (not a +1 return), so `takeRetainedValue()` would over-release it.
- **HotkeyManager guards on AXIsProcessTrusted() before creating event tap** — `CGEvent.tapCreate` returns non-nil even without Accessibility, creating a dead tap. The guard prevents registration and sets `isRegistered = false` so future attempts can retry. If a tap was previously registered but Accessibility was revoked, it tears down the dead tap first.
- **AppDelegate polls for Accessibility after failed hotkey registration** — when the app launches with stale/revoked TCC (e.g., after update changes binary signature), a 2-second polling timer checks `AXIsProcessTrusted()` and calls `reregister()` when granted. Avoids requiring app restart.
- **Multi-display: primary vs ambient screens** — `OverlayWindowManager.showOverlay` takes a content factory `(Int, Bool) -> AnyView` instead of a single view. Primary screen (index 0) shows full lock screen; secondary screens show `AmbientScreenView` (morphing gradient blobs). Configurable in Settings: "Ambient on secondary" (default) or "Same on all screens".
- **AmbientScreenView uses 5 morphing gradient blobs** — ellipses with solid fills at low opacity (0.06-0.13), heavy blur (90-140pt), on independent orbital paths driven by `osc()` helper (sin/cos with unique frequencies and offsets). 3-second fade-in from black. Vignette overlay darkens edges. `accessibilityReduceMotion` shows static version.
- **Secondary screen windows have `ignoresMouseEvents = true`** — no interaction needed on ambient screens; all auth UI is on the primary screen.

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
- **Release workflow** — tag `v*` → build → conditional sign/notarize (inside-out, not `--deep`) → branded DMG via `create-dmg` with Finder alias → GitHub Release (`.github/workflows/release.yml`). Uses `macos-15` runners.
- **Sparkle auto-updates** — EdDSA-signed appcast at `https://getlockpaw.com/appcast.xml`, download URL points to GitHub Releases. SPUStandardUpdaterController in AppDelegate with deferred start. UpdateCheckViewModel is the SPUUpdaterDelegate, providing inline UI for user-initiated checks. EdDSA public key in Info.plist, private key in Keychain.
- **Homebrew cask** — tap repo at `sorkila/homebrew-lockpaw`, install via `brew tap sorkila/lockpaw && brew install --cask lockpaw`
- **Raycast extension** — `lockpaw-raycast/`, submitted to Raycast store (PR #26497 on `raycast/extensions`). Shared `lockpaw.ts` utility, error handling via `showToast`, dark dog head icon.
- **Website** — `sorkila/lockpaw-web`, deployed via FTP GitHub Action to Inleed. Download button points to `https://github.com/sorkila/lockpaw/releases/latest/download/Lockpaw.dmg`.
- **GitHub Sponsors** — `.github/FUNDING.yml` links to Buy Me a Coffee (eriknielsen)

## Repo-level files

- **`LICENSE`** — MIT license
- **`CONTRIBUTING.md`** — Build, test, and PR guidelines for contributors
- **`CHANGELOG.md`** — Version history and release notes
- **`.github/ISSUE_TEMPLATE/`** — Bug report and feature request templates (YAML)
- **`.github/FUNDING.yml`** — Buy Me a Coffee link

## Awesome list submissions

Lockpaw has been submitted to the following curated lists (delete forks after merge):

| Repo | PR | Category | Status |
|---|---|---|---|
| `jaywcjlove/awesome-mac` | #1901 | Security Tools | Merged |
| `jaywcjlove/awesome-swift-macos-apps` | #27 | Security | Merged |
| `xyNNN/awesome-mac` | #29 | Security | Merged |
| `phmullins/awesome-macos` | #158 | Security | Pending |
| `milanaryal/awesome-macos` | #7 | Utilities | Pending |
| `iCHAIT/awesome-macOS` | #731 | Security | Pending (superseded #729) |
| `open-saas-directory/awesome-native-macosx-apps` | #48 | Security & Privacy | Pending (superseded #47) |
| `SKaplanOfficial/Mac-Menubar-Megalist` | #11 | Security | Pending (superseded #10) |
| `ashishb/osx-and-ios-security-awesome` | #48 | macOS Security | Pending |
| `jeffreyjackson/mac-apps` | #79 | Mac Interface Exclusives | Pending |
| `kai5263499/osx-security-awesome` | #24 | Useful tools and guides | Pending |
| `drduh/macOS-Security-and-Privacy-Guide` | #523 | Related software | Pending |
| `tonnoz/super-awesome-mac` | #3 | Utils | Pending |
| `guyzyl/awesome-macos-apps` | #19 | Utilities | Pending |
| `serhii-londar/open-source-mac-os-apps` | #1062 | Security + Menubar | Closed |
| `matteocrippa/awesome-swift` | #1899 | Security | Rejected (libraries only) |
| `Wolg/awesome-swift` | #283 | Security | Closed |
| `Lissy93/awesome-privacy` | #444 | Mac OS Defences | Rejected (project too new) |
| `pluja/awesome-privacy` | #731 | Desktop | Pending |
| `onmyway133/awesome-swiftui` | #29 | Open source apps > macOS | Pending |
| `linsa-io/macos-apps` | #40 | Utilities | Pending |
| `johnjago/awesome-free-software` | #100 | Utilities | Pending |
| `unicodeveloper/awesome-opensource-apps` | #162 | Swift | Pending |
| `sbilly/awesome-security` | #471 | Endpoint > Authentication | Pending |
| `ishanvyas22/awesome-open-source-systems` | #16 | Security | Pending |

## Directory listings

| Site | Category | Status |
|---|---|---|
| MacUpdate | Utilities | Submitted |
| AlternativeTo | Screen Lock | Submitted |
