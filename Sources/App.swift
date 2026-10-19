import SwiftUI
import AppKit

@main
struct WLEDMenuBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            // Filled icon doubles as the at-a-glance "something is on" state.
            Image(systemName: anyOn ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)

        Window("WLED", id: "main") {
            MainWindowView(store: store)
                .onAppear { WindowPresence.shared.opened() }
                .onDisappear { WindowPresence.shared.closed() }
        }
        .defaultSize(width: 820, height: 580)
    }

    private var anyOn: Bool {
        store.devices.contains { $0.isOn && $0.reachable }
    }
}

/// The app ships as an `LSUIElement` accessory so it has no Dock icon while it
/// is just a menu bar item. A real window needs a real app, though — Dock icon,
/// Cmd-Tab, a focused menu bar — so we promote on the first window and demote
/// once the last one closes.
@MainActor
final class WindowPresence {
    static let shared = WindowPresence()

    private var count = 0

    func opened() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closed() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
