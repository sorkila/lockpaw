import SwiftUI
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "App")

@main
struct LockpawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lockController = LockController()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: lockController)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(lockController.state == .locked ? 1.0 : 0.55)
        }

        Settings {
            SettingsView(viewModel: appDelegate.updateCheckViewModel)
        }
    }

    init() {
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            AccessibilityChecker.promptIfNeeded()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let updateCheckViewModel = UpdateCheckViewModel()
    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updateCheckViewModel, userDriverDelegate: nil)
    }()
    private let hotkeyManager = HotkeyManager()
    private var hotkeyObserver: Any?
    private var lastURLSchemeCall: Date = .distantPast
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start Sparkle after app is fully launched
        updateCheckViewModel.bind(to: updaterController.updater)
        do {
            try updaterController.updater.start()
        } catch {
            logger.error("Sparkle updater failed to start: \(error.localizedDescription)")
        }

        // Apply saved appearance
        let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }

        // Only register hotkey if onboarding is complete (Accessibility granted).
        // Otherwise, wait for onboarding to finish and post the notification.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            let enabled = HotkeyConfig.enabled
            hotkeyManager.setEnabled(enabled)
        }

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .lockpawHotkeyPreferenceChanged, object: nil, queue: nil
        ) { [weak self] notification in
            DispatchQueue.main.async {
                if let enabled = notification.userInfo?["enabled"] as? Bool {
                    self?.hotkeyManager.setEnabled(enabled)
                } else {
                    // Key combo changed or onboarding completed — re-register.
                    // Delay to let Settings activate the event pipeline first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.hotkeyManager.reregister()
                    }
                }
            }
        }

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        let view = OnboardingView(hasCompletedOnboarding: Binding(
            get: { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding")
                if newValue {
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                }
            }
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Lockpaw"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let now = Date()
        guard now.timeIntervalSince(lastURLSchemeCall) > Constants.Timing.urlSchemeDebounce else { return }
        lastURLSchemeCall = now

        for url in urls {
            guard url.scheme == Constants.urlScheme else { continue }
            switch url.host {
            case "lock": NotificationCenter.default.post(name: .lockpawLock, object: nil)
            case "unlock": NotificationCenter.default.post(name: .lockpawUnlock, object: nil)
            case "unlock-password": NotificationCenter.default.post(name: .lockpawUnlockPassword, object: nil)
            case "toggle": NotificationCenter.default.post(name: .toggleLockpaw, object: nil)
            default: logger.warning("Unknown URL scheme: \(url.host ?? "nil")")
            }
        }
    }

    deinit {
        if let obs = hotkeyObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
