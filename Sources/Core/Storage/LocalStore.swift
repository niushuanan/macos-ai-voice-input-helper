import Foundation

struct LocalStore {
    let rootDirectory: URL
    let historyDirectory: URL
    let diagnosticsDirectory: URL
    let temporaryAudioDirectory: URL

    static func bootstrap(fileManager: FileManager = .default) -> LocalStore {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let rootDirectory = baseDirectory.appendingPathComponent("PulseType", isDirectory: true)
        let store = LocalStore(
            rootDirectory: rootDirectory,
            historyDirectory: rootDirectory.appendingPathComponent("History", isDirectory: true),
            diagnosticsDirectory: rootDirectory.appendingPathComponent("Diagnostics", isDirectory: true),
            temporaryAudioDirectory: rootDirectory.appendingPathComponent("TemporaryAudio", isDirectory: true)
        )
        store.ensureDirectoryLayout(fileManager: fileManager)
        return store
    }

    private func ensureDirectoryLayout(fileManager: FileManager) {
        [rootDirectory, historyDirectory, diagnosticsDirectory, temporaryAudioDirectory].forEach { url in
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
