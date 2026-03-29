import Foundation

struct FeishuCLIProcessRunner {
    let timeoutSeconds: TimeInterval
    let maxOutputCharacters: Int

    init(
        timeoutSeconds: TimeInterval = 16,
        maxOutputCharacters: Int = 16_000
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputCharacters = maxOutputCharacters
    }

    func run(
        executablePath: String,
        arguments: [String]
    ) async -> MagicianProcessResult {
        await runProcessWithTimeout(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            maxOutputCharacters: maxOutputCharacters,
            environment: FeishuCLIProvider.buildProcessEnvironment(executablePath: executablePath)
        )
    }

    func mergedOutput(from result: MagicianProcessResult) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return ""
    }
}
