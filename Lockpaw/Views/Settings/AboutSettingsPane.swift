import SwiftUI

private let sponsorsURL = URL(string: "https://github.com/sponsors/sorkila")!
private let creatorURL = URL(string: "https://sorkila.com")!

/// About: the version and updates, the supporter licence, who makes it, and the honest
/// note about what kind of lock this is.
struct AboutSettingsPane: View {
    @ObservedObject var updates: UpdateCheckViewModel
    @ObservedObject private var supporter = Supporter.shared
    @State private var licenceKey = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lockpaw").font(.title3.weight(.semibold))
                        Text(versionText).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if supporter.isSupporter {
                        Label("Supporter", systemImage: "heart.fill")
                            .foregroundStyle(settingsAccentColor)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent {
                    Button {
                        updates.checkForUpdates()
                    } label: {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(!updates.canCheckForUpdates || updates.isChecking)
                } label: {
                    SettingLabel("Updates", detail: updateDetail)
                }

                Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.setChecksAutomatically($0) })) {
                    SettingLabel("Check for updates automatically", detail: "Once a day. Every update is signed, and you're asked before it installs.")
                }

                Toggle(isOn: Binding(get: { updates.downloadsAutomatically }, set: { updates.setDownloadsAutomatically($0) })) {
                    SettingLabel("Install updates automatically", detail: "Downloads in the background and installs the next time Lockpaw quits.")
                }
                .disabled(!updates.checksAutomatically)
            }

            Section {
                if supporter.isSupporter {
                    LabeledContent {
                        Button("Remove Licence", role: .destructive) { supporter.removeLicence() }
                    } label: {
                        SettingLabel("Supporter licence", detail: supporter.message ?? "Thank you. Your licence is saved on this Mac.")
                    }
                } else {
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("Licence key", text: $licenceKey, prompt: Text("LOCKPAW-\u{2026}"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .onSubmit { supporter.enter(key: licenceKey) }
                            Button {
                                supporter.enter(key: licenceKey)
                            } label: {
                                if supporter.isChecking { ProgressView().controlSize(.small) } else { Text("Activate") }
                            }
                            .disabled(licenceKey.trimmingCharacters(in: .whitespaces).isEmpty || supporter.isChecking)
                        }
                    } label: {
                        SettingLabel("Supporter licence", detail: supporter.message ?? "Paste the key from your receipt.")
                    }

                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("Sponsor on GitHub") { NSWorkspace.shared.open(sponsorsURL) }
                            Button("Become a Supporter") { NSWorkspace.shared.open(SupporterLicence.supportPageURL) }
                        }
                    } label: {
                        SettingLabel("Support Lockpaw", detail: "It's free and stays free. Supporters get four extra mascots and seasonal outfits as a thank-you.")
                    }
                }
            } header: {
                Text("Supporter")
            }

            Section {
                LabeledContent("Made by") {
                    Link("Erik Nielsen", destination: creatorURL)
                }
            } footer: {
                Text("Lockpaw covers your screen and blocks the keyboard while you're away. It isn't a replacement for your Mac's own lock screen (Control-Command-Q).")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane(.about)
        .onAppear { updates.refreshAutoUpdate() }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)): return "Version \(version) (\(build))"
        case let (.some(version), .none): return "Version \(version)"
        case let (.none, .some(build)): return "Build \(build)"
        default: return "Version unknown"
        }
    }

    private var updateDetail: String? {
        switch updates.updateStatus {
        case .upToDate: return "You're up to date."
        case .available(let version): return "Version \(version) is available."
        case .error(let message): return message
        case nil: return nil
        }
    }
}
