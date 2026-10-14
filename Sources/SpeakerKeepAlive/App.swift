import AppKit
import SwiftUI

@main
struct SpeakerKeepAliveApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var coordinator = Coordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator)
        } label: {
            MenuBarLabel(symbol: coordinator.menuBarSymbol)
        }

        Window("Speaker Keep-Alive", id: SettingsView.windowID) {
            SettingsView(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Opening the app again (Finder, Spotlight, `open`) shows Settings. This is
/// the way in when the menu bar is too crowded to show the icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showSettings = Notification.Name("SpeakerKeepAlive.showSettings")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: Self.showSettings, object: nil)
        return false
    }
}

/// The menu bar icon. It's the one view that always exists, so it also handles
/// requests to open the Settings window.
private struct MenuBarLabel: View {
    var symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Speaker Keep-Alive")
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.showSettings)) { _ in
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            }
    }
}
