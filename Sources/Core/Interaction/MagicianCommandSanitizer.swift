import Foundation

enum MagicianCommandSanitizer {
    static func sanitize(_ rawInstruction: String) -> SkillApplyResult {
        let trimmed = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SkillApplyResult(text: "", appliedSkills: [])
        }

        var value = trimmed
        for token in ["左", "右", "上", "下", "前", "后"] {
            value = collapseRepeatedToken(in: value, token: token)
        }
        for word in ["shift", "option", "command", "control", "ctrl"] {
            value = collapseRepeatedWord(in: value, word: word)
        }
        value = value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return SkillApplyResult(
            text: value.trimmingCharacters(in: .whitespacesAndNewlines),
            appliedSkills: []
        )
    }

    private static func collapseRepeatedToken(in text: String, token: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(\(escaped))\\s*\\1+"
        return replacingMatches(in: text, pattern: pattern, template: "$1")
    }

    private static func collapseRepeatedWord(in text: String, word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(?i)\\b(\(escaped))\\b(?:\\s+\\1\\b)+"
        return replacingMatches(in: text, pattern: pattern, template: "$1")
    }

    private static func replacingMatches(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
