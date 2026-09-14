import SwiftUI
import SnakeApp

@main
struct SnakeExecutable: App {
    @NSApplicationDelegateAdaptor(SnakeAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SnakeSettingsView()
                .environmentObject(appDelegate.store)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}
