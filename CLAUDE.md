# Lockpaw

macOS menu bar screen guard. Lock/unlock with a hotkey; the covered screen glows when your AI agent (Claude Code / Codex / Gemini) needs you. Dog or cat mascot.

## Quick reference

- **App name:** Lockpaw
- **Bundle ID:** `com.eriknielsen.lockpaw`
- **URL scheme:** `lockpaw://`
- **Website:** getlockpaw.com (hosted on Inleed, deployed via FTP from `sorkila/lockpaw-web`)
- **Repo:** git@github.com:sorkila/lockpaw.git
- **Requires:** macOS 14+, Xcode 16+, XcodeGen
- **Dependencies:** Sparkle (SPM, auto-updates with EdDSA signing)
- **Current version:** 1.1.1
- **Size:** ~10 MB DMG download, ~13 MB installed (2.7 MB of that is Sparkle) — keep README/site/marketing claims in sync with the actual DMG when this changes

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

**⚠️ Finder Automation gotcha:** the DMG window-styling AppleScript needs Automation→Finder permission (`-1743 Not authorized to send Apple events to Finder` otherwise). The first attempt from a fresh terminal is auto-denied without a prompt, but the denial creates an entry — **grant the host terminal (e.g. Ghostty) → Finder under System Settings → Privacy & Security → Automation and re-run**; v1.1.1's branded DMG was built from Claude Code this way. (v1.1.0 shipped with a plain-DMG fallback before this was understood.) Long-term: add CI signing secrets so `v*` tags build the branded DMG in the cloud. See `memory/project_release_gotchas.md`.

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
│   ├── Mascot.swift                Dog/cat lock-screen mascot preference
│   └── PingDecision.swift          Pure agent-ping decision (state + sound pref → pulse/notify/sound)
├── Views/
│   ├── LockScreenView.swift        Lock screen — mascot, timer, message, fallback auth, agent-ping glow
│   ├── AmbientScreenView.swift     Secondary display — morphing gradient blobs
│   ├── MenuBarView.swift           Menu bar dropdown
│   ├── SettingsView.swift          5 tabs; hotkey recorder, auth setting, agent alerts (sound/test/setup), updates, Buy Me a Coffee
│   └── OnboardingView.swift        5 steps: welcome (mascot), hotkey, accessibility, agent alerts, menu bar
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
- **Glow is the hero, not the banner** — on ping, `LockScreenView` breathes a saturated teal full-screen radial bloom (`pingPulseCount` breaths of `pingPulsePeriod`, mid-stop gradient + `.plusLighter`), then settles to a faint resting glow (`pingGlowRest`) with a standing "Your agent needs you" caption (`LockController.agentAttention`) until unlock. A generation counter cancels a stale pulse chain if a new ping lands mid-sequence. Notification is secondary; delivered banners are cleared on unlock (`AgentNotifier.clearDelivered()`). Sound is opt-in (`Constants.agentPingSoundKey`, default off, for shared offices).
- **Cursor hides while locked** — `OverlayWindowManager` activates the app, makes the primary overlay key (`OverlayWindow` subclass: borderless windows refuse key status by default), then `NSCursor.setHiddenUntilMouseMoves(true)` — which is a no-op unless the app is active. Mouse-move monitors + an idle timer (`Timing.cursorIdleHide`) re-hide after stillness. Never `NSCursor.hide()` — an unbalanced hide would leave the pointer invisible over the auth button.
- **Lock-screen type uses four tokens** — `Font.lockBody/lockLabel/lockCaption/lockMono` in Constants.swift map to the DESIGN.md §2 scale; differentiate captions with opacity, never new sizes.
- **The CLI lives in `Contents/SharedSupport/`, NOT `Contents/MacOS/`** — `lockpaw` would collide with the app binary `Lockpaw` on case-insensitive filesystems (DMG/Applications). `install-cli` symlinks it into `~/.local/bin`.
- **The CLI target sets `PRODUCT_MODULE_NAME: LockpawCLI`** (executable stays `lockpaw`) — its Swift module would otherwise be `lockpaw`, which case-collides with the app's `Lockpaw` module and breaks `@testable import Lockpaw` on a clean build (`unable to resolve module dependency: 'Lockpaw'`). This only surfaces on a clean build (CI), not incremental local ones.
- **CLI resolves `$HOME`, not `homeDirectoryForCurrentUser`** — the latter ignores `$HOME`; agent CLIs locate their own configs via `$HOME`, so `install-hook` must too. Writers back up (`.bak`), are idempotent, and never clobber a foreign `notify`/hook.
- **`install-hook` is self-contained** — it ensures the `~/.local/bin/lockpaw` symlink exists (`ensureCLISymlink()`, shared with `install-cli`) and writes PATH-independent commands: Claude gets `"$HOME/.local/bin/lockpaw" ping` (hook commands run through a shell, which expands `$HOME`); Codex gets the absolute symlink path in the `notify` argv (executed directly, no shell). Bare `lockpaw ping` silently failed for anyone who skipped `install-cli` or lacked `~/.local/bin` on PATH. Re-running upgrades any older lockpaw entry in place (`isLockpawPingCommand` matches loosely).
- **`install-hook claude` honors `$CLAUDE_CONFIG_DIR`** — falls back to `~/.claude`. Users running multiple Claude Code profiles (e.g. `CLAUDE_CONFIG_DIR=~/.claude-personal`) get the hook in the right settings.json.
- **Settings → General has one-click agent setup** — buttons run the bundled CLI (`SharedSupport/lockpaw`) via `Process` off the main thread: Install (install-cli), Claude/Codex (install-hook), Gemini copies the `--print` snippet (its hook schema is still stabilizing). Exit ≠ 0 or a ⚠️ on stdout (foreign Codex `notify`) shows as a failure with the message under the row — the button never claims success for a write that didn't happen. Note: the GUI app launches without `CLAUDE_CONFIG_DIR`, so one-click Claude setup targets `~/.claude`; multi-profile users should run `install-hook` from their terminal.
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
- **Breathing animation uses one monotonic master phase** — advanced linearly over a ~14-day span (`Constants.Anim.breathePhaseTarget`), one phase-unit ≈ 12s. NOT a `0→1 repeatForever` loop: that wrapped discontinuously and snapped the mascot every 12s. Drives the lock screen and ambient blobs.
- **Sparkle updater deferred to applicationDidFinishLaunching** — `SPUStandardUpdaterController` created with `startingUpdater: false`, then `updater.start()` called manually.
- **Sparkle uses inline update UI** — `UpdateCheckViewModel` (SPUUpdaterDelegate) in SettingsView shows spinner, checkmark, or error inline. Sparkle's standard dialogs don't surface in LSUIElement apps.
- **AccessibilityChecker uses `takeUnretainedValue()`** on `kAXTrustedCheckOptionPrompt` — it's a global CF constant, not a +1 return.

## Design principles

- Minimal, whisper-quiet aesthetic. Low opacities, light font weights, generous negative space.
- The mascot (dog or cat) is the hero in normal mode. Everything else recedes.
- The fallback auth button is always visible at the bottom of the lock screen (quiet, material-backed; no tap-to-reveal).
- Color as signal — teal (safe) → amber (caution) → red (danger). Everything uses the same proximity-based gradient.
- No information on screen that would help someone bypass the lock (hotkey is not shown).
- Settings has five focused tabs (Lock Screen, Shortcuts, General, Permissions, About) via `SettingsTabBar`; tabs cross-fade. Keep each tab tight — don't turn Settings into a dashboard. The full design system (tokens, motion, coherence) lives in `DESIGN.md`.

## Color assets

- `LockpawTeal` — primary brand, shadows, glows, interactive elements (#00D4AA)
- `LockpawAmber` — secondary, warm accent (#FF9F43)
- `LockpawError` — auth failures and destructive/error states (#FF3B30)
- `LockpawViolet` — removed from lock screen, kept in assets
- `LockpawSuccess` — available but unused currently

## CI / Distribution

- **GitHub Actions CI** — build + 50 tests on `macos-15` runners (Xcode 16) on push to main and PRs (`.github/workflows/ci.yml`). Uses `actions/checkout@v6`.
- **Release workflow** — tag `v*` → build → conditional sign/notarize (inside-out, not `--deep`) → branded DMG via `create-dmg` with Finder alias → GitHub Release (`.github/workflows/release.yml`). Handles pre-existing releases gracefully. **Note:** signing/notarization only runs if signing secrets are set — they are **not** currently configured, so a tag push creates a release but no signed DMG. Sign/notarize locally (or add the secrets).
- **Latest release** — v1.1.1 released 2026-06-10 (build 12). DMG SHA-256: `94a4ad96650f395e21fcb112c4904621cce1442cfef9d4919feccdbeedbdf9b4`. Full branded DMG (Finder styling worked from Claude Code after granting Ghostty Automation→Finder in System Settings).
- **Sparkle auto-updates** — EdDSA-signed appcast at `https://getlockpaw.com/appcast.xml`, download URL points to GitHub Releases. Advertises **v1.1.1 / build 12**.
- **Homebrew cask** — tap repo at `sorkila/homebrew-lockpaw`, install via `brew tap sorkila/lockpaw && brew install --cask lockpaw`. The tap and checked-in `homebrew/Casks/lockpaw.rb` are current at **v1.1.1** (uses modern `depends_on macos: :sonoma`). Homebrew core submission [Homebrew/homebrew-cask#259932](https://github.com/Homebrew/homebrew-cask/pull/259932) was closed 2026-04-18 for notability requirements; resubmit once the app meets Homebrew's thresholds.
- **Raycast extension** — **scrapped (2026-06-11)**. Never shipped: store PR [raycast/extensions#26497](https://github.com/raycast/extensions/pull/26497) auto-closed after unanswered review comments; decision is to not pursue the Raycast store. The `lockpaw-raycast/` code was deleted from the repo 2026-06-12 (recoverable from git history if ever needed).
- **Website** — `sorkila/lockpaw-web`, deployed via FTP GitHub Action to Inleed (the FTP connection to Inleed occasionally times out; re-run the failed workflow). Hero `demo.mp4` is the annotated agent-ping cut (since 2026-06-11).
- **GitHub Sponsors** — `.github/FUNDING.yml` links to Buy Me a Coffee (eriknielsen)
- **Git history rewritten 2026-06-12** (author-email normalization to the sorkila identity via `git filter-repo`; file trees byte-identical). All pre-rewrite SHAs are invalid — **re-clone stale clones, never pull/merge across the rewrite**. Tags/releases/appcast/cask were unaffected (they bind to tag names + asset URLs). Old commits remain reachable on GitHub only via immutable `refs/pull/*`; purging those would need a GitHub Support request.
- **Repo settings** (2026-06-12): wiki + Projects tabs disabled, private vulnerability reporting enabled (SECURITY.md routes reports there).

## Repo-level files

- **`LICENSE`** — MIT license
- **`CONTRIBUTING.md`** — Build, test, and PR guidelines for contributors
- **`CHANGELOG.md`** — Version history and release notes
- **`DESIGN.md`** — Canonical design system (color/type/space/motion/elevation tokens + coherence checklist) for app, web, and GitHub
- **`MARKETING.md`** — go-to-market plan (gitignored/local — competitive positioning; not committed). Rewritten 2026-06-11 as the v1.1.1 relaunch plan; Phase 0 closed. Reddit seeding started 2026-06-11 (r/ClaudeAI + r/vibecoding); PH/HN/X still open. 2026-06-12: "round 2" directory/list section added — ready-to-paste copy for the web-form directories (MacMenuBar, OpenAlternative, Softpedia, …) and the launch-morning platforms (Uneed/Fazier/MicroLaunch/OpenHunts), plus parked ideas (Claude Code plugin, MacPorts). Reddit copy: `~/Desktop/lockpaw-claudeai-post.md` (the old `~/Desktop/lockpaw-reddit/POSTS.txt` is lost). ⚠️ This file is public — Reddit account identity, post history, and per-sub filter intel live in `memory/project_reddit_account.md` only; never name the Reddit account in committed files.
- **`SECURITY.md`** — Security policy: threat-model caveat, latest-release-only support, private vulnerability reporting (enabled on the repo 2026-06-12)
- **`.github/ISSUE_TEMPLATE/`** — Bug report and feature request templates (YAML)
- **`.github/FUNDING.yml`** — Buy Me a Coffee link
- **`.github/dependabot.yml`** — monthly GitHub Actions version bumps (actions only — no tracked Package.swift/Package.resolved, so SPM/Sparkle can't be tracked; xcodeproj is gitignored)

## Repo-level directories

- **`assets/`** — `demo.gif` hero GIF for README (18s agent-ping story: Claude Code working → lock → teal glow ping → unlock, annotated with Settings-style badges + branded end card; 800px wide, updated 2026-06-11); `hero.png` agent-angle key art (README hero + website OG + repo social preview). The same cut ships as `demo.mp4` on the website (played at 1×; pacing is edited into the cut).
- **`scripts/`** — `build-release.sh`, DMG background PNGs, volume icon
- **`homebrew/`** — Local copy of Homebrew cask (canonical version in `sorkila/homebrew-lockpaw`)
- **`lockpaw-web/`** — local checkout of `sorkila/lockpaw-web` (the live getlockpaw.com site; gitignored in this repo, has its own CLAUDE.md)

## Awesome list submissions

Lockpaw has been submitted to the following curated lists. **⚠️ Never delete a fork until its PR is merged** — the 2026-04-19 fork cleanup deleted forks for 13 still-open PRs, which GitHub auto-closed. All 13 were resubmitted from fresh forks on 2026-06-11 (rows below); the forks live under `sorkila/` and stay until each PR merges, then delete:

| Repo | PR | Category | Status |
|---|---|---|---|
| `jaywcjlove/awesome-mac` | #1901 | Security Tools | Merged |
| `jaywcjlove/awesome-swift-macos-apps` | #27 | Security | Merged |
| `xyNNN/awesome-mac` | #29 | Security | Merged |
| `phmullins/awesome-macos` | #199 | Security | Pending (resubmitted 2026-06-11, was #158) |
| `milanaryal/awesome-macos` | #12 | Utilities | Pending (resubmitted 2026-06-11, was #7; fork is `sorkila/awesome-macos-milanaryal` due to name collision) |
| `iCHAIT/awesome-macOS` | #731 | Security | Merged |
| `open-saas-directory/awesome-native-macosx-apps` | #87 | Security & Privacy | Pending (resubmitted 2026-06-11, was #48) |
| `SKaplanOfficial/Mac-Menubar-Megalist` | #18 | Security | Pending (resubmitted 2026-06-11, was #11) |
| `ashishb/osx-and-ios-security-awesome` | #48 | macOS Security | Merged |
| `jeffreyjackson/mac-apps` | #79 | Mac Interface Exclusives | Merged |
| `kai5263499/osx-security-awesome` | #24 | Useful tools and guides | Merged |
| `drduh/macOS-Security-and-Privacy-Guide` | #532 | Related software | Pending (resubmitted 2026-06-11, was #523) |
| `tonnoz/super-awesome-mac` | #7 | Utils | Pending (resubmitted 2026-06-11, was #3) |
| `guyzyl/awesome-macos-apps` | #25 | Utilities | Pending (resubmitted 2026-06-11, was #19) |
| `serhii-londar/open-source-mac-os-apps` | #1062 | Security + Menubar | Closed |
| `matteocrippa/awesome-swift` | #1899 | Security | Rejected (libraries only) |
| `Wolg/awesome-swift` | #283 | Security | Closed |
| `Lissy93/awesome-privacy` | #444 | Mac OS Defences | Rejected (project too new) |
| `pluja/awesome-privacy` | #859 | Desktop | Pending (resubmitted 2026-06-11, was #731) |
| `onmyway133/awesome-swiftui` | #29 | Open source apps > macOS | Merged |
| `linsa-io/macos-apps` | #54 | Utilities | Pending (resubmitted 2026-06-11, was #40) |
| `johnjago/awesome-free-software` | #130 | Utilities | Pending (resubmitted 2026-06-11, was #100) |
| `unicodeveloper/awesome-opensource-apps` | #183 | Swift | Pending (resubmitted 2026-06-11, was #162; PR also restores the list README clobbered by their #149) |
| `sbilly/awesome-security` | #594 | Endpoint > Authentication | Pending (resubmitted 2026-06-11, was #471) |
| `ishanvyas22/awesome-open-source-systems` | #24 | Security | Pending (resubmitted 2026-06-11, was #16) |
| `Piebald-AI/awesome-gemini-cli` | #58 | Development Tools & Utilities | Pending (submitted 2026-06-12; list merges actively) |
| `RoggeOhta/awesome-codex-cli` | #88 | GUI & Desktop Apps | Pending (submitted 2026-06-12; ⚠️ list has never merged a PR) |
| `hesreallyhim/awesome-claude-code` | issue #2015 | Tooling | Pending (submitted 2026-06-12 via their issue form — PRs banned; bot validation passed, awaiting maintainer review) |

## Directory listings

| Site | Category | Status |
|---|---|---|
| MacUpdate | Security | Resubmitted 2026-06-11 (icon + screenshots), awaiting review — first submission never went live |
| AlternativeTo | Screen Lock | Live: [alternativeto.net/software/lockpaw](https://alternativeto.net/software/lockpaw/) (zero likes/reviews yet) |

Queued (browser forms, ready-to-paste copy in MARKETING.md round-2 section): MacMenuBar.com, macosmenubar.com, OpenAlternative, opensourcealternative.to, Softpedia — anytime; Uneed/Fazier/MicroLaunch/OpenHunts — save for the coordinated launch morning. Repo topics include `claude-code` (added 2026-06-12) since auto-curated lists scrape by topic. Skipped deliberately: jqueryscript/awesome-claude-code (never merges PRs), Console.dev (pre-1.0 tools only), AI-tool directories (wrong category).
