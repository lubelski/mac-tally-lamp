import MacTallyLampCore
import SwiftUI

/// The lamp's card: a lit lamp, who is using the screen and for what, how long, who is
/// waiting, and a button for the person at the Mac to take the screen.
struct LampCard: View {
    static let width: CGFloat = 420

    let status: ScreenStatus
    let now: Date
    var takeScreen: () -> Void
    @Environment(\.isRenderingPreview) private var rendering

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LampGlyph()
                VStack(alignment: .leading, spacing: 3) {
                    Text("On screen")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(status.holder?.name ?? "Nobody")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let purpose = status.holder?.purpose {
                        Text(purpose)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("An agent is using the keyboard and mouse. Hands off until it finishes, or take the screen.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(details)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Take the Screen", action: takeScreen)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .modifier(LampSurface(rendering: rendering))
    }

    /// "For 3 min · 2 waiting · turn ends in 7 min"
    private var details: String {
        var parts: [String] = []
        if let since = status.holder?.since {
            parts.append("For \(TimeFormat.duration(now.timeIntervalSince(since)))")
        }
        switch status.waiting.count {
        case 0: parts.append("nobody waiting")
        case 1: parts.append("\(status.waiting[0].name) waiting")
        case let count: parts.append("\(count) waiting")
        }
        if let ends = status.holdEnds {
            parts.append("turn ends in \(TimeFormat.duration(ends.timeIntervalSince(now)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The card's glass. Glass does not draw in a window that was never on screen, so
/// `--render-previews` draws a plain rounded card in its place.
private struct LampSurface: ViewModifier {
    let rendering: Bool
    static let shape = RoundedRectangle(cornerRadius: 24)

    func body(content: Content) -> some View {
        if rendering {
            content.background(Self.shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        } else {
            content.glassEffect(.regular, in: Self.shape)
        }
    }
}

/// A round red lamp, lit, as a broadcast tally light is while its camera is live.
struct LampGlyph: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.55, blue: 0.5), Color(red: 0.92, green: 0.12, blue: 0.1)],
                    center: UnitPoint(x: 0.38, y: 0.34), startRadius: 0, endRadius: size * 0.62))
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 1, green: 0.15, blue: 0.1).opacity(0.7), radius: size * 0.35)
        .accessibilityHidden(true)
    }
}
