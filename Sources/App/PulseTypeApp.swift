import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup("PulseType", id: "control-center") {
            SettingsView(model: model)
                .frame(minWidth: 1080, minHeight: 700)
        }

        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }
    }
}
