import Foundation

enum MagicianFeishuCLIHealth: Equatable {
    case unknown
    case ready(version: String?, scopes: [String], userName: String?)
    case permissionLimited(
        version: String?,
        scopes: [String],
        userName: String?,
        missingScopes: [String],
        doctorFailures: [String]
    )
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
        case let .permissionLimited(version, _, userName, _, _):
            return joinedDetail(version: version, userName: userName)
        case let .authRequired(message), let .unavailable(message):
            return message
        }
    }

    var limitationItems: [String] {
        switch self {
        case .unknown, .ready, .authRequired, .unavailable:
            return []
        case let .permissionLimited(_, _, _, missingScopes, doctorFailures):
            var items: [String] = []
            if !missingScopes.isEmpty {
                items.append("缺少 scope：\(missingScopes.joined(separator: "、"))")
            }
            items.append(contentsOf: doctorFailures.map { "诊断失败：\($0)" })
            return items
        }
    }

    var missingScopes: [String] {
        switch self {
        case .unknown, .ready, .authRequired, .unavailable:
            return []
        case let .permissionLimited(_, _, _, missingScopes, _):
            return missingScopes
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
        let verifiedAuthStatus = runCLI(executablePath: backend.executablePath, arguments: ["auth", "status", "--verify"], timeoutSeconds: 3.2)
        let doctorOffline = runCLI(executablePath: backend.executablePath, arguments: ["doctor", "--offline"], timeoutSeconds: 4.0)
        let coreScopes = [
            "calendar:calendar:read",
            "im:message:readonly",
            "docs:document:read"
        ]

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

        let authPayload = parsedJSON(from: authStatus.stdout)
        let verifiedPayload = parsedJSON(from: verifiedAuthStatus.stdout)
        let payload = verifiedPayload.isEmpty ? authPayload : verifiedPayload
        let tokenStatus = ((payload["tokenStatus"] as? String) ?? (payload["status"] as? String))?.lowercased()
        let scopes = ((payload["scope"] as? String) ?? "")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let userName = (payload["userName"] as? String) ?? (payload["user_name"] as? String)

        let doctorPayload = parsedJSON(from: doctorOffline.stdout)
        let doctorChecks = doctorPayload["checks"] as? [[String: Any]] ?? []
        let hasDoctorFailure = doctorChecks.contains { check in
            let status = ((check["status"] as? String) ?? (check["result"] as? String) ?? "").lowercased()
            return status == "fail" || status == "failed" || status == "error"
        }

        let scopeProbeResults = coreScopes.map { scope in
            let result = runCLI(
                executablePath: backend.executablePath,
                arguments: ["auth", "check", "--scope", scope],
                timeoutSeconds: 2.0
            )
            return (scope: scope, result: result)
        }
        let scopeProbeMissing = scopeProbeResults.compactMap { item -> String? in
            item.result.exitCode == 0 ? nil : item.scope
        }
        let doctorScopeCandidates = Set(doctorChecks.flatMap { check -> [String] in
            let name = (check["name"] as? String) ?? ""
            let message = (check["message"] as? String) ?? ""
            return extractScopes(from: "\(name) \(message)")
        })
        let grantedScopes = Set(scopes)
        let inferredMissingScopes = doctorScopeCandidates
            .filter { !grantedScopes.contains($0) }
        let missingScopes = Array(Set(scopeProbeMissing).union(inferredMissingScopes)).sorted()
        let missingCoreScope = !missingScopes.isEmpty
        let doctorFailures = doctorChecks.compactMap { check -> String? in
            let status = ((check["status"] as? String) ?? (check["result"] as? String) ?? "").lowercased()
            guard status == "fail" || status == "failed" || status == "error" else {
                return nil
            }
            let name = (check["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let message = (check["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? name : "\(name)（\(message)）"
        }

        if tokenStatus == "valid" {
            if !missingCoreScope && !hasDoctorFailure {
                return (availability, .ready(version: versionLine, scopes: scopes, userName: userName))
            }
            return (
                availability,
                .permissionLimited(
                    version: versionLine,
                    scopes: scopes,
                    userName: userName,
                    missingScopes: missingScopes,
                    doctorFailures: doctorFailures
                )
            )
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

    private func extractScopes(from text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        let pattern = #"[A-Za-z][A-Za-z0-9_.-]*:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var scopes: [String] = []
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else {
                continue
            }
            let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !scopes.contains(value) {
                scopes.append(value)
            }
        }
        return scopes
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
