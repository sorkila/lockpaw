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
- **Current version:** 1.1.0

## Build

```bash
xcodegen generate
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug build
```

After each rebuild, reset TCC (binary signature changes invalidate Accessibility permission):
```bash
tccutil reset Accessibility com.eriknielsen.lockpaw
```

## Test

```bash
xcodebuild -project Lockpaw.xcodeproj -scheme Lockpaw -configuration Debug test
```

50 unit tests covering LockState transitions, Constants formatting, HotkeyConfig conflict detection/auth-required unlock preference, SleepPreventer state handling, Mascot resolution, and PingDecision agent-ping branching.

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
│   ├── SleepPreventer.swift        IOKit sleep assertion
│   └── AgentNotifier.swift         UNUserNotificationCenter — "your agent needs you" (lazy auth)
├── Models/
│   ├── LockState.swift             .unlocked → .locking → .locked → .unlocking
│   ├── HotkeyConfig.swift          Centralized hotkey UserDefaults + system conflict detection/auth unlock preference
│   └── PingDecision.swift          Pure agent-ping decision (state + sound pref → pulse/notify/sound)
├── Views/
│   ├── LockScreenView.swift        Lock screen — dog, timer, message, fallback auth
│   ├── AmbientScreenView.swift     Secondary display — morphing gradient blobs
│   ├── MenuBarView.swift           Menu bar dropdown
│   ├── SettingsView.swift          Native Form, hotkey recorder, auth setting, updates, Buy Me a Coffee
│   └── OnboardingView.swift        4 steps: welcome, hotkey, accessibility, menu bar
├── Utilities/
│   ├── Constants.swift             App constants, Timing enum, animation presets, formatting
│   ├── Notifications.swift         All Notification.Name in one place
│   └── AccessibilityChecker.swift  AXIsProcessTrusted + System Settings opener
└── Resources/
    └── Assets.xcassets             App icon, mascot, menu bar icon (template), colors

LockpawTests/                       (sibling of Lockpaw/)
├── LockStateTests.swift            State transition validation (16 tests)
├── ConstantsTests.swift            Time formatting (11 tests)
├── HotkeyConfigTests.swift         System shortcut conflict detection + auth unlock preference (9 tests)
├── SleepPreventerTests.swift       Sleep assertion state handling (5 tests)
├── MascotTests.swift               Mascot resolution (3 tests)
└── AgentPingTests.swift            PingDecision branching: locked/unlocked × sound (6 tests)

LockpawCLI/                         (sibling of Lockpaw/)
└── main.swift                      `lockpaw` CLI: ping / install-cli / install-hook <claude|codex|gemini>
```

## Architecture decisions

### Core lock system
- **Hotkey is the primary unlock by default** — Touch ID / password is the fallback for forgotten hotkeys, and Settings can require auth before a hotkey unlock succeeds.
- **HotkeyManager uses CGEventTap on a dedicated background thread** — Carbon RegisterEventHotKey is unreliable in LSUIElement (menu bar-only) apps because the Carbon event dispatch doesn't activate until user interaction. The background thread with its own CFRunLoop bypasses this entirely.
- **Toggle observer lives in LockController.init()** — NOT in MenuBarExtra's `.onReceive`. SwiftUI lazily initializes MenuBarExtra content, so the observer wouldn't exist until the user clicks the menu bar icon.
- **Hotkey not registered until onboarding completes** — CGEventTap requires Accessibility permission. Registering before permission is granted creates a dead tap. OnboardingView posts `lockpawHotkeyPreferenceChanged` on completion, which triggers registration.
- **HotkeyManager guards on AXIsProcessTrusted() before creating event tap** — `CGEvent.tapCreate` returns non-nil even without Accessibility, creating a dead tap. The guard prevents registration and sets `isRegistered = false` so future attempts can retry.
- **AppDelegate polls for Accessibility after failed hotkey registration** — when the app launches with stale/revoked TCC (e.g., after update changes binary signature), a 2-second polling timer checks `AXIsProcessTrusted()` and calls `reregister()` when granted. Also starts polling after onboarding completion if registration fails.
- **InputBlocker only blocks keyboard + scroll** — mouse events pass through to the overlay window (SwiftUI buttons need clicks). The fullscreen overlay at CGShieldingWindowLevel blocks mouse access to other apps.
- **Overlay dismiss does NOT call window.close()** — only `orderOut` + clear `contentView`. Calling `close()` during animated dismiss causes EXC_BAD_ACCESS in `_NSWindowTransformAnimation dealloc` (autorelease pool timing).

### Multi-display
- **Primary vs ambient screens** — `OverlayWindowManager.showOverlay` takes a content factory `(Int, Bool) -> AnyView`. Primary screen shows full lock screen; secondary screens show `AmbientScreenView`.
- **AmbientScreenView uses 5 morphing gradient blobs** — ellipses with solid fills at low opacity, heavy blur, on independent orbital paths. 3-second fade-in from black.

### Agent alerts (the `lockpaw` CLI ping)
- **Purpose** — when an AI agent (Claude Code, Codex, Gemini) pauses for permission or finishes while the screen is locked, the lock screen glows + a notification fires. Stays locked; you unlock when ready.
- **Transport is DistributedNotificationCenter, NOT `lockpaw://`** — `open lockpaw://ping` would launch the app when it isn't running (wrong for a background ping). The CLI posts `com.eriknielsen.lockpaw.ping`; `AppDelegate` bridges it to a local `.lockpawPing`. The URL scheme stays for `lock`/`unlock` only.
- **`PingDecision.make(state:soundEnabled:)` is pure** — locked → pulse + notify; any other state → no-op. Unit-tested directly (no UNUserNotificationCenter mocking). `LockController.handlePing()` debounces (`Timing.pingDebounce`) then applies the decision; `pingPulse` is a counter the lock screen watches via `.onChange`.
- **Glow is the hero, not the banner** — `LockScreenView` ramps a bright teal full-screen radial bloom (peak ~0.28, `.plusLighter`) so it reads across a room; notification is secondary. Sound is opt-in (`Constants.agentPingSoundKey`, default off, for shared offices).
- **The CLI lives in `Contents/SharedSupport/`, NOT `Contents/MacOS/`** — `lockpaw` would collide with the app binary `Lockpaw` on case-insensitive filesystems (DMG/Applications). `install-cli` symlinks it into `~/.local/bin`.
- **CLI resolves `$HOME`, not `homeDirectoryForCurrentUser`** — the latter ignores `$HOME`; agent CLIs locate their own configs via `$HOME`, so `install-hook` must too. Writers back up (`.bak`), are idempotent, and never clobber an existing `notify`/hook.
- **build-release.sh signs the CLI inside-out** — `Contents/SharedSupport/lockpaw` is signed before the outer app, same `/tmp` copy treatment as the rest (iCloud xattr gotcha).

### Misc
- **NSHostingView requires explicit autoresizingMask** — defaults to 0 (no flex). Must set `[.width, .height]` and `frame = window.contentLayoutRect`.
- **Screen change handler uses true debounce** — cancels pending `DispatchWorkItem` before scheduling a new one. 300ms delay for `NSScreen.screens` to settle.
- **All timing magic numbers in Constants.Timing** — inputBlockerDelay, unlockSuccessAnim, errorDisplay, authRateLimit, etc.
- **All notifications consolidated** in `Notifications.swift` — not scattered across files.
- **@MainActor on LockController and Authenticator** — all Task blocks use explicit `Task { @MainActor [weak self] in }`.
- **LAContext.evaluatePolicy runs via Task.detached** to avoid MainActor deadlock.
- **Accessibility revocation while locked** → shows error message for 1.5s then force unlocks.
- **Accessibility revocation at launch** → re-shows onboarding. If `hasCompletedOnboarding` is true but `AXIsProcessTrusted()` is false (e.g., after TCC reset from binary signature change), the app resets the flag and re-shows the onboarding window to guide re-granting.
- **Fast User Switching** → cancels in-flight auth, keeps lock, re-blocks on session return.
- **Auth rate limiting** → 30s cooldown after 3 failed attempts.
- **Lock screen is always dark mode** regardless of appearance setting.
- **Breathing cycle** is 12 seconds (single master phase drives all animation).
- **Sparkle updater deferred to applicationDidFinishLaunching** — `SPUStandardUpdaterController` created with `startingUpdater: false`, then `updater.start()` called manually.
- **Sparkle uses inline update UI** — `UpdateCheckViewModel` (SPUUpdaterDelegate) in SettingsView shows spinner, checkmark, or error inline. Sparkle's standard dialogs don't surface in LSUIElement apps.
- **AccessibilityChecker uses `takeUnretainedValue()`** on `kAXTrustedCheckOptionPrompt` — it's a global CF constant, not a +1 return.

## Design principles

- Minimal, whisper-quiet aesthetic. Low opacities, light font weights, generous negative space.
- The dog is the hero in normal mode. Everything else recedes.
- Progressive disclosure — lock screen shows chevron + hint, tap reveals fallback auth.
- Color as signal — teal (safe) → amber (caution) → red (danger). Everything uses the same proximity-based gradient.
- No information on screen that would help someone bypass the lock (hotkey is not shown).
- Settings: two sections max (Lock Screen + General). No scrolling needed. Keep support and update controls discoverable without turning Settings into a dashboard.

## Color assets

- `LockpawTeal` — primary brand, shadows, glows, interactive elements (#00D4AA)
- `LockpawAmber` — secondary, warm accent (#FF9F43)
- `LockpawError` — auth failures and destructive/error states (#FF3B30)
- `LockpawViolet` — removed from lock screen, kept in assets
- `LockpawSuccess` — available but unused currently

## CI / Distribution

- **GitHub Actions CI** — build + 41 tests on `macos-15` runners (Xcode 16) on push to main and PRs (`.github/workflows/ci.yml`). Uses `actions/checkout@v6`.
- **Release workflow** — tag `v*` → build → conditional sign/notarize (inside-out, not `--deep`) → branded DMG via `create-dmg` with Finder alias → GitHub Release (`.github/workflows/release.yml`). Handles pre-existing releases gracefully (`gh release view` check before create, `gh release upload --clobber` for DMG).
- **Latest release** — v1.0.9 prepared 2026-05-25. DMG SHA-256: `48cfa87be14eef13491ef3093bca85c4005cff47ed7c06feb87d27481635a960`.
- **Sparkle auto-updates** — EdDSA-signed appcast at `https://getlockpaw.com/appcast.xml`, download URL points to GitHub Releases. The public appcast should advertise v1.0.9 / build 10 after release.
- **Homebrew cask** — tap repo at `sorkila/homebrew-lockpaw`, install via `brew tap sorkila/lockpaw && brew install --cask lockpaw`. The tap and checked-in `homebrew/Casks/lockpaw.rb` are current at v1.0.9. Homebrew core submission [Homebrew/homebrew-cask#259932](https://github.com/Homebrew/homebrew-cask/pull/259932) was closed 2026-04-18 for notability requirements; resubmit once the app meets Homebrew's thresholds.
- **Raycast extension** — `lockpaw-raycast/`, submitted to Raycast store.
- **Website** — `sorkila/lockpaw-web`, deployed via FTP GitHub Action to Inleed.
- **GitHub Sponsors** — `.github/FUNDING.yml` links to Buy Me a Coffee (eriknielsen)

## Repo-level files

- **`LICENSE`** — MIT license
- **`CONTRIBUTING.md`** — Build, test, and PR guidelines for contributors
- **`CHANGELOG.md`** — Version history and release notes
- **`.github/ISSUE_TEMPLATE/`** — Bug report and feature request templates (YAML)
- **`.github/FUNDING.yml`** — Buy Me a Coffee link

## Repo-level directories

- **`assets/`** — `demo.gif` hero GIF for README (lock/unlock flow, 800px wide)
- **`scripts/`** — `build-release.sh`, DMG background PNGs, volume icon
- **`homebrew/`** — Local copy of Homebrew cask (canonical version in `sorkila/homebrew-lockpaw`)
- **`lockpaw-raycast/`** — Raycast extension (TypeScript, 4 commands)
- **`website/`** — getlockpaw.com marketing site (untracked)

## Awesome list submissions

Lockpaw has been submitted to the following curated lists (delete forks after merge):

| Repo | PR | Category | Status |
|---|---|---|---|
| `jaywcjlove/awesome-mac` | #1901 | Security Tools | Merged |
| `jaywcjlove/awesome-swift-macos-apps` | #27 | Security | Merged |
| `xyNNN/awesome-mac` | #29 | Security | Merged |
| `phmullins/awesome-macos` | #158 | Security | Pending |
| `milanaryal/awesome-macos` | #7 | Utilities | Pending |
| `iCHAIT/awesome-macOS` | #731 | Security | Merged |
| `open-saas-directory/awesome-native-macosx-apps` | #48 | Security & Privacy | Pending (superseded #47) |
| `SKaplanOfficial/Mac-Menubar-Megalist` | #11 | Security | Pending (superseded #10) |
| `ashishb/osx-and-ios-security-awesome` | #48 | macOS Security | Merged |
| `jeffreyjackson/mac-apps` | #79 | Mac Interface Exclusives | Merged |
| `kai5263499/osx-security-awesome` | #24 | Useful tools and guides | Merged |
| `drduh/macOS-Security-and-Privacy-Guide` | #523 | Related software | Pending |
| `tonnoz/super-awesome-mac` | #3 | Utils | Pending |
| `guyzyl/awesome-macos-apps` | #19 | Utilities | Pending |
| `serhii-londar/open-source-mac-os-apps` | #1062 | Security + Menubar | Closed |
| `matteocrippa/awesome-swift` | #1899 | Security | Rejected (libraries only) |
| `Wolg/awesome-swift` | #283 | Security | Closed |
| `Lissy93/awesome-privacy` | #444 | Mac OS Defences | Rejected (project too new) |
| `pluja/awesome-privacy` | #731 | Desktop | Pending |
| `onmyway133/awesome-swiftui` | #29 | Open source apps > macOS | Merged |
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
