import SwiftUI

/// The supporter card's content: a note from Erik, the user's own mascot in its pool of
/// light, and every ending (thanks, not now, already a supporter, the welcome). The copy is
/// shaped by the research behind it: thank first, the facts and what support pays for on
/// the card itself, one small concrete amount, a "Not now" as easy as yes, and no rewards in
/// the ask. The supporter mascots only appear in the welcome, after a licence is entered.
struct SupportCardView: View {
    static let width: CGFloat = 340

    @ObservedObject var model: SupportCardModel
    let onAction: (SupportCardPanel.Action) -> Void

    @ObservedObject private var supporter = Supporter.shared
    @ObservedObject private var customMascot = CustomMascot.shared
    @AppStorage(Mascot.storageKey) private var mascotChoice = Mascot.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BreathingMascot(mascot: ownMascot)
                    .frame(width: 52, height: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phase.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .accessibilityAddTraits(.isHeader)
                    if case .ask = model.phase {
                        Text("Creator of Lockpaw")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            content
                .padding(.top, 12)
        }
        .id(model.phase.contentID)
        .transition(.opacity)
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    /// The mascot this user already has: the card is about the relationship that works.
    /// No mascot chosen, or a custom one with no file, falls back to Lockpaw's own dog.
    private var ownMascot: Mascot {
        let mascot = Mascot.resolved(from: mascotChoice, isSupporter: supporter.isSupporter, assetExists: Mascot.bundledAssetExists)
        if mascot == .custom { return customMascot.hasImage ? .custom : .dog }
        return mascot.assetName == nil ? .dog : mascot
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ask:
            VStack(alignment: .leading, spacing: 0) {
                paragraph("Lockpaw has kept your screen covered while your agents work. I build it on my own, and it\u{2019}ll always be free. If you\u{2019}d like to help keep it going, $9 is a fine thank-you, $19 if it saves your afternoons. Or pay what you want.")
                buttons(primary: ("Chip in", .support), secondary: ("Not now", .notNow))
                HStack(spacing: 12) {
                    Button("Already a supporter?") { onAction(.alreadySupport) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 0)
                    Text("This note won\u{2019}t come back.")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .font(.system(size: 11.5))
                .padding(.top, 12)
            }

        case .thanks:
            VStack(alignment: .leading, spacing: 0) {
                paragraph("The checkout is open in your browser. When your key arrives, paste it in **Settings \u{203A} About**.")
                buttons(primary: ("Open Settings", .openSettings(.about)), secondary: ("Done", .close))
            }

        case .notNow:
            VStack(alignment: .leading, spacing: 0) {
                paragraph("Lockpaw stays exactly the same. Thanks for using it.")
                AutoCloseBar(duration: Constants.Timing.supportCardAutoClose)
            }

        case .already:
            VStack(alignment: .leading, spacing: 0) {
                paragraph("I won\u{2019}t ask again. If you sponsor me on GitHub or gave before licences existed, you get a licence for free.")
                buttons(primary: ("Get my licence", .freeLicence), secondary: ("Done", .close))
            }

        case .welcome(let friends):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(friends) { friend in
                        VStack(spacing: 2) {
                            MascotImage(friend)
                                .frame(height: 42)
                                .shadow(color: Color("LockpawTeal").opacity(0.18), radius: 12)
                            Text(friend.displayName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(friends.map(\.displayName).joined(separator: ", "))
                paragraph("Pick one in **Settings \u{203A} Lock Screen**. Thanks for supporting Lockpaw.")
                buttons(primary: ("Choose a mascot", .openSettings(.lockScreen)), secondary: ("Later", .close))
            }
        }
    }

    // MARK: - Pieces

    private func paragraph(_ markdown: String) -> some View {
        Text(LocalizedStringKey(markdown))
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .foregroundStyle(.white.opacity(0.68))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 16)
    }

    /// Two buttons of equal size: saying no is as easy as saying yes.
    private func buttons(primary: (String, SupportCardPanel.Action), secondary: (String, SupportCardPanel.Action)) -> some View {
        HStack(spacing: 8) {
            Button(primary.0) { onAction(primary.1) }
                .buttonStyle(CardButtonStyle(prominent: true))
            Button(secondary.0) { onAction(secondary.1) }
                .buttonStyle(CardButtonStyle(prominent: false))
        }
    }
}

extension SupportCardPanel.Phase {
    var title: String {
        switch self {
        case .ask: return "Hi, it\u{2019}s Erik."
        case .thanks: return "Thank you, really."
        case .notNow: return "No worries."
        case .already: return "Thank you!"
        case .welcome(let friends): return friends.count == 4 ? "Four new friends just moved in." : "New friends just moved in."
        }
    }

    /// What VoiceOver says when the card appears or changes.
    var announcement: String {
        switch self {
        case .ask: return "A note from Erik, who makes Lockpaw, asking if you'd like to chip in."
        case .thanks: return "Thank you. When your key arrives, paste it in Settings, About."
        case .notNow: return "No worries. Lockpaw stays exactly the same."
        case .already: return "Thank you. Lockpaw won't ask again."
        case .welcome: return "New supporter mascots are available in Settings, Lock Screen."
        }
    }

    /// One identity per phase, so the content cross-fades between phases.
    var contentID: String {
        switch self {
        case .ask: return "ask"
        case .thanks: return "thanks"
        case .notNow: return "notNow"
        case .already: return "already"
        case .welcome: return "welcome"
        }
    }
}

// MARK: - Parts

/// The user's mascot, breathing in its pool of light (DESIGN.md §5), still under Reduce Motion.
private struct BreathingMascot: View {
    let mascot: Mascot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhale = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color("LockpawTeal").opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: 28))
                .blur(radius: 6)
                .scaleEffect(inhale ? 1.08 : 1)
                .opacity(inhale ? 1 : 0.75)
            MascotImage(mascot)
                .frame(width: 50)
                .shadow(color: .black.opacity(0.45), radius: 5, y: 5)
                .scaleEffect(inhale ? 1.025 : 1)
                .offset(y: inhale ? -2 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            // Half the 12s breath each way; autoreversing, so it never snaps.
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { inhale = true }
        }
    }
}

private struct AutoCloseBar: View {
    let duration: TimeInterval
    @State private var remaining: CGFloat = 1

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.06))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: geo.size.width * remaining)
                }
            }
            .onAppear { withAnimation(.linear(duration: duration)) { remaining = 0 } }
            .accessibilityHidden(true)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color(red: 0.016, green: 0.071, blue: 0.055) : .white.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color("LockpawTeal") : .white.opacity(0.09))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// HUD material under a near-black wash: reads like a notification, looks like Lockpaw.
private struct CardBackground: View {
    var body: some View {
        ZStack {
            VisualEffect()
            LinearGradient(
                colors: [Color(white: 0.12).opacity(0.82), Color(white: 0.07).opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
