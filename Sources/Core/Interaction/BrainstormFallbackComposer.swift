import Foundation

enum BrainstormFallbackComposer {
    static func summary(for transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var points = [
            "先确认讨论目标与边界，再推进执行。",
            "优先完成最小可行版本，复杂项后置。",
            "按优先级拆分任务并明确负责人。"
        ]
        if let firstLine = normalized
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            points[0] = "本次讨论核心为：\(firstLine.prefix(28))。"
        }
        return points.map { "- \($0)" }.joined(separator: "\n")
    }

    static func dialogue(for transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "A: （暂无有效转写内容）"
        }

        let rawLines = normalized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let roles = ["A", "B", "C"]
        let lines = rawLines.isEmpty ? [normalized] : rawLines

        return lines.enumerated().map { index, line in
            if line.range(of: #"^[A-Z][A-Z0-9]*\s*[:：]"#, options: .regularExpression) != nil {
                return line.replacingOccurrences(of: "：", with: ":")
            }
            return "\(roles[index % roles.count]): \(line)"
        }
        .joined(separator: "\n")
    }
}
