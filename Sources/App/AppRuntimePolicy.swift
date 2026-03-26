import Foundation

struct AppRuntimePolicy: Equatable {
    let appName: String
    let bundleIdentifier: String
    let installPath: String
    let debugRuntimeEnvironmentKey: String
    let launchServicesToolPath: String

    static let resourceName = "AppRuntimePolicy"
    static let fallback = AppRuntimePolicy(
        appName: "PulseType",
        bundleIdentifier: "com.niushuanan.PulseType",
        installPath: "/Applications/PulseType.app",
        debugRuntimeEnvironmentKey: "PULSETYPE_ALLOW_DEBUG_RUNTIME",
        launchServicesToolPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
    )

    var installURL: URL {
        URL(fileURLWithPath: installPath, isDirectory: true)
    }

    var launchServicesToolURL: URL {
        URL(fileURLWithPath: launchServicesToolPath, isDirectory: false)
    }

    func allowsAlternateRuntime(
        environment: [String: String],
        isRunningUnderTests: Bool
    ) -> Bool {
        isRunningUnderTests || environment[debugRuntimeEnvironmentKey] == "1"
    }

    static func current(bundle: Bundle = .main) -> AppRuntimePolicy {
        if let policy = load(from: bundle) {
            return policy
        }
        return fallback
    }

    static func load(from bundle: Bundle) -> AppRuntimePolicy? {
        for candidate in candidateBundles(primary: bundle) {
            guard
                let url = candidate.url(forResource: resourceName, withExtension: "plist"),
                let policy = try? load(from: url)
            else {
                continue
            }
            return policy
        }

        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("\(resourceName).plist", isDirectory: false)
        return try? load(from: repoURL)
    }

    static func load(from url: URL) throws -> AppRuntimePolicy {
        let data = try Data(contentsOf: url)
        let payload = try PropertyListDecoder().decode(ResourcePayload.self, from: data)
        return AppRuntimePolicy(
            appName: payload.appName,
            bundleIdentifier: payload.bundleIdentifier,
            installPath: payload.installPath,
            debugRuntimeEnvironmentKey: payload.debugRuntimeEnvironmentKey,
            launchServicesToolPath: payload.launchServicesToolPath
        )
    }

    private static func candidateBundles(primary: Bundle) -> [Bundle] {
        [primary, Bundle(for: AppRuntimePolicyBundleProbe.self)]
    }

    private struct ResourcePayload: Decodable {
        let appName: String
        let bundleIdentifier: String
        let installPath: String
        let debugRuntimeEnvironmentKey: String
        let launchServicesToolPath: String
    }
}

private final class AppRuntimePolicyBundleProbe: NSObject {}
