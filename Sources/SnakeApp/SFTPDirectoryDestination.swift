import Foundation

/// Snapshot the browser directory before presenting a creation or upload dialog.
/// A context-clicked folder is deliberately not part of this destination.
struct SFTPDirectoryDestination: Equatable {
    let path: String

    init?(connectionState: ConnectionState, currentPath: String, loadingPath: String?) {
        guard connectionState == .connected, loadingPath == nil else { return nil }
        path = currentPath
    }
}
