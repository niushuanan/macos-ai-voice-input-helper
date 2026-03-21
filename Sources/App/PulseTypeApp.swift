import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup("PulseType 主界面", id: "control-center") {
            SettingsView(model: model)
                .frame(minWidth: 920, minHeight: 700)
        }

        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }
    }
}
