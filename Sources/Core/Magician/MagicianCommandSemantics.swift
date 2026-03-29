import Foundation

let magicianCLIValueOptionalFlags: Set<String> = [
    "-h",
    "--help",
    "--dry-run",
    "--page-all",
    "--recommend",
    "--no-wait"
]

let magicianValueOptionalCLIFlags = magicianCLIValueOptionalFlags

func magicianCommandContainsExplicitCLIFlags(_ command: String) -> Bool {
    command
        .split(whereSeparator: \.isWhitespace)
        .contains { token in
            token.hasPrefix("-")
        }
}

func magicianCLIArgumentsLookComplete(_ arguments: [String]) -> Bool {
    guard !arguments.isEmpty else {
        return true
    }

    var index = 0
    while index < arguments.count {
        let token = arguments[index]
        if token.hasPrefix("-") {
            if magicianCLIValueOptionalFlags.contains(token) {
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                return false
            }
            let next = arguments[index + 1]
            guard !next.hasPrefix("-") else {
                return false
            }
            index += 2
            continue
        }
        index += 1
    }
    return true
}

func compactIntentText(_ value: String) -> String {
    let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    return value.lowercased()
        .components(separatedBy: separators)
        .joined()
}

func isLikelyInstructionPhrase(
    _ candidate: String,
    command: String,
    actionTokens: [String]
) -> Bool {
    let compactCandidate = compactIntentText(candidate)
    guard !compactCandidate.isEmpty else {
        return true
    }
    if compactCandidate == compactIntentText(command) {
        return true
    }

    var reduced = compactCandidate
    let baseTokens = [
        "帮我", "请", "一下", "帮忙", "把", "给我", "这段", "这个", "内容", "文字", "文本"
    ] + actionTokens
    for token in baseTokens {
        let compactToken = compactIntentText(token)
        guard !compactToken.isEmpty else {
            continue
        }
        reduced = reduced.replacingOccurrences(of: compactToken, with: "")
    }
    return reduced.isEmpty || reduced.count <= 2
}

func magicianNormalizedText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func magicianSemanticPayload(
    from command: String,
    actionTokens: [String],
    extraCommandTokens: [String] = [],
    stripRecipientDirectives: Bool = false
) -> String? {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else {
        return nil
    }

    var candidate = trimmedCommand
    if stripRecipientDirectives {
        candidate = removingRecipientDirectiveSegments(in: candidate)
    }
    candidate = removingCommandSkeleton(
        in: candidate,
        actionTokens: actionTokens,
        extraCommandTokens: extraCommandTokens
    )
    candidate = candidate
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: magicianCommandTrimCharacterSet)
    candidate = trimmingLeadingActionVerb(
        in: candidate,
        actionTokens: actionTokens + extraCommandTokens
    )

    guard !candidate.isEmpty else {
        return nil
    }
    if isLikelyInstructionPhrase(
        candidate,
        command: trimmedCommand,
        actionTokens: actionTokens + extraCommandTokens
    ) {
        return nil
    }
    return candidate
}

func magicianResolvedPayload(
    selectedText: String,
    sourceText: String?,
    command: String,
    actionTokens: [String],
    extraCommandTokens: [String] = [],
    stripRecipientDirectives: Bool = false
) -> String? {
    if let selected = magicianNormalizedText(selectedText), !selected.isEmpty {
        return selected
    }

    let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if
        let source = magicianNormalizedText(sourceText),
        !isLikelyInstructionPhrase(
            source,
            command: normalizedCommand,
            actionTokens: actionTokens + extraCommandTokens
        )
    {
        return source
    }

    return magicianSemanticPayload(
        from: normalizedCommand,
        actionTokens: actionTokens,
        extraCommandTokens: extraCommandTokens,
        stripRecipientDirectives: stripRecipientDirectives
    )
}

private func removingRecipientDirectiveSegments(in value: String) -> String {
    var output = value
    let patterns = [
        #"(?i)(^|[，,。；;、\s])(?:发给|寄给|写给|to)\s*[^，,。；;、\n]+"#,
        #"(?i)(^|[，,。；;、\s])给\s*[^，,。；;、\n]+(?:发邮件|写邮件|邮件|mail|email)"#
    ]
    for pattern in patterns {
        output = output.replacingOccurrences(
            of: pattern,
            with: " ",
            options: .regularExpression
        )
    }
    return output
}

private func trimmingLeadingActionVerb(
    in value: String,
    actionTokens: [String]
) -> String {
    var output = value.trimmingCharacters(in: magicianCommandTrimCharacterSet)
    guard let first = output.first else {
        return output
    }

    let verb = String(first)
    let leadingVerbs: Set<String> = ["记", "写", "发", "建", "创", "改", "翻", "整", "安", "提"]
    guard leadingVerbs.contains(verb) else {
        return output
    }
    guard actionTokens.contains(where: { $0.hasPrefix(verb) }) else {
        return output
    }

    output = String(output.dropFirst())
        .trimmingCharacters(in: magicianCommandTrimCharacterSet)
    return output
}

private func removingCommandSkeleton(
    in value: String,
    actionTokens: [String],
    extraCommandTokens: [String]
) -> String {
    var output = value
    let tokens = Set(
        [
            "请帮我", "请你", "帮我", "帮忙", "麻烦", "拜托",
            "帮我把", "请把", "请将", "把", "将",
            "一下", "一下子", "整理一下", "整理成",
            "写一封", "写封", "草拟", "草稿"
        ] + actionTokens + extraCommandTokens
    )

    for token in tokens.sorted(by: { $0.count > $1.count }) {
        guard !token.isEmpty else {
            continue
        }
        output = output.replacingOccurrences(
            of: token,
            with: "",
            options: [.caseInsensitive]
        )
    }
    output = output.replacingOccurrences(
        of: #"(?:^|[，,。；;、\s])(?:请|帮我|麻烦|拜托)+(?=[，,。；;、\s]|$)"#,
        with: " ",
        options: .regularExpression
    )
    return output
}

private let magicianCommandTrimCharacterSet: CharacterSet = {
    CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
        .union(CharacterSet(charactersIn: "，。；：、（）【】《》“”‘’「」『』—-"))
}()
