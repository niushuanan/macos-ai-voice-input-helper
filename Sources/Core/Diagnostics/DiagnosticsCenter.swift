import Foundation

struct DiagnosticsCenter {
    let appVersion: String
    let buildNumber: String

    init(bundle: Bundle = .main) {
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"
    }

    func summaryLines() -> [String] {
        [
            "Version \(appVersion) (\(buildNumber))",
            "Helper app mode with menu bar lifecycle",
            "Local-first history and settings roadmap"
        ]
    }
}
