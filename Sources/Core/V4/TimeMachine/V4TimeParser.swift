import Foundation

struct V4TimeParser: Sendable {
    private var calendar: Calendar
    private let locale: Locale

    init(
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "zh_CN")
    ) {
        var resolved = calendar
        resolved.locale = locale
        resolved.timeZone = calendar.timeZone
        self.calendar = resolved
        self.locale = locale
    }

    func parse(
        _ rawCommand: String,
        referenceDate: Date = Date()
    ) -> V4TimeParseResult {
        let command = normalizeWhitespace(rawCommand)

        if let relative = parseRelative(command, referenceDate: referenceDate) {
            return relative
        }

        if let weekday = parseWeekday(command, referenceDate: referenceDate) {
            return weekday
        }

        if let absolute = parseAbsolute(command, referenceDate: referenceDate) {
            return absolute
        }

        return V4TimeParseResult(
            status: .failed,
            kind: .ambiguous,
            matchedExpression: nil,
            normalizedText: command,
            scheduledAt: nil,
            resolutionSummary: "未识别到可用时间",
            hint: V4TimeParseHint(
                code: "time_not_understood",
                userMessage: "没听懂提醒时间。已支持：今晚 8 点、明早 9 点、下周一上午、30 分钟后。",
                debugMessage: "unsupported time expression: \(command)",
                supportedExamples: ["今晚 8 点", "明早 9 点", "下周一上午", "30 分钟后"]
            )
        )
    }

    func looksLikeTimeExpression(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if containsAny(normalized, tokens: ["今晚", "今早", "明早", "明天", "后天", "下周", "本周", "这周", "凌晨", "早上", "上午", "中午", "下午", "晚上"]) {
            return true
        }
        if normalized.range(of: #"\d+\s*(分钟|分|小时)\s*后"#, options: .regularExpression) != nil {
            return true
        }
        return normalized.range(of: #"\d{1,2}\s*(点|[:：])"#, options: .regularExpression) != nil
    }

    private func parseRelative(
        _ command: String,
        referenceDate: Date
    ) -> V4TimeParseResult? {
        guard
            let match = firstMatch(
                in: command,
                pattern: #"([0-9一二两三四五六七八九十半]+)\s*(分钟|分|小时)\s*后"#
            ),
            let amountText = match.capture(1, in: command),
            let unit = match.capture(2, in: command),
            let amount = parsedNumber(from: amountText)
        else {
            return nil
        }

        let seconds: TimeInterval
        if unit.contains("小时") {
            seconds = amount * 3_600
        } else {
            seconds = amount * 60
        }
        let scheduledAt = referenceDate.addingTimeInterval(seconds)
        let matched = match.fullMatch(in: command) ?? "\(amountText)\(unit)后"
        return V4TimeParseResult(
            status: .parsed,
            kind: .relative,
            matchedExpression: matched,
            normalizedText: strippedContent(from: command, matchedExpression: matched),
            scheduledAt: scheduledAt,
            resolutionSummary: "相对时间：\(matched)",
            hint: nil
        )
    }

    private func parseWeekday(
        _ command: String,
        referenceDate: Date
    ) -> V4TimeParseResult? {
        guard
            let match = firstMatch(
                in: command,
                pattern: #"((下下周|下周|本周|这周)?([一二三四五六日天])(?:\s*(早上|上午|中午|下午|晚上|凌晨))?(?:\s*(\d{1,2})(?:\s*[:：]\s*(\d{1,2}))?\s*点?(半|(\d{1,2})分?)?)?)"#
            ),
            let matched = match.fullMatch(in: command),
            let weekdayText = match.capture(3, in: command)
        else {
            return nil
        }

        guard let weekday = weekdayNumber(from: weekdayText) else {
            return nil
        }

        let weekOffset: Int
        switch match.capture(2, in: command) {
        case "下下周":
            weekOffset = 2
        case "下周":
            weekOffset = 1
        default:
            weekOffset = 0
        }

        let dayPart = match.capture(4, in: command)
        let explicitHour = match.capture(5, in: command).flatMap { Int($0) }
        let explicitMinute = match.capture(6, in: command).flatMap { Int($0) }
        let hasHalfHour = match.capture(7, in: command)?.contains("半") == true

        let baseDate = nextDate(
            weekday: weekday,
            weekOffset: weekOffset,
            referenceDate: referenceDate
        )
        let time = resolvedHourMinute(
            explicitHour: explicitHour,
            explicitMinute: explicitMinute,
            hasHalfHour: hasHalfHour,
            dayPart: dayPart
        )

        guard let scheduledAt = calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: baseDate
        ) else {
            return nil
        }

        return V4TimeParseResult(
            status: .parsed,
            kind: .weekday,
            matchedExpression: matched,
            normalizedText: strippedContent(from: command, matchedExpression: matched),
            scheduledAt: scheduledAt,
            resolutionSummary: "周内时间：\(matched)",
            hint: nil
        )
    }

    private func parseAbsolute(
        _ command: String,
        referenceDate: Date
    ) -> V4TimeParseResult? {
        let dayPart = detectedDayPart(in: command)
        let dayOffset = detectedDayOffset(in: command)
        let explicitTime = extractExplicitTime(in: command)

        guard dayOffset != nil || dayPart != nil || explicitTime != nil else {
            return nil
        }

        let offset = dayOffset ?? 0
        let baseDate = calendar.date(byAdding: .day, value: offset, to: referenceDate) ?? referenceDate
        let resolved = resolvedHourMinute(
            explicitHour: explicitTime?.hour,
            explicitMinute: explicitTime?.minute,
            hasHalfHour: explicitTime?.isHalfHour == true,
            dayPart: dayPart
        )

        guard let scheduledAt = calendar.date(
            bySettingHour: resolved.hour,
            minute: resolved.minute,
            second: 0,
            of: baseDate
        ) else {
            return nil
        }

        let matched = explicitTime?.matchedExpression ?? dayPart ?? detectedDayToken(in: command)
        return V4TimeParseResult(
            status: .parsed,
            kind: .absolute,
            matchedExpression: matched,
            normalizedText: strippedContent(from: command, matchedExpression: matched),
            scheduledAt: scheduledAt,
            resolutionSummary: "绝对时间：\(matched ?? "未命名时间")",
            hint: nil
        )
    }

    private func detectedDayOffset(in command: String) -> Int? {
        if command.contains("后天") {
            return 2
        }
        if command.contains("明天") || command.contains("明早") || command.contains("明晚") || command.contains("明晨") {
            return 1
        }
        if command.contains("今天") || command.contains("今晚") || command.contains("今早") || command.contains("今晨") {
            return 0
        }
        return nil
    }

    private func detectedDayToken(in command: String) -> String? {
        ["后天", "明天", "明早", "明晚", "今天", "今晚", "今早", "今晨"].first { command.contains($0) }
    }

    private func detectedDayPart(in command: String) -> String? {
        ["凌晨", "早上", "上午", "中午", "下午", "晚上", "今晚"].first { command.contains($0) }
    }

    private func extractExplicitTime(
        in command: String
    ) -> (hour: Int, minute: Int, isHalfHour: Bool, matchedExpression: String)? {
        guard
            let match = firstMatch(
                in: command,
                pattern: #"(\d{1,2})(?:\s*[:：]\s*(\d{1,2}))?\s*点?(半|(\d{1,2})分?)?"#
            ),
            let hourText = match.capture(1, in: command),
            let hour = Int(hourText)
        else {
            return nil
        }

        let minuteFromColon = match.capture(2, in: command).flatMap { Int($0) }
        let minuteFromSuffix = match.capture(4, in: command).flatMap { Int($0) }
        let isHalfHour = match.capture(3, in: command)?.contains("半") == true
        let minute = minuteFromColon ?? minuteFromSuffix ?? 0
        return (
            hour,
            minute,
            isHalfHour,
            match.fullMatch(in: command) ?? "\(hour)点"
        )
    }

    private func nextDate(
        weekday: Int,
        weekOffset: Int,
        referenceDate: Date
    ) -> Date {
        let currentWeekday = calendar.component(.weekday, from: referenceDate)
        var delta = weekday - currentWeekday
        if delta < 0 {
            delta += 7
        }
        if weekOffset > 0 {
            delta += weekOffset * 7
        } else if delta == 0 {
            delta += 7
        }
        return calendar.date(byAdding: .day, value: delta, to: referenceDate) ?? referenceDate
    }

    private func weekdayNumber(from text: String) -> Int? {
        switch text {
        case "日", "天":
            return 1
        case "一":
            return 2
        case "二":
            return 3
        case "三":
            return 4
        case "四":
            return 5
        case "五":
            return 6
        case "六":
            return 7
        default:
            return nil
        }
    }

    private func resolvedHourMinute(
        explicitHour: Int?,
        explicitMinute: Int?,
        hasHalfHour: Bool,
        dayPart: String?
    ) -> (hour: Int, minute: Int) {
        let baseMinute = hasHalfHour ? 30 : (explicitMinute ?? 0)
        guard let explicitHour else {
            return defaultHourMinute(for: dayPart)
        }

        var hour = explicitHour
        if let dayPart {
            switch dayPart {
            case "下午":
                if hour < 12 {
                    hour += 12
                }
            case "晚上", "今晚":
                if hour < 12 {
                    hour += 12
                }
                if hour < 18 {
                    hour = max(18, hour)
                }
            case "中午":
                if hour < 11 {
                    hour += 12
                }
            case "凌晨":
                if hour == 12 {
                    hour = 0
                }
            default:
                break
            }
        }
        return (hour, baseMinute)
    }

    private func defaultHourMinute(for dayPart: String?) -> (hour: Int, minute: Int) {
        switch dayPart {
        case "凌晨":
            return (1, 0)
        case "早上", "上午":
            return (9, 0)
        case "中午":
            return (12, 0)
        case "下午":
            return (15, 0)
        case "晚上", "今晚":
            return (20, 0)
        default:
            return (9, 0)
        }
    }

    private func strippedContent(
        from command: String,
        matchedExpression: String?
    ) -> String {
        var value = command
        if let matchedExpression, !matchedExpression.isEmpty {
            value = value.replacingOccurrences(of: matchedExpression, with: " ")
        }

        let patterns = [
            #"提醒我"#,
            #"提醒一下"#,
            #"提醒"#,
            #"记一下"#,
            #"记一条"#,
            #"记下来"#,
            #"记住"#,
            #"今天"#,
            #"今晚"#,
            #"今早"#,
            #"今晨"#,
            #"明天"#,
            #"明早"#,
            #"明晨"#,
            #"明晚"#,
            #"后天"#,
            #"下下周"#,
            #"下周"#,
            #"本周"#,
            #"这周"#,
            #"周[一二三四五六日天]"#,
            #"早上"#,
            #"上午"#,
            #"中午"#,
            #"下午"#,
            #"晚上"#,
            #"凌晨"#,
            #"到时候"#,
            #"之后"#,
            #"稍后"#,
            #"帮我"#,
            #"请"#,
            #"："#,
            #":"#
        ]

        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let normalized = normalizeWhitespace(value)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return normalized.isEmpty ? command : normalized
    }

    private func parsedNumber(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "半" {
            return 0.5
        }
        if let value = Double(trimmed) {
            return value
        }

        let mapping: [Character: Double] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]

        if trimmed == "十" {
            return 10
        }
        if trimmed.count == 2, trimmed.first == "十", let second = trimmed.last, let value = mapping[second] {
            return 10 + value
        }
        if trimmed.count == 2, trimmed.last == "十", let first = trimmed.first, let value = mapping[first] {
            return value * 10
        }
        if
            trimmed.count == 3,
            let first = trimmed.first,
            trimmed[trimmed.index(after: trimmed.startIndex)] == "十",
            let last = trimmed.last,
            let tens = mapping[first],
            let ones = mapping[last]
        {
            return tens * 10 + ones
        }

        return mapping[trimmed.first ?? " "] ?? nil
    }

    private func firstMatch(
        in text: String,
        pattern: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }
}

private extension NSTextCheckingResult {
    func capture(_ index: Int, in text: String) -> String? {
        guard numberOfRanges > index, let range = Range(range(at: index), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fullMatch(in text: String) -> String? {
        guard let range = Range(range, in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
