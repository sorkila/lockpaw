import SwiftUI

// The lock screen's token counter, under the timer: today's tokens with the live rate, and
// this year's total — one combined total across every model and tool, never per model. Shown
// only when Settings → Lock Screen → Token counter is on.
//
// `TokenCounterView` observes the monitor itself, so a token update re-renders only this
// subtree and never `LockScreenView`'s body (which already runs every breath frame);
// nothing derived from the breath is passed in. All motion is one-shot and event-driven:
// the digits roll on change, the glow and the "+N" chip are keyframes triggered by an
// arrival counter, and the only clock is a 1 s timeline that exists while this is on screen.
// Type is the lock screen's own four roles (`Font.lockLabel` / `lockCaption` / `lockMono`),
// at the waiting rows' opacities, so the counter reads as part of the same quiet block.

struct TokenCounterView: View, Equatable {
    var compact: Bool

    @ObservedObject private var monitor = TokenUsageMonitor.shared

    init(compact: Bool) {
        self.compact = compact
    }

    static func == (a: TokenCounterView, b: TokenCounterView) -> Bool { a.compact == b.compact }

    var body: some View {
        TokenCounterHero(today: monitor.todayTokens, yearTokens: monitor.yearTokens, year: monitor.year,
                         isCounting: monitor.isCounting, recent: monitor.recent, arrival: monitor.arrival,
                         compact: compact)
            .onAppear { monitor.counterAppeared() }
            .onDisappear { monitor.counterDisappeared() }
    }
}

/// The counter drawn from plain values. Two lines: today (with the rate and, on roomy
/// screens, the sparkline) and the year.
struct TokenCounterHero: View {
    let today: Int64
    let yearTokens: Int64
    let year: Int
    let isCounting: Bool
    let recent: TokenRateWindow
    let arrival: TokenArrival
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chip = ChipState()

    private struct ChipState {
        var serial = 0
        var tokens: Int64 = 0
        var pending: Int64 = 0
        var lastShown = Date.distantPast
    }

    private var roll: Animation? { reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9) }

    var body: some View {
        // The waiting rows' spacing (`AgentPingList`: 6 between rows).
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                number
                caption
                if !isCounting {
                    dot
                    rateRow
                }
            }
            if !isCounting || yearTokens > 0 { yearLine }
        }
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onChange(of: arrival) { _, new in landed(new.tokens) }
    }

    // MARK: Pieces

    private var number: some View {
        Text(TokenFormat.grouped(today))
            .font(.lockLabel.monospacedDigit())
            .tracking(0.3)
            .foregroundStyle(.white.opacity(isCounting ? 0.3 : 0.55))
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(today)))
            .animation(roll, value: today)
            .keyframeAnimator(initialValue: 0.0, trigger: chip.serial) { content, glow in
                content.shadow(color: Color("LockpawTeal").opacity(0.7 * glow), radius: 1 + 6 * glow)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.18)
                CubicKeyframe(0, duration: 0.72)
            }
            .overlay(alignment: .topLeading) { chipView }
    }

    /// "+712K" rising off the number's leading edge and fading. A zero-size box, so it never
    /// widens the line or covers a digit; it floats up into the gap under the timer.
    private var chipView: some View {
        Text("+" + TokenFormat.short(chip.tokens))
            .font(.lockCaption.monospacedDigit())
            .tracking(0.5)
            .foregroundStyle(Color("LockpawTeal"))
            .fixedSize()
            .frame(width: 0, height: 0, alignment: .bottomLeading)
            .keyframeAnimator(initialValue: ChipFrame(), trigger: chip.serial) { content, frame in
                content.opacity(frame.opacity).offset(y: frame.y)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(1, duration: 0.45)
                    LinearKeyframe(0, duration: 0.6)
                }
                KeyframeTrack(\.y) {
                    MoveKeyframe(-2)
                    CubicKeyframe(-12, duration: 1.2)
                }
            }
            .accessibilityHidden(true)
    }

    private var caption: some View {
        Text(isCounting ? "counting tokens\u{2026}" : "tokens today")
            .font(.lockCaption)
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.4))
    }

    private var dot: some View {
        Text("\u{00B7}")
            .font(.lockCaption)
            .foregroundStyle(.white.opacity(0.3))
    }

    private var rateRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            rateContent(now: context.date)
        }
    }

    private func rateContent(now: Date) -> some View {
        let t = now.timeIntervalSince1970
        let perMinute = recent.tokensPerMinute(now: t)
        let idle = perMinute == 0
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                if !idle {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 6, weight: .bold))
                }
                Text(idle ? "idle" : TokenFormat.rate(perMinute: perMinute))
                    .font(.lockMono)
                    .tracking(0.5)
                    .fixedSize()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(perMinute)))
                    .animation(roll, value: perMinute)
            }
            .foregroundStyle(idle ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(Color("LockpawTeal").opacity(0.8)))
            if !compact {
                TokenSparkline(buckets: recent.buckets(now: t), idle: idle, animated: !reduceMotion, tint: Color("LockpawTeal"))
                    .frame(width: 48, height: 9)
            }
        }
    }

    private var yearLine: some View {
        Text(String(year) + " \u{00B7} " + TokenFormat.compact(yearTokens) + " tokens")
            .font(.lockCaption.monospacedDigit())
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.3))
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(yearTokens)))
            .animation(roll, value: yearTokens)
    }

    // MARK: Arrivals

    /// A batch landed. The glow and chip fire at most once a second; a batch inside that
    /// second rides along with the next chip. Reduce Motion: neither.
    private func landed(_ tokens: Int64) {
        guard tokens > 0, !reduceMotion, !isCounting else { return }
        chip.pending += tokens
        let now = Date()
        guard now.timeIntervalSince(chip.lastShown) >= 1 else { return }
        chip.tokens = chip.pending
        chip.pending = 0
        chip.lastShown = now
        chip.serial &+= 1
    }

    private var accessibilityText: String {
        if isCounting { return "Counting tokens" }
        let perMinute = recent.tokensPerMinute(now: Date().timeIntervalSince1970)
        let rate = perMinute == 0 ? "idle" : "\(TokenFormat.spoken(perMinute)) tokens a minute"
        return "\(TokenFormat.grouped(today)) tokens today, \(rate). \(TokenFormat.spoken(yearTokens)) tokens in \(year)."
    }
}

private struct ChipFrame {
    var opacity = 0.0
    var y = 0.0
}

/// 24 bars of the last two minutes, one path. Heights animate between updates through the
/// shape's animatable data — no per-bar views.
struct TokenSparkline: View {
    let buckets: [Int64]
    var idle = false
    var animated = true
    var tint: Color

    var body: some View {
        let peak = Double(buckets.max() ?? 0)
        let bars = SparkBars(values: buckets.map { peak > 0 ? Double($0) / peak : 0 })
        SparklineShape(bars: bars)
            .fill(idle ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(tint.opacity(0.7)))
            .animation(animated ? .easeOut(duration: 0.35) : nil, value: bars)
            .accessibilityHidden(true)
    }
}

private struct SparklineShape: Shape {
    var bars: SparkBars

    var animatableData: SparkBars {
        get { bars }
        set { bars = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, bars.values.count)
        let gap: CGFloat = 1
        let width = max(0.5, (rect.width - gap * CGFloat(count - 1)) / CGFloat(count))
        for (i, value) in bars.values.enumerated() {
            let height = max(1, CGFloat(min(1, max(0, value))) * rect.height)
            let bar = CGRect(x: rect.minX + CGFloat(i) * (width + gap), y: rect.maxY - height, width: width, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 0.5, height: 0.5))
        }
        return path
    }
}

/// Bar heights as animatable data.
private struct SparkBars: VectorArithmetic {
    var values: [Double]

    static var zero: SparkBars { SparkBars(values: []) }

    static func + (lhs: SparkBars, rhs: SparkBars) -> SparkBars { combine(lhs, rhs, +) }
    static func - (lhs: SparkBars, rhs: SparkBars) -> SparkBars { combine(lhs, rhs, -) }

    private static func combine(_ lhs: SparkBars, _ rhs: SparkBars, _ op: (Double, Double) -> Double) -> SparkBars {
        let count = max(lhs.values.count, rhs.values.count)
        return SparkBars(values: (0..<count).map { i in
            op(i < lhs.values.count ? lhs.values[i] : 0, i < rhs.values.count ? rhs.values[i] : 0)
        })
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
