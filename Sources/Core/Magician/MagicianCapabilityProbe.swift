import Foundation

enum MagicianFeishuCLIHealth: Equatable {
    case unknown
    case ready(version: String?, scopes: [String], userName: String?)
    case permissionLimited(version: String?, scopes: [String], userName: String?)
    case authRequired(message: String)
    case unavailable(message: String)

    var title: String {
        switch self {
        case .unknown:
            return "状态未知"
        case .ready:
            return "可直接执行"
        case .permissionLimited:
            return "可运行但权限不全"
        case .authRequired:
            return "未登录"
        case .unavailable:
            return "CLI 不可用"
        }
    }

    var detail: String? {
        switch self {
        case .unknown:
            return nil
        case let .ready(version, _, userName):
            return joinedDetail(version: version, userName: userName)
        case let .permissionLimited(version, _, userName):
            return joinedDetail(version: version, userName: userName)
        case let .authRequired(message), let .unavailable(message):
            return message
        }
    }

    private func joinedDetail(version: String?, userName: String?) -> String? {
        let parts = [version, userName].compactMap { value -> String? in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct MagicianCapabilityProbe {
    func probeFeishuCLI(executableOverride: String?) async -> (availability: FeishuCLIAvailability, health: MagicianFeishuCLIHealth) {
        let availability = FeishuCLIProvider.detectAvailability(executableOverride: executableOverride)
        guard let backend = availability.backend else {
            return (availability, .unavailable(message: "未检测到 feishu 或 lark-cli。"))
        }

        let version = runCLI(executablePath: backend.executablePath, arguments: ["--version"], timeoutSeconds: 2.5)
        let authStatus = runCLI(executablePath: backend.executablePath, arguments: ["auth", "status"], timeoutSeconds: 3.0)

        let versionLine = version.stdout
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard authStatus.exitCode == 0 else {
            let detail = [authStatus.stderr, authStatus.stdout]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                availability,
                .authRequired(message: detail?.isEmpty == false ? detail! : "请先完成 auth login。")
            )
        }

        let payload = parsedJSON(from: authStatus.stdout)
        let tokenStatus = (payload["tokenStatus"] as? String)?.lowercased()
        let scopes = ((payload["scope"] as? String) ?? "")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let userName = payload["userName"] as? String

        if tokenStatus == "valid" {
            let requiredScopePrefixes = ["calendar:", "im:", "docs:", "base:", "task:", "wiki:"]
            let hasCoreScope = requiredScopePrefixes.allSatisfy { prefix in
                scopes.contains(where: { $0.hasPrefix(prefix) })
            }
            if hasCoreScope {
                return (availability, .ready(version: versionLine, scopes: scopes, userName: userName))
            }
            return (availability, .permissionLimited(version: versionLine, scopes: scopes, userName: userName))
        }

        return (
            availability,
            .authRequired(message: "登录已失效，请重新授权。")
        )
    }

    private func parsedJSON(from text: String) -> [String: Any] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    private func runCLI(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> MagicianProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = FeishuCLIProvider.buildProcessEnvironment(executablePath: executablePath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return MagicianProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.6)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return MagicianProcessResult(
            exitCode: timedOut ? -998 : process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
