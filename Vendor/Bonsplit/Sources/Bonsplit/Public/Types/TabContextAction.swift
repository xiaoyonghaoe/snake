import Foundation

/// Actions exposed by the native context menu of a Bonsplit tab.
public enum TabContextAction: Sendable {
    case splitHorizontal
    case splitVertical
    case close
    case closeOthers
    case detach
}
