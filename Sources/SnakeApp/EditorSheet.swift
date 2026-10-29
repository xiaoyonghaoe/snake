import SwiftUI

/// Shared shell for the add, edit and view sheets of the MCP and 磁盘映射 tabs:
/// a context-and-title header with a close button, a scrolling column of
/// sections, and a footer whose leading slot holds secondary actions and whose
/// trailing slot holds the primary one.
struct SnakeEditorSheet<Content: View, Leading: View, Trailing: View>: View {
    private let context: String
    private let title: String
    private let width: CGFloat
    private let height: CGFloat
    private let onClose: () -> Void
    private let content: Content
    private let leading: Leading
    private let trailing: Trailing

    init(
        context: String,
        title: String,
        width: CGFloat = 640,
        height: CGFloat = 560,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.context = context
        self.title = title
        self.width = width
        self.height = height
        self.onClose = onClose
        self.content = content()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context).font(.system(size: 11, weight: .semibold)).foregroundStyle(SnakeStyle.muted)
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(SnakeIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("关闭").accessibilityLabel("关闭")
            }
            .padding(.horizontal, 24)
            .frame(height: 74)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) { content }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
        }
        .frame(width: width, height: height)
        .background(SnakeStyle.canvas)
    }
}

/// A titled group of fields inside `SnakeEditorSheet`.
struct EditorSection<Content: View>: View {
    private let title: String
    private let footnote: String?
    private let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .bold))
            content
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(SnakeStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small muted label above an arbitrary control.
struct EditorRow<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditorField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var monospaced = false

    var body: some View {
        EditorRow(label) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
        }
    }
}

/// Read-only monospaced value on a raised surface, e.g. a path or a secret.
struct EditorValueBox<Accessory: View>: View {
    private let value: String
    private let placeholder: Bool
    private let accessory: Accessory

    init(_ value: String, placeholder: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.value = value
        self.placeholder = placeholder
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(placeholder ? SnakeStyle.muted : SnakeStyle.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
    }
}
