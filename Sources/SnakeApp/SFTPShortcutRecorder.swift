import AppKit
import SwiftUI

struct SFTPShortcutRecorder: NSViewRepresentable {
    let shortcut: SFTPShortcut
    let onRecord: (SFTPShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.shortcut = shortcut
        field.onRecord = onRecord
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.shortcut = shortcut
        field.onRecord = onRecord
        if field.window?.firstResponder !== field { field.showShortcut() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderField, context: Context) -> CGSize? {
        CGSize(width: 150, height: 28)
    }
}

final class ShortcutRecorderField: NSTextField {
    var shortcut = SFTPShortcutAction.search.defaultShortcut
    var onRecord: ((SFTPShortcut) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        focusRingType = .exterior
        toolTip = "点击后按下新的快捷键"
        setAccessibilityRole(.button)
        setAccessibilityLabel("录制快捷键")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        stringValue = "按下快捷键…"
        textColor = .controlAccentColor
        return true
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        showShortcut()
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        guard let shortcut = SFTPShortcut.from(event: event) else {
            NSSound.beep()
            return
        }
        onRecord?(shortcut)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    func showShortcut() {
        stringValue = shortcut.displayText
        textColor = .labelColor
        setAccessibilityValue(shortcut.displayText)
    }
}
