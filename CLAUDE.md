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
- **Current version:** 1.3.1
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

96 unit tests covering LockState transitions, Constants formatting, HotkeyConfig conflict detection/auth-required unlock preference, SleepPreventer state handling, Mascot resolution (incl. the `hidden` case), PingDecision agent-ping branching, FadeToBlack preference resolution (checkbox × delay), every branch of the PresentationLogic fade-to-black reducer, and TerminationPolicy (quit refused unless `.unlocked`).

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
│   ├── PresentationController.swift  Fade-to-black effects — timer slot, NSEvent monitors, cross-fades
│   └── AgentNotifier.swift         UNUserNotificationCenter — "your agent needs you" (lazy auth)
├── Models/
│   ├── LockState.swift             .unlocked → .locking → .locked → .unlocking
│   ├── HotkeyConfig.swift          Centralized hotkey UserDefaults + system conflict detection/auth unlock preference
│   ├── Mascot.swift                Dog/cat lock-screen mascot preference
│   ├── FadeToBlack.swift           Fade-to-black preference + pure presentation reducer (LockPresentation / PresentationLogic)
│   └── PingDecision.swift          Pure agent-ping decision (state + sound pref → pulse/notify/sound)
├── Views/
│   ├── OverlayRootView.swift       Per-screen presentation switch — lock UI / pure black / attention pulse
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
├── FadeToBlackTests.swift          Fade-to-black checkbox/delay resolution + timeout mapping (11 tests)
├── PresentationLogicTests.swift    Presentation reducer: blackout/reveal/pulse/error branches (30 tests)
├── MascotTests.swift               Mascot resolution incl. hidden (5 tests)
├── TerminationPolicyTests.swift    Quit guard + LockStatus mirror (3 tests)
└── AgentPingTests.swift            PingDecision branching: locked/unlocked × sound (6 tests)

LockpawCLI/                         (sibling of Lockpaw/)
└── main.swift                      `lockpaw` CLI: ping / install-cli / install-hook <claude|codex|gemini|cursor|copilot|aider>
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
- **Primary vs ambient screens** — `OverlayWindowManager.showOverlay` takes a content factory `(Int, Bool) -> AnyView`. Every screen gets an `OverlayRootView`; while presentation is `.visible` the primary (or all screens in Mirror mode) shows the full lock screen and secondaries show `AmbientScreenView`.
- **AmbientScreenView uses 5 morphing gradient blobs** — ellipses with solid fills at low opacity, heavy blur, on independent orbital paths. 3-second fade-in from black.

### Fade to black (display protection)
- **Why not real display sleep** — macOS's "require password after display off" locks the GUI session when the display sleeps, which revokes Accessibility from session apps: the hotkey taps die and agent automation breaks. Fade to black paints pure black over an *awake* display instead — OLED pixels off, session (and agents) fully alive. Off by default; a Settings → Lock Screen checkbox reveals a "Fade delay" row (1/5/10 min), mirroring the "Show lock message" → "Message" pattern.
- **Presentation is a pure reducer, separate from LockState** — `PresentationLogic.reduce` (Models/FadeToBlack.swift) maps (presentation, armed timer, event, timeout) → decision; `PresentationController` only runs the effects. No presentation bug can touch the security-relevant lock state, and every branch is unit-tested.
- **Single one-shot timer slot** — arming always invalidates the previous timer, so stale blackout/re-black fires are structurally impossible. A Combine sink on `$state` arms on every `.locked` entry (including re-entry after failed auth) and forces `.visible` + cancel on `.unlocking`; a sink on `$lastError` reveals errors and re-arms the configured fade delay as the re-black window (every reveal — input or error — reuses that one delay; there is no separate reveal constant) — cancelling instead would disarm protection for the rest of the session under auth rate limiting, which never leaves `.locked`.
- **`.lockpawPhysicalInput` side channel** — InputBlocker's tap swallows keyboard/scroll before NSEvent monitors can see them, so the tap posts this (throttled) for physical events; mouse arrives via NSEvent global+local monitors in PresentationController.
- **Physical vs synthetic: `eventSourceUnixProcessID == 0`** — hardware events carry PID 0; synthetic posts carry the poster's PID, so agent automation (cliclick, AppleScript) never lights the screen. Best-effort: remappers (Karabiner/BTT) repost under their own PID and won't reveal — the unlock hotkey ignores the filter, so recovery always works.
- **The reveal click is consumed** — the local monitor returns nil for mouseDowns while not `.visible`, so the click that wakes the screen can never press the just-mounted auth button (the orphaned mouseUp is harmless).
- **The attention pulse runs on every screen** — the primary lock UI is unmounted while black, so a ping breathes the lock screen's teal glow everywhere (`AttentionPulseView`, keyed by `attentionGeneration` so re-pings restart the breaths) for a bounded `Timing.attentionPulse`, then settles back to black. `agentAttention` survives blackness; on reveal the caption + resting glow appear (LockScreenView seeds `pingGlow` on appear). Under Reduce Motion the glow holds static at the pulse floor.
- **The pointer stays with OverlayWindowManager's concealment in every presentation state** — fade-to-black adds no cursor calls of its own. An earlier revision hid via `NSCursor.hide()` while black, but mixing `hide()`/`unhide()` with `setHiddenUntilMouseMoves` is documented-unpredictable and in practice kills the idle re-hide for the rest of the session after the first reveal. Accepted trade: a synthetic mouse nudge can show the pointer over black for ~`Timing.cursorIdleHide` seconds before it re-conceals (the screen itself stays black — the PID filter ignores synthetic input).
- **`stop()` leaves `presentation` untouched** — unlocking from black fades the overlay out from black with no lock-UI flash; the next `start()` resets it. `OverlayRootView`'s constant black backdrop is load-bearing: overlay windows have clear backgrounds, so the 6s cross-fade would otherwise blend through to the desktop.
- **Fades are explicit opacity, NOT removal transitions** — `.transition(.opacity)` on a switched-out branch hard-cuts inside `NSHostingView` overlay windows on macOS 26 (verified on hardware; the PR's original transition-based version cut straight to black). `OverlayRootView` animates `@State` opacity values via `withAnimation` and unmounts the subtree only after the fade completes (generation-guarded `asyncAfter`), preserving the nothing-rendered-while-black property.

### Agent alerts (the `lockpaw` CLI ping)
- **Purpose** — when an AI agent (Claude Code, Codex, Gemini) pauses for permission or finishes while the screen is locked, the lock screen glows + a notification fires. Stays locked; you unlock when ready.
- **Transport is DistributedNotificationCenter, NOT `lockpaw://`** — `open lockpaw://ping` would launch the app when it isn't running (wrong for a background ping). The CLI posts `com.eriknielsen.lockpaw.ping`; `AppDelegate` bridges it to a local `.lockpawPing`. The URL scheme stays for `lock`/`unlock` only.
- **`PingDecision.make(state:soundEnabled:)` is pure** — locked → pulse + notify; any other state → no-op. Unit-tested directly (no UNUserNotificationCenter mocking). `LockController.handlePing()` debounces (`Timing.pingDebounce`) then applies the decision; `pingPulse` is a counter the lock screen watches via `.onChange`.
- **Glow is the hero, not the banner** — on ping, `LockScreenView` breathes a saturated teal full-screen radial bloom (`pingPulseCount` breaths of `pingPulsePeriod`, mid-stop gradient + `.plusLighter`), then settles to a faint resting glow (`pingGlowRest`) with a standing "Your agent needs you" caption (`LockController.agentAttention`) until unlock. A generation counter cancels a stale pulse chain if a new ping lands mid-sequence. Notification is secondary; delivered banners are cleared on unlock (`AgentNotifier.clearDelivered()`). Sound is opt-in (`Constants.agentPingSoundKey`, default off, for shared offices).
- **Cursor hides while locked** — `OverlayWindowManager` activates the app, makes the primary overlay key (`OverlayWindow` subclass: borderless windows refuse key status by default), then `NSCursor.setHiddenUntilMouseMoves(true)` — which is a no-op unless the app is active. Mouse-move monitors + an idle timer (`Timing.cursorIdleHide`) re-hide after stillness. Never `NSCursor.hide()` — an unbalanced hide would leave the pointer invisible over the auth button, and even a balanced one breaks `setHiddenUntilMouseMoves` re-hides for the rest of the session (see the fade-to-black pointer note above).
- **Lock-screen type uses four tokens** — `Font.lockBody/lockLabel/lockCaption/lockMono` in Constants.swift map to the DESIGN.md §2 scale; differentiate captions with opacity, never new sizes.
- **The CLI lives in `Contents/SharedSupport/`, NOT `Contents/MacOS/`** — `lockpaw` would collide with the app binary `Lockpaw` on case-insensitive filesystems (DMG/Applications). `install-cli` symlinks it into `~/.local/bin`.
- **The CLI target sets `PRODUCT_MODULE_NAME: LockpawCLI`** (executable stays `lockpaw`) — its Swift module would otherwise be `lockpaw`, which case-collides with the app's `Lockpaw` module and breaks `@testable import Lockpaw` on a clean build (`unable to resolve module dependency: 'Lockpaw'`). This only surfaces on a clean build (CI), not incremental local ones.
- **CLI resolves `$HOME`, not `homeDirectoryForCurrentUser`** — the latter ignores `$HOME`; agent CLIs locate their own configs via `$HOME`, so `install-hook` must too. Writers back up (`.bak`), are idempotent, and never clobber a foreign `notify`/hook.
- **`install-hook` is self-contained** — it ensures the `~/.local/bin/lockpaw` symlink exists (`ensureCLISymlink()`, shared with `install-cli`) and writes PATH-independent commands: Claude/Gemini/Copilot get `"$HOME/.local/bin/lockpaw" ping` (their hook commands run through a shell, which expands `$HOME` — Copilot via the `bash` key); Codex, Cursor, and Aider get the literal absolute symlink path (Codex `notify` is argv-executed with no shell; Cursor and Aider don't document a shell guarantee, and the literal path works either way). Bare `lockpaw ping` silently failed for anyone who skipped `install-cli` or lacked `~/.local/bin` on PATH. Re-running upgrades any older lockpaw entry in place (`isLockpawPingCommand` matches loosely).
- **Six hookable agents (since v1.2.0)** — Claude (`Notification`+`Stop`, `~/.claude/settings.json`), Codex (`notify`, `~/.codex/config.toml` — its richer hooks.json is still feature-flagged upstream, so `notify` stays), Gemini (`Notification`+`AfterAgent`, `~/.gemini/settings.json` — adopted Claude's hook schema, shared merge via `mergingPingHook`), Cursor (`stop`, `~/.cursor/hooks.json` — flat schema, command at group level), Copilot CLI (`agentStop`+`notification` in an owned file `~/.copilot/hooks/lockpaw.json`, honors `$COPILOT_HOME` — the CLI loads every `*.json` in that dir, so no foreign-config merging), Aider (`notifications: true` + `notifications-command` in `~/.aider.conf.yml`, dashed YAML keys per aider's sample config; both keys written because docs don't promise the command implies enabling).
- **`install-hook claude` honors `$CLAUDE_CONFIG_DIR`** — falls back to `~/.claude`. Users running multiple Claude Code profiles (e.g. `CLAUDE_CONFIG_DIR=~/.claude-personal`) get the hook in the right settings.json.
- **Settings → General has one-click agent setup** — buttons run the bundled CLI (`SharedSupport/lockpaw`) via `Process` off the main thread: Install (install-cli) plus a 3×2 grid of Claude/Codex/Gemini/Cursor/Copilot/Aider (install-hook — all real writers since v1.2.0; the old Gemini copy-snippet path and its pasteboard plumbing are gone). Exit ≠ 0 or a ⚠️ on stdout (foreign Codex `notify` / Aider `notifications-command`) shows as a failure with the message under the row — the button never claims success for a write that didn't happen. Note: the GUI app launches without `CLAUDE_CONFIG_DIR`, so one-click Claude setup targets `~/.claude`; multi-profile users should run `install-hook` from their terminal.
- **build-release.sh signs the CLI inside-out** — `Contents/SharedSupport/lockpaw` is signed before the outer app, same `/tmp` copy treatment as the rest (iCloud xattr gotcha).

### Quit guard, hidden icon, no mascot (v1.3.1)
- **Quit is refused while guarded** — `AppDelegate.applicationShouldTerminate` returns `.terminateCancel` unless `TerminationPolicy.allowsQuit(state:)` (pure, tested: only `.unlocked`). Why: the overlay makes Lockpaw the active app and the menu's Quit carries an app-wide Cmd+Q; the input tap normally swallows it, but macOS enables **secure input while the LAContext password sheet is up, and secure input hides keystrokes from event taps** — so Cmd+Q reached the app and quit it (reported in #10 by @moonlit-ds). `LockStatus.shared` mirrors `LockController.state` (a `didSet`) so the delegate can read it without a controller reference. `.terminateCancel` also blocks logout/shutdown while locked — accepted, that is what a lock does; ssh `shutdown` bypasses app replies anyway.
- **Menu bar icon is optional** — `MenuBarExtra(isInserted:)` bound to `Constants.showMenuBarIconKey` (default on). Ways back in when hidden: the hotkey, the CLI, `lockpaw://settings`, and **reopening the app** (`applicationShouldHandleReopen` re-enables the icon and opens Settings via the `showSettingsWindow:` selector — SwiftUI's Settings scene has no opener outside a View). Onboarding never hides it. (#14)
- **Mascot `.hidden` (raw value "none")** — `assetName` is optional; the lock screen, onboarding hero and Settings preview all branch on it. Named `hidden`, not `none`, so call sites never collide with `Optional.none`. (#8, #9)

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

- **GitHub Actions CI** — build + 96 tests on `macos-15` runners (Xcode 16) on push to main and PRs (`.github/workflows/ci.yml`). Uses `actions/checkout@v7`.
- **Release workflow** — tag `v*` → build → conditional sign/notarize (inside-out, not `--deep`) → branded DMG via `create-dmg` with Finder alias → GitHub Release (`.github/workflows/release.yml`). Handles pre-existing releases gracefully. **Note:** signing/notarization only runs if signing secrets are set — they are **not** currently configured, so a tag push creates a release but no signed DMG. Sign/notarize locally (or add the secrets).
- **Latest release** — v1.3.0 released 2026-08-24 (build 14). DMG SHA-256: `9b1df1d26c433c18f1921f09390b04c3a806015c0fdb07c4c12ed6ca3e694251`. Fade to black display protection (contributed in #15 by @swbiggart; follow-up `40e9f1f` fixed removal-transition hard cuts on macOS 26). Full branded DMG. ⚠️ First release build after the repo moved out of iCloud failed on stale SPM artifacts pointing at the old `~/Documents` path — `rm -rf build/DerivedData` fixed it.
- **Sparkle auto-updates** — EdDSA-signed appcast at `https://getlockpaw.com/appcast.xml`, download URL points to GitHub Releases. Advertises **v1.3.0 / build 14**. ⚠️ The 1.1.1 appcast entry's enclosure is `https://getlockpaw.com/Lockpaw.dmg` and `lockpaw-web/Lockpaw.dmg` still holds the 1.1.1 bytes — do NOT overwrite that file with a newer DMG or the 1.1.1 entry's EdDSA signature stops matching for old clients.
- **Homebrew cask** — tap repo at `sorkila/homebrew-lockpaw`, install via `brew tap sorkila/lockpaw && brew install --cask lockpaw`. The tap and checked-in `homebrew/Casks/lockpaw.rb` are current at **v1.3.0** (uses modern `depends_on macos: :sonoma`). Homebrew core submission [Homebrew/homebrew-cask#259932](https://github.com/Homebrew/homebrew-cask/pull/259932) was closed 2026-04-18 for notability requirements; resubmit once the app meets Homebrew's thresholds.
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
- **`MARKETING.md`** — go-to-market plan (gitignored/local — competitive positioning; not committed). Rewritten 2026-06-11 as the v1.1.1 relaunch plan; Phase 0 closed. Reddit seeding started 2026-06-11 (r/ClaudeAI + r/vibecoding); PH/HN/X still open. 2026-06-12: "round 2" directory/list section added — ready-to-paste copy for the web-form directories (MacMenuBar, OpenAlternative, Softpedia, …) and the launch-morning platforms (Uneed/Fazier/MicroLaunch/OpenHunts), plus parked ideas (Claude Code plugin, MacPorts). 2026-08-18: August outreach round executed — drafts + statuses in the gitignored `OUTREACH-DRAFTS-2026-08.md`. Reddit copy: `~/Desktop/lockpaw-claudeai-post.md` (the old `~/Desktop/lockpaw-reddit/POSTS.txt` is lost). ⚠️ This file is public — Reddit account identity, post history, and per-sub filter intel live in `memory/project_reddit_account.md` only; never name the Reddit account in committed files.
- **`backlog.md`** — feature backlog (gitignored/local — carries competitive intel). Living idea list judged against the ambient-signal wedge; August 2026 research pass. Tier 1 keystone: typed pings + semantic glow.
- **`OUTREACH-DRAFTS-2026-08.md`** — outreach drafts + send statuses (gitignored/local). August round sent 2026-08-18.
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
| `hesreallyhim/awesome-claude-code` | issue #2015 | Tooling | Pending (submitted 2026-06-12 via their issue form — PRs banned; bot validation passed, awaiting maintainer review; status-update comment posted 2026-08-18 via browser) |

## Directory listings

| Site | Category | Status |
|---|---|---|
| MacUpdate | Security | Resubmitted 2026-06-11 (icon + screenshots), awaiting review — first submission never went live |
| AlternativeTo | Screen Lock | Live: [alternativeto.net/software/lockpaw](https://alternativeto.net/software/lockpaw/) (zero likes/reviews yet) |

Queued (browser forms, ready-to-paste copy in MARKETING.md round-2 section): MacMenuBar.com, macosmenubar.com, OpenAlternative, opensourcealternative.to, Softpedia — anytime; Uneed/Fazier/MicroLaunch/OpenHunts — save for the coordinated launch morning. Repo topics include `claude-code` (added 2026-06-12) since auto-curated lists scrape by topic. Skipped deliberately: jqueryscript/awesome-claude-code (never merges PRs), Console.dev (pre-1.0 tools only), AI-tool directories (wrong category).

## Portfolio context (2026-08-25)

Lockpaw is a reputation piece in a portfolio plan targeting 100 000 kr/month in side income (Sorkila session artifacts: "The Demand Ledger"). Research verdict: the agent-companion lane was nativised (Claude Code hooks, desktop app with parallel sessions/worktrees, Remote Control; Codex app with worktrees) or VC-subsidised, and Terragon, Bloop, Crystal and Omnara folded in 2026. Treat Lockpaw as pipeline for consulting, not a revenue line. A paid tier was measured: cross-agent status/notification asks **halved** since March 2026 (free tools filled them; CodexBar +5 549 stars in 67 days), so a paid status/menu-bar product is saturated. The one measured unmet need is a **Claude Code transcript/session-history vault** (r/ClaudeCode "transcript" posts 9/month in January → 88 peak in July), a $19 one-time Mac tool sold direct via r/macapps and brew, which could live in Tintpad or Lockpaw. Per-app locks and scheduled lockouts (r/macapps FaceGate 142↑) remain a plausible small Lockpaw Pro. Nothing decided.
