import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }

        Window("Command Deck", id: "command-deck") {
            MenuBarPanelView(model: model)
                .frame(minWidth: 360, minHeight: 500)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}
