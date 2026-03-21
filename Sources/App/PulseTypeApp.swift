import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}
