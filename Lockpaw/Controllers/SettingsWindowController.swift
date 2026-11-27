import AppKit
import SwiftUI

/// Owns the Settings window. SwiftUI's `Settings` scene can only be opened from a View
/// (`SettingsLink` / `openSettings`); on macOS 26 the old `showSettingsWindow:` route is
/// refused ("Please use SettingsLink"), which silently broke `lockpaw://settings`, reopening
/// the app with the menu bar icon hidden, and every in-app "Open Settings". A window we own
/// opens the same way from anywhere: the menu, the app delegate, the supporter card.
///
/// The panes sit in a toolbar-style `NSTabViewController`, the native preferences layout:
/// the toolbar always shows the active pane, the window title follows it, and the window
/// reopens on the pane last viewed.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Set once at launch; the Updates row reads Sparkle's state through it.
    var updateCheckViewModel: UpdateCheckViewModel?

    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    func show(_ section: SettingsSection? = nil) {
        // Never over a lock: Settings would take activation and the keyboard from the
        // lock screen's password field.
        guard LockStatus.shared.state == .unlocked else { return }
        // An accessory app's window can't come to the front or take the keyboard.
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        if let section { tabs?.select(section) }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController(updates: updateCheckViewModel ?? UpdateCheckViewModel())
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        // Sized by the pane, so no zoom or resize; a settings window has nothing to minimise to.
        // Full-size content: on macOS 26 each form's scroll view keeps a blurred "scroll
        // pocket" a toolbar tall at its top, meant to sit under the toolbar. Without this
        // the pane started below the toolbar and the pocket covered its first rows instead.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// Closing tears the panes down. A closed NSWindow keeps its hosted SwiftUI views alive
    /// and never fires `onDisappear`, so without this the relay fields were never committed
    /// to the Keychain, the shortcut recorder could keep listening, and the panes' polling
    /// ran for the life of the app. The next `show()` builds a fresh window on the last pane.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.contentViewController = nil
            self.window = nil
            self.tabs = nil
        }
    }
}

/// Toolbar tabs, one SwiftUI pane each. Remembers the last pane across launches.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private static let lastPaneKey = "settingsLastPane"

    init(updates: UpdateCheckViewModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for section in SettingsSection.allCases {
            let pane = NSHostingController(rootView: SettingsPane(section: section, updates: updates))
            pane.sizingOptions = [.preferredContentSize]
            pane.title = section.title
            let item = NSTabViewItem(viewController: pane)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.systemImage, accessibilityDescription: section.title)
            item.identifier = section.rawValue
            addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsSection.init(rawValue:))
        select(saved ?? .general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ section: SettingsSection) {
        guard let index = SettingsSection.allCases.firstIndex(of: section) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastPaneKey)
        }
    }
}

/// Routes a section to its pane.
private struct SettingsPane: View {
    let section: SettingsSection
    let updates: UpdateCheckViewModel

    var body: some View {
        switch section {
        case .general: GeneralSettingsPane()
        case .lockScreen: LockScreenSettingsPane()
        case .agents: AgentSettingsPane()
        case .about: AboutSettingsPane(updates: updates)
        }
    }
}
