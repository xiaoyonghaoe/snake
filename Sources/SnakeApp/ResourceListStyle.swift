import SwiftUI

/// Rows for things that run in the background, such as disk mappings and SSH
/// tunnels. What a row *is* reads on the left; whether it is running, and
/// whether it starts by itself with Snake, read together as status on the
/// right; the buttons only act. Keeping "starts automatically" as a quiet
/// badge instead of a second switch next to a start button avoids two
/// controls that both seem to mean "start".
struct ResourceRow<Title: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    let subtitle: String
    let status: String
    let statusColor: Color
    /// Shown only when the item starts by itself.
    let automaticLabel: String?
    let automaticHelp: String
    let problem: String?
    let isSelected: Bool
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        mainLine
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? SnakeStyle.selectedRow.opacity(0.75) : .clear)
        .contentShape(Rectangle())
    }

    private var mainLine: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                title()
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SnakeStyle.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
                if let problem, !problem.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                StatusPill(text: status, color: statusColor)
                if let automaticLabel {
                    AutomaticBadge(text: automaticLabel, help: automaticHelp)
                }
            }
            .fixedSize()
            HStack(spacing: 6) { actions() }
                .fixedSize()
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color == .secondary ? SnakeStyle.muted : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .lineLimit(1)
    }
}

/// "Starts with Snake", as a fact about the row rather than a control.
struct AutomaticBadge: View {
    let text: String
    let help: String

    var body: some View {
        Label(text, systemImage: "bolt.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(SnakeStyle.action)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(SnakeStyle.action.opacity(0.1), in: Capsule())
            .lineLimit(1)
            .help(help)
    }
}

/// The rounded card the rows sit in, with hairlines between them.
struct ResourceListCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
    }
}
