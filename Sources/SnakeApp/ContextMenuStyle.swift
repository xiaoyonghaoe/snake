import AppKit
import SwiftUI

/// One look for every right-click menu in Snake, AppKit or SwiftUI:
/// - every item carries an SF Symbol;
/// - the main actions come first without a heading, later groups get a small
///   grey heading (连接 / 文件 / 管理 …);
/// - destructive items sit alone at the bottom, in red;
/// - items that cannot run right now are dimmed rather than hidden, so the
///   menu keeps its shape;
/// - titles carry no trailing ellipsis.
extension View {
    func snakeContextMenu<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        // SwiftUI menus on macOS drop item icons unless asked to keep them.
        contextMenu { Group { items() }.labelStyle(.titleAndIcon) }
    }
}

/// Builds AppKit menus to the same rules.
@MainActor
struct SnakeMenuBuilder {
    let menu: NSMenu
    let target: AnyObject

    func header(_ title: String) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: title))
    }

    func separator() {
        menu.addItem(.separator())
    }

    func item(
        _ title: String,
        symbol: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        enabled: Bool = true,
        destructive: Bool = false,
        action: Selector
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if destructive {
            item.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        } else {
            item.image = image
        }
        item.target = target
        item.isEnabled = enabled
        menu.addItem(item)
    }
}
