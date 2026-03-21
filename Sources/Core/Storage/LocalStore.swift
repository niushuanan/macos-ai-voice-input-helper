import Foundation

struct LocalStore {
    let rootDirectory: URL
    let historyDirectory: URL
    let diagnosticsDirectory: URL

    static func bootstrap(fileManager: FileManager = .default) -> LocalStore {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let rootDirectory = baseDirectory.appendingPathComponent("PulseType", isDirectory: true)
        return LocalStore(
            rootDirectory: rootDirectory,
            historyDirectory: rootDirectory.appendingPathComponent("History", isDirectory: true),
            diagnosticsDirectory: rootDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        )
    }
}
