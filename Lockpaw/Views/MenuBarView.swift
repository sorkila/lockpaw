import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: LockController
    @ObservedObject private var supportAsk = SupportAskController.shared
    @ObservedObject private var sessionMonitor = AgentSessionMonitor.shared
    /// Session ages are read when the menu opens.
    @State private var now = Date()

    var body: some View {
        Group {
            if controller.state == .unlocked {
                Button {
                    controller.lock()
                } label: {
                    Label("Lock Screen", systemImage: "lock.fill")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            } else {
                Button {
                    controller.requestUnlock()
                } label: {
                    Label("Unlock with Password", systemImage: "keyboard")
                }

                Divider()

                Label {
                    Text("Locked for \(Constants.formatElapsedTime(controller.elapsedTime))")
                        .foregroundStyle(.primary.opacity(0.7))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            // The session board, one plain line per Claude session. The menu is the user's
            // own, so folder names are fine here.
            if !sessionMonitor.sessions.isEmpty {
                Divider()

                Section("Claude Sessions") {
                    ForEach(sessionMonitor.sessions) { session in
                        Text(session.menuLine(now: now))
                    }
                }
            }

            if controller.state == .unlocked, supportAsk.isShowing {
                Divider()

                Text("Lockpaw kept watch while your agents worked.")
                Button("Support Lockpaw\u{2026}") { supportAsk.support() }
                Button("Not Now") { supportAsk.notNow() }
                Button("Don\u{2019}t Ask Again") { supportAsk.neverAsk() }
            }

            Divider()

            SettingsLink {
                Text("Settings\u{2026}")
            }
            .keyboardShortcut(",")

            Button("Quit Lockpaw") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        // The menu is the ask's only surface, so let a week-old ask lapse when it opens.
        .onAppear {
            supportAsk.refresh()
            now = Date()
        }
    }
}
