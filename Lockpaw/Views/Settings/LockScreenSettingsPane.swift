import SwiftUI
import UniformTypeIdentifiers

/// Lock Screen: what the cover shows. The mascot and its live preview first, then the
/// message, the other displays and the wallpaper, then fade to black. Sub-options only
/// appear once their parent is on.
struct LockScreenSettingsPane: View {
    @AppStorage(Mascot.storageKey) private var selectedMascot = Mascot.defaultValue
    @AppStorage(SeasonalSkin.enabledKey) private var seasonalMascots = true
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("multiDisplayMode") private var multiDisplayMode = 0 // 0 = Ambient, 1 = Mirror
    @AppStorage(DesktopWallpaper.enabledKey) private var showDesktopWallpaper = DesktopWallpaper.defaultEnabled
    @AppStorage(WallpaperMotion.storageKey) private var wallpaperMotion = WallpaperMotion.defaultValue
    @AppStorage(FadeToBlack.enabledKey) private var fadeToBlackEnabled = FadeToBlack.defaultEnabled
    @AppStorage(FadeToBlack.storageKey) private var fadeToBlackDelay = FadeToBlack.defaultValue
    @AppStorage(TokenCounterPreference.showKey) private var showTokenCounter = TokenCounterPreference.defaultShow

    @ObservedObject private var customMascot = CustomMascot.shared
    @ObservedObject private var supporter = Supporter.shared
    @State private var customMascotError: String?

    var body: some View {
        Form {
            Section {
                MascotPreview(mascot: Mascot.effective(from: selectedMascot), showsMessage: showMessage, message: message,
                              showsTokenCounter: showTokenCounter)
                    .listRowInsets(EdgeInsets())

                if mascotChoices.count > 5 {
                    Picker("Mascot", selection: $selectedMascot) { mascotOptions }
                        .pickerStyle(.menu)
                } else {
                    Picker("Mascot", selection: $selectedMascot) { mascotOptions }
                        .pickerStyle(.segmented)
                }

                if Mascot.resolved(from: selectedMascot) == .custom {
                    LabeledContent {
                        HStack(spacing: 8) {
                            if customMascot.hasImage {
                                Button("Remove") {
                                    customMascot.remove()
                                    customMascotError = nil
                                }
                            }
                            Button(customMascot.hasImage ? "Replace\u{2026}" : "Choose\u{2026}") { chooseCustomImage() }
                        }
                    } label: {
                        SettingLabel("Image", detail: customMascotError ?? "PNG, JPEG or HEIC. A transparent background looks best.")
                    }
                }

                if supporter.isSupporter {
                    Toggle(isOn: $seasonalMascots) {
                        SettingLabel("Seasonal outfits", detail: "The dog and cat dress up for the holidays.")
                    }
                }
            }

            Section("Message") {
                Toggle("Show a message", isOn: $showMessage)
                if showMessage {
                    TextField("Message", text: $message, prompt: Text(Constants.defaultLockMessage), axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: message) { _, newValue in
                            if newValue.count > 120 { message = String(newValue.prefix(120)) }
                        }
                }
            }

            Section("Token counter") {
                Toggle(isOn: $showTokenCounter) {
                    SettingLabel("Show token usage", detail: "Reads Claude Code and opencode usage on this Mac and shows it on the lock screen.")
                }
            }

            Section("Background") {
                Toggle(isOn: $showDesktopWallpaper) {
                    SettingLabel("Desktop wallpaper", detail: "Show your wallpaper behind the lock screen, Aerials included.")
                }
                .onChange(of: showDesktopWallpaper) { _, isOn in
                    if isOn { WallpaperController.requestAccessToStills() }
                }

                if showDesktopWallpaper {
                    Picker("Aerials move", selection: $wallpaperMotion) {
                        ForEach(WallpaperMotion.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Picker(selection: $multiDisplayMode) {
                    Text("Ambient").tag(0)
                    Text("Mirror").tag(1)
                } label: {
                    SettingLabel("Other displays", detail: multiDisplayMode == 0 ? "A slow glow. The lock screen stays on the main display." : "The full lock screen on every display.")
                }
                .pickerStyle(.segmented)
            }

            Section("Fade to black") {
                Toggle(isOn: $fadeToBlackEnabled) {
                    SettingLabel("Fade to black when idle", detail: "Saves an OLED screen while you're away. Agent pings still glow.")
                }
                if fadeToBlackEnabled {
                    Picker("After", selection: $fadeToBlackDelay) {
                        ForEach(FadeToBlack.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .settingsPane(.lockScreen)
    }

    /// Dog, Cat, Custom, None; plus the supporter mascots for supporters, when their art ships.
    private var mascotChoices: [Mascot] {
        guard supporter.isSupporter else { return Mascot.freeCases }
        let extras = Mascot.supporterCases.filter { $0.assetName.map(Mascot.bundledAssetExists) ?? false }
        return Array(Mascot.freeCases.prefix(2)) + extras + Array(Mascot.freeCases.dropFirst(2))
    }

    @ViewBuilder
    private var mascotOptions: some View {
        ForEach(mascotChoices) { Text($0.displayName).tag($0.rawValue) }
    }

    private func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Image"
        panel.message = "Choose an image for the lock screen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try customMascot.install(from: url)
            customMascotError = nil
        } catch {
            customMascotError = error.localizedDescription
        }
    }
}

/// A small, live picture of the lock screen: the mascot in its pool of light, the message
/// under it, the timer and the token counter. It changes as the settings below it do.
private struct MascotPreview: View {
    let mascot: Mascot
    let showsMessage: Bool
    let message: String
    let showsTokenCounter: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.035, blue: 0.045), Color(red: 0.005, green: 0.006, blue: 0.01)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [Color("LockpawTeal").opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 150)

            VStack(spacing: 10) {
                if CustomMascot.shared.canShow(mascot) {
                    MascotImage(mascot)
                        .frame(height: 74)
                        .shadow(color: Color("LockpawTeal").opacity(0.25), radius: 18)
                } else if mascot == .custom {
                    Text("No image chosen")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: 74)
                }
                if showsMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
                Text("00:42")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                if showsTokenCounter {
                    Text("12,480 tokens today")
                        .font(.system(size: 9, weight: .light).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(height: 168)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the lock screen with \(mascot == .hidden ? "no mascot" : mascot.displayName)")
    }
}
