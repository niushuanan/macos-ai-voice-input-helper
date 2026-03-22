import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let expectedRuntimePath = "/Applications/PulseType.app"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if isRunningUnderTests() || ProcessInfo.processInfo.environment["PULSETYPE_ALLOW_DEBUG_RUNTIME"] == "1" {
            return
        }

        guard Bundle.main.bundlePath != expectedRuntimePath else {
            return
        }

        presentSingleRuntimeAlert()
    }

    private func presentSingleRuntimeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前不是 /Applications 版本，已禁止继续运行"
        alert.informativeText = """
        现在只允许 /Applications/PulseType.app 作为正式运行实例。
        可以直接同步当前版本到 /Applications 并重启。
        """
        alert.addButton(withTitle: "同步到 /Applications 并重启")
        alert.addButton(withTitle: "退出")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try installCurrentBundleToApplications()
                NSWorkspace.shared.open(URL(fileURLWithPath: expectedRuntimePath, isDirectory: true))
            } catch {
                presentInstallFailureAlert(error.localizedDescription)
            }
        }

        NSApp.terminate(nil)
    }

    private func presentInstallFailureAlert(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "同步失败"
        alert.informativeText = """
        无法自动写入 /Applications。
        失败原因：\(reason)

        请在仓库目录执行：./scripts/install-local-app.sh
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func installCurrentBundleToApplications() throws {
        let sourceURL = URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: expectedRuntimePath, isDirectory: true)
        let fileManager = FileManager.default

        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == Bundle.main.bundleIdentifier {
            if app.bundleURL?.path == destinationURL.path {
                app.terminate()
            }
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        cleanupLaunchServices(sourceURL: sourceURL, destinationURL: destinationURL)
    }

    private func cleanupLaunchServices(sourceURL: URL, destinationURL: URL) {
        let toolPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            return
        }

        runProcess(
            executablePath: toolPath,
            arguments: ["-u", sourceURL.path]
        )
        runProcess(
            executablePath: toolPath,
            arguments: ["-f", "-R", destinationURL.path]
        )
        runProcess(
            executablePath: toolPath,
            arguments: ["-gc"]
        )
    }

    private func runProcess(executablePath: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func isRunningUnderTests() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(where: {
            $0.localizedCaseInsensitiveContains("xctest")
        }) {
            return true
        }
        return false
    }
}
