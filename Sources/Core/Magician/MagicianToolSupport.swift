import Foundation

struct MagicianProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var detail: String {
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedStdout.isEmpty ? "unknown" : trimmedStdout
    }
}

func runProcess(
    executablePath: String,
    arguments: [String]
) async -> MagicianProcessResult {
    await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return MagicianProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return MagicianProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }.value
}

func runOsaScript(
    lines: [String],
    arguments: [String]
) async -> MagicianProcessResult {
    var commandArguments: [String] = []
    for line in lines {
        commandArguments.append("-e")
        commandArguments.append(line)
    }
    commandArguments.append("--")
    commandArguments.append(contentsOf: arguments)
    return await runProcess(
        executablePath: "/usr/bin/osascript",
        arguments: commandArguments
    )
}

func magicianEnsureApplicationReadyAppleScriptLines(
    activate: Bool = true,
    timeoutSeconds: Int = 8
) -> [String] {
    var lines = [
        "set startupDeadline to (current date) + \(timeoutSeconds)",
        "if not running then launch",
        "repeat while (not running) and ((current date) < startupDeadline)",
        "delay 0.1",
        "end repeat",
        "if not running then error \"app launch timeout\""
    ]
    if activate {
        lines.append("activate")
        lines.append("delay 0.1")
    }
    return lines
}

func summarizedHistoryText(_ text: String, limit: Int = 48) -> String {
    let normalized = text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        return "无内容"
    }
    return normalized.count > limit ? "\(normalized.prefix(limit))…" : normalized
}

func magicianMusicSearchQueries(from rawQuery: String) -> [String] {
    let punctuationToTrim = CharacterSet(charactersIn: " \t\r\n。．.!！?？,，、:：;；'\"‘’“”（）()《》〈〉[]【】")
    var value = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    value = value.trimmingCharacters(in: punctuationToTrim)

    let leadingTokens = ["播放", "来一首", "放一首", "听", "music", "play"]
    var lowered = value.lowercased()
    var didTrimLeadingToken = true
    while didTrimLeadingToken, !value.isEmpty {
        didTrimLeadingToken = false
        for token in leadingTokens {
            if lowered.hasPrefix(token) {
                value = String(value.dropFirst(token.count)).trimmingCharacters(in: punctuationToTrim)
                lowered = value.lowercased()
                didTrimLeadingToken = true
                break
            }
        }
    }

    var candidates: [String] = []
    func appendCandidate(_ candidate: String) {
        let cleaned = candidate
            .replacingOccurrences(of: "[《》“”‘’\"']", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: punctuationToTrim)
        guard !cleaned.isEmpty else {
            return
        }
        guard !candidates.contains(cleaned) else {
            return
        }
        candidates.append(cleaned)
    }

    if let quoted = firstQuotedSongTitle(in: value) {
        appendCandidate(quoted)
    }

    if let range = value.range(of: "的"), !range.isEmpty {
        let left = String(value[..<range.lowerBound])
        let right = String(value[range.upperBound...])
        appendCandidate(right)
        appendCandidate(left)
        appendCandidate(value)
    } else {
        appendCandidate(value)
    }

    value
        .components(separatedBy: CharacterSet.whitespaces)
        .forEach { appendCandidate($0) }

    return candidates
}

func magicianMusicEvidenceMatchesQuery(output: String, query: String) -> Bool {
    guard let range = output.range(of: "track=") else {
        return false
    }
    let payload = String(output[range.upperBound...])
    let normalizedPayload = normalizedMusicMatchText(payload)
    guard !normalizedPayload.isEmpty else {
        return false
    }

    if let primarySongQuery = magicianPrimarySongQuery(from: query) {
        let normalizedPrimarySong = normalizedMusicMatchText(primarySongQuery)
        if !normalizedPrimarySong.isEmpty, !normalizedPayload.contains(normalizedPrimarySong) {
            return false
        }
    }

    let candidateQueries = magicianMusicSearchQueries(from: query)
    let verificationCandidates: [String] = {
        if candidateQueries.isEmpty {
            return [query]
        }
        return Array(candidateQueries.prefix(2))
    }()

    for candidate in verificationCandidates {
        let normalizedCandidate = normalizedMusicMatchText(candidate)
        guard !normalizedCandidate.isEmpty else {
            continue
        }
        if normalizedPayload.contains(normalizedCandidate) {
            return true
        }
        let candidateTerms = normalizedMusicCandidateTerms(from: normalizedCandidate)
        if !candidateTerms.isEmpty, candidateTerms.allSatisfy({ normalizedPayload.contains($0) }) {
            return true
        }
    }
    return false
}

func firstQuotedSongTitle(in value: String) -> String? {
    let patterns = [
        "《([^》]+)》",
        "“([^”]+)”",
        "\"([^\"]+)\""
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            continue
        }
        let nsValue = value as NSString
        let range = NSRange(location: 0, length: nsValue.length)
        guard let match = regex.firstMatch(in: value, options: [], range: range), match.numberOfRanges > 1 else {
            continue
        }
        let title = nsValue.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
    }
    return nil
}

func normalizedMusicMatchText(_ value: String) -> String {
    value
        .lowercased()
        .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]+", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func magicianPrimarySongQuery(from query: String) -> String? {
    if let quoted = firstQuotedSongTitle(in: query) {
        return quoted
    }
    let punctuationToTrim = CharacterSet(charactersIn: " \t\r\n。．.!！?？,，、:：;；'\"‘’“”（）()《》〈〉[]【】")
    let compact = query
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: punctuationToTrim)
    guard !compact.isEmpty else {
        return nil
    }
    if let range = compact.range(of: "的"), !range.isEmpty {
        let right = String(compact[range.upperBound...]).trimmingCharacters(in: punctuationToTrim)
        return right.isEmpty ? nil : right
    }
    return compact
}

private func normalizedMusicCandidateTerms(from value: String) -> [String] {
    value
        .split(separator: "的")
        .map(String.init)
        .filter { $0.count >= 2 }
}
