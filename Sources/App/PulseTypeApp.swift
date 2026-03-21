import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup("PulseType 控制台") {
            DesktopDashboardView(model: model)
                .frame(minWidth: 920, minHeight: 640)
        }

        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }

        Window("命令台", id: "command-deck") {
            MenuBarPanelView(model: model)
                .frame(minWidth: 360, minHeight: 500)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 760, minHeight: 680)
        }
    }
}
