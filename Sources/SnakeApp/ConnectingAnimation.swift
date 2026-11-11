import SwiftUI

/// Shown over a terminal or SFTP tab while it connects: a wave of dots runs from
/// this Mac to the server, the server pulses, and the elapsed time keeps counting
/// so a slow network reads as progress rather than a stall. When the attempt
/// fails the card stays, the link between the two ends shows as broken and the
/// reason appears with a way to reconnect or read the log.
struct ConnectingAnimation: View {
    let title: String
    let detail: String
    let status: String
    var foreground: Color = SnakeStyle.ink
    var surface: Color = SnakeStyle.raisedSurface
    /// Painted under `surface` so a translucent card stays readable over text.
    var backdrop: Color = .clear
    /// Set when the attempt failed; replaces the status line.
    var failure: String?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onShowLog: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private static let dotCount = 5
    /// Seconds for the wave to cross from one end to the other.
    private static let period = 1.1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || failure != nil)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    endpoint("laptopcomputer", pulse: nil)
                    if failure == nil {
                        HStack(spacing: 7) {
                            ForEach(0..<Self.dotCount, id: \.self) { index in
                                dot(index: index, elapsed: elapsed)
                            }
                        }
                    } else {
                        brokenLink
                    }
                    endpoint("server.rack", pulse: reduceMotion || failure != nil ? nil : elapsed, dimmed: failure != nil)
                }
                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(foreground.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failure {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .frame(maxWidth: 380)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    } else {
                        HStack(spacing: 6) {
                            Text(status)
                            Text(L10n.plural("%@ 秒", count: Int(elapsed), Int(elapsed)))
                                .monospacedDigit()
                                .foregroundStyle(foreground.opacity(0.45))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(foreground.opacity(0.75))
                        .lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    if failure != nil, let onRetry {
                        Button("重新连接", action: onRetry)
                            .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                    }
                    if failure == nil, let onCancel {
                        Button("取消连接", action: onCancel)
                            .buttonStyle(SnakeOutlineButtonStyle())
                    }
                    if let onShowLog {
                        Button("查看日志", action: onShowLog)
                            .buttonStyle(SnakeOutlineButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(minWidth: 280)
            .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(backdrop, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(foreground.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title + " " + (failure ?? status)))
        .onChange(of: failure == nil) { _, connecting in
            if connecting { startedAt = Date() }
        }
    }

    /// The dots fall grey and a cross sits where the link broke.
    private var brokenLink: some View {
        HStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { _ in
                Circle().fill(foreground.opacity(0.22)).frame(width: 7, height: 7)
            }
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white, Color.red)
            ForEach(0..<2, id: \.self) { _ in
                Circle().fill(foreground.opacity(0.22)).frame(width: 7, height: 7)
            }
        }
    }

    private func endpoint(_ symbol: String, pulse elapsed: Double?, dimmed: Bool = false) -> some View {
        ZStack {
            if let elapsed {
                // One ring per wave, expanding as the dots arrive.
                let progress = (elapsed / Self.period).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(SnakeStyle.action.opacity(0.45 * (1 - progress)), lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1 + 0.45 * progress)
            }
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(dimmed ? foreground.opacity(0.28) : SnakeStyle.action,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(width: 64, height: 64)
    }

    private func dot(index: Int, elapsed: Double) -> some View {
        let strength: Double
        if reduceMotion {
            strength = 0.6
        } else {
            // A bright crest travels left to right; each dot lights as it passes.
            let crest = (elapsed / Self.period).truncatingRemainder(dividingBy: 1) * Double(Self.dotCount + 1) - 0.5
            strength = max(0, 1 - abs(Double(index) - crest) / 1.4)
        }
        return Circle()
            .fill(SnakeStyle.action.opacity(0.35 + 0.65 * strength))
            .frame(width: 7, height: 7)
            .scaleEffect(0.8 + 0.5 * strength)
    }
}
