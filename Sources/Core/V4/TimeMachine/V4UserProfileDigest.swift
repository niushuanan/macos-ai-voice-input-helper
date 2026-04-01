import Foundation

struct V4DigestFacet: Codable, Equatable, Sendable, Identifiable {
    let value: String
    let count: Int

    var id: String { value }
}

enum V4ReminderTimeSlot: String, CaseIterable, Codable, Equatable, Sendable {
    case morning
    case noon
    case afternoon
    case evening
    case night

    var displayName: String {
        switch self {
        case .morning:
            return "上午"
        case .noon:
            return "中午"
        case .afternoon:
            return "下午"
        case .evening:
            return "晚上"
        case .night:
            return "深夜"
        }
    }

    static func resolve(for date: Date, calendar: Calendar = .current) -> Self {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 6..<11:
            return .morning
        case 11..<14:
            return .noon
        case 14..<18:
            return .afternoon
        case 18..<23:
            return .evening
        default:
            return .night
        }
    }
}

struct V4UserProfileDigest: Codable, Equatable, Sendable {
    let frequentTopics: [V4DigestFacet]
    let reminderTimeSlots: [V4DigestFacet]
    let actionTags: [V4DigestFacet]
    let generatedAt: Date

    static let empty = V4UserProfileDigest(
        frequentTopics: [],
        reminderTimeSlots: [],
        actionTags: [],
        generatedAt: .distantPast
    )

    var isEmpty: Bool {
        frequentTopics.isEmpty && reminderTimeSlots.isEmpty && actionTags.isEmpty
    }

    var briefSummary: String? {
        guard !isEmpty else {
            return nil
        }

        var lines: [String] = []
        if !frequentTopics.isEmpty {
            lines.append("高频主题：\(frequentTopics.prefix(3).map(\.value).joined(separator: "、"))")
        }
        if !reminderTimeSlots.isEmpty {
            lines.append("常设提醒时段：\(reminderTimeSlots.prefix(2).map(\.value).joined(separator: "、"))")
        }
        if !actionTags.isEmpty {
            lines.append("常见动作：\(actionTags.prefix(2).map(\.value).joined(separator: "、"))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "；")
    }
}

enum V4UserProfileDigestBuilder {
    static func make(
        from items: [V4TimeItem],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> V4UserProfileDigest {
        let topicCounts = rankedValues(
            from: items.flatMap { item in
                item.tags.filter { !$0.hasPrefix("action:") }
            }
        )
        let slotCounts = rankedValues(
            from: items.compactMap { item in
                guard let scheduledAt = item.scheduledAt else {
                    return nil
                }
                return V4ReminderTimeSlot.resolve(for: scheduledAt, calendar: calendar).displayName
            }
        )
        let actionCounts = rankedValues(
            from: items.flatMap { item in
                item.tags.compactMap { tag in
                    guard tag.hasPrefix("action:") else {
                        return nil
                    }
                    return actionLabel(from: String(tag.dropFirst("action:".count)))
                }
            }
        )

        return V4UserProfileDigest(
            frequentTopics: Array(topicCounts.prefix(5)),
            reminderTimeSlots: Array(slotCounts.prefix(4)),
            actionTags: Array(actionCounts.prefix(5)),
            generatedAt: now
        )
    }

    private static func rankedValues(from values: [String]) -> [V4DigestFacet] {
        var counts: [String: Int] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            counts[trimmed, default: 0] += 1
        }

        return counts
            .map { V4DigestFacet(value: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.value < rhs.value
            }
    }

    private static func actionLabel(from raw: String) -> String {
        switch raw {
        case "capture":
            return "灵感记录"
        case "remind":
            return "本地提醒"
        default:
            return raw
        }
    }
}
