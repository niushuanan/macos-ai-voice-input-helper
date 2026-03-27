import Combine
import Foundation

enum MagicianMailDeliveryMode: String, Codable, Equatable {
    case draftOnly = "draft_only"
    case autoSendIfResolved = "auto_send_if_resolved"
}

enum ResolvedMailRecipientSource: String, Codable, Equatable {
    case explicit
    case addressBook
    case llm
}

struct ResolvedMailRecipient: Codable, Equatable {
    let address: String
    let source: ResolvedMailRecipientSource
    let confidence: Double
    let matchedHint: String?
}

struct MailRecipientResolution: Equatable {
    let primaryRecipient: ResolvedMailRecipient?
    let alternateRecipients: [ResolvedMailRecipient]
    let unresolvedHints: [String]
    let isAmbiguous: Bool

    init(
        primaryRecipient: ResolvedMailRecipient?,
        alternateRecipients: [ResolvedMailRecipient],
        unresolvedHints: [String],
        isAmbiguous: Bool
    ) {
        self.primaryRecipient = primaryRecipient
        self.alternateRecipients = alternateRecipients
        self.unresolvedHints = unresolvedHints
        self.isAmbiguous = isAmbiguous
    }

    init(
        recipients: [ResolvedMailRecipient],
        unresolvedHints: [String]
    ) {
        self.primaryRecipient = recipients.first
        self.alternateRecipients = Array(recipients.dropFirst())
        self.unresolvedHints = unresolvedHints
        self.isAmbiguous = false
    }

    var recipients: [ResolvedMailRecipient] {
        if let primaryRecipient {
            return [primaryRecipient] + alternateRecipients
        }
        return alternateRecipients
    }

    var addresses: [String] {
        guard let primaryRecipient else {
            return []
        }
        return [primaryRecipient.address]
    }
}

struct MailAddressBookEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var email: String
    var aliases: [String]
    var note: String
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        email: String,
        aliases: [String] = [],
        note: String = "",
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = Self.normalizeAliases(aliases)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastUsedAt = lastUsedAt
    }

    static func normalizeAliases(_ aliases: [String]) -> [String] {
        var deduped: [String] = []
        var seen = Set<String>()
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = MailAddressBookStore.normalizedLookupKey(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else {
                continue
            }
            deduped.append(trimmed)
        }
        return deduped
    }
}

struct MailAddressBookMatch: Equatable {
    let entry: MailAddressBookEntry
    let matchedHint: String
    let confidence: Double
}

@MainActor
final class MailAddressBookStore: ObservableObject {
    nonisolated static let defaultStorageKey = "magician.mail.address_book.v1"

    @Published private(set) var entries: [MailAddressBookEntry]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = MailAddressBookStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.entries = Self.decodeEntries(from: defaults.data(forKey: storageKey))
    }

    func save(
        id: UUID? = nil,
        displayName: String,
        email: String,
        aliases: [String],
        note: String
    ) -> MailAddressBookEntry {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingMatchID = entries.first(where: {
            Self.normalizedLookupKey($0.email) == Self.normalizedLookupKey(normalizedEmail)
        })?.id
        let entry = MailAddressBookEntry(
            id: id ?? existingMatchID ?? UUID(),
            displayName: displayName,
            email: normalizedEmail,
            aliases: aliases,
            note: note,
            lastUsedAt: currentLastUsedAt(for: id ?? existingMatchID)
        )

        if let id, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else if let index = entries.firstIndex(where: {
            Self.normalizedLookupKey($0.email) == Self.normalizedLookupKey(normalizedEmail)
        }) {
            var updated = entry
            updated.lastUsedAt = entries[index].lastUsedAt
            entries[index] = updated
        } else {
            entries.append(entry)
        }

        sortEntries()
        persist()
        return entry
    }

    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries.remove(at: index)
        persist()
    }

    func markUsed(addresses: [String], at date: Date = Date()) {
        guard !addresses.isEmpty else {
            return
        }

        let normalizedAddresses = Set(addresses.map(Self.normalizedLookupKey))
        var didChange = false
        for index in entries.indices {
            let key = Self.normalizedLookupKey(entries[index].email)
            guard normalizedAddresses.contains(key) else {
                continue
            }
            entries[index].lastUsedAt = date
            didChange = true
        }

        guard didChange else {
            return
        }
        sortEntries()
        persist()
    }

    func match(for hint: String) -> MailAddressBookMatch? {
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHint = Self.normalizedLookupKey(trimmedHint)
        guard !normalizedHint.isEmpty else {
            return nil
        }

        for entry in entries {
            let exactKeys = entryLookupKeys(for: entry)
            if exactKeys.contains(normalizedHint) {
                return MailAddressBookMatch(
                    entry: entry,
                    matchedHint: trimmedHint,
                    confidence: 1.0
                )
            }
        }

        for entry in entries {
            let fuzzyKeys = entryLookupKeys(for: entry)
            if fuzzyKeys.contains(where: { normalizedHint.contains($0) || $0.contains(normalizedHint) }) {
                return MailAddressBookMatch(
                    entry: entry,
                    matchedHint: trimmedHint,
                    confidence: 0.86
                )
            }
        }

        return nil
    }

    static func normalizeAliases(from rawText: String) -> [String] {
        rawText
            .split(separator: ",")
            .flatMap { chunk in
                chunk.split(whereSeparator: \.isNewline)
            }
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { partialResult, item in
                let key = normalizedLookupKey(item)
                if !partialResult.contains(where: { normalizedLookupKey($0) == key }) {
                    partialResult.append(item)
                }
            }
    }

    nonisolated static func normalizedLookupKey(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }

    private func entryLookupKeys(for entry: MailAddressBookEntry) -> Set<String> {
        Set(
            ([entry.displayName, entry.email] + entry.aliases)
                .map(Self.normalizedLookupKey)
                .filter { !$0.isEmpty }
        )
    }

    private func currentLastUsedAt(for id: UUID?) -> Date? {
        guard let id, let existing = entries.first(where: { $0.id == id }) else {
            return nil
        }
        return existing.lastUsedAt
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftName = lhs.displayName.isEmpty ? lhs.email : lhs.displayName
                let rightName = rhs.displayName.isEmpty ? rhs.email : rhs.displayName
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func decodeEntries(from data: Data?) -> [MailAddressBookEntry] {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([MailAddressBookEntry].self, from: data)
        else {
            return []
        }
        return decoded.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftName = lhs.displayName.isEmpty ? lhs.email : lhs.displayName
                let rightName = rhs.displayName.isEmpty ? rhs.email : rhs.displayName
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
        }
    }
}

@MainActor
protocol MagicianMailRecipientResolving {
    func resolve(
        command: String,
        selection: String,
        explicitRecipients: [String],
        recipientHints: [String]
    ) async -> MailRecipientResolution

    func shouldAutoSend(
        deliveryMode: MagicianMailDeliveryMode?,
        resolution: MailRecipientResolution
    ) -> Bool
}

private struct LLMMailRecipientCandidate: Codable, Equatable {
    let address: String
    let matchedHint: String?
    let confidence: Double
}

private struct LLMMailRecipientPayload: Codable, Equatable {
    let recipients: [LLMMailRecipientCandidate]
}

@MainActor
final class LLMMailRecipientResolver: MagicianMailRecipientResolving {
    private let addressBookStore: MailAddressBookStore
    private let providerSettingsStore: ProviderSettingsStore?
    private let generationProvider: any TextGenerationProvider
    private let confidenceThreshold: Double
    private let ambiguityGapThreshold: Double

    init(
        addressBookStore: MailAddressBookStore,
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        confidenceThreshold: Double = 0.70,
        ambiguityGapThreshold: Double = 0.10
    ) {
        self.addressBookStore = addressBookStore
        self.providerSettingsStore = providerSettingsStore
        self.generationProvider = generationProvider
        self.confidenceThreshold = confidenceThreshold
        self.ambiguityGapThreshold = ambiguityGapThreshold
    }

    func resolve(
        command: String,
        selection: String,
        explicitRecipients: [String],
        recipientHints: [String]
    ) async -> MailRecipientResolution {
        var candidatesByHintKey: [String: ResolvedMailRecipient] = [:]
        let hintedExplicitRecipients = recipientHints.filter { isValidEmail($0) }

        for address in normalizeEmails(explicitRecipients + hintedExplicitRecipients) {
            let recipient = ResolvedMailRecipient(
                address: address,
                source: .explicit,
                confidence: 1.0,
                matchedHint: address
            )
            registerCandidate(
                recipient,
                hint: address,
                into: &candidatesByHintKey
            )
        }

        let normalizedHints = normalizeHints(recipientHints)
        var unresolvedHints: [String] = []

        for hint in normalizedHints {
            guard let match = addressBookStore.match(for: hint) else {
                unresolvedHints.append(hint)
                continue
            }

            let recipient = ResolvedMailRecipient(
                address: match.entry.email,
                source: .addressBook,
                confidence: match.confidence,
                matchedHint: match.matchedHint
            )
            registerCandidate(
                recipient,
                hint: hint,
                into: &candidatesByHintKey
            )
        }

        if !unresolvedHints.isEmpty {
            let llmRecipients = await inferRecipientsWithLLM(
                command: command,
                selection: selection,
                unresolvedHints: unresolvedHints
            )

            var remainingHints = unresolvedHints
            for candidate in llmRecipients {
                guard isValidEmail(candidate.address) else {
                    continue
                }

                let matchedHint = candidate.matchedHint?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let recipient = ResolvedMailRecipient(
                    address: candidate.address,
                    source: .llm,
                    confidence: max(0, min(1, candidate.confidence)),
                    matchedHint: matchedHint
                )
                registerCandidate(
                    recipient,
                    hint: matchedHint ?? candidate.address,
                    into: &candidatesByHintKey
                )

                if let matchedHint, !matchedHint.isEmpty {
                    remainingHints.removeAll {
                        MailAddressBookStore.normalizedLookupKey($0) == MailAddressBookStore.normalizedLookupKey(matchedHint)
                    }
                } else if remainingHints.count == 1 {
                    remainingHints.removeAll()
                }
            }
            unresolvedHints = remainingHints
        }

        let orderedCandidates = rankedCandidates(from: Array(candidatesByHintKey.values))
        let isAmbiguous = isTopCandidateAmbiguous(in: orderedCandidates)
        let primaryRecipient: ResolvedMailRecipient?
        if
            let top = orderedCandidates.first,
            !isAmbiguous,
            isEligiblePrimaryRecipient(top)
        {
            primaryRecipient = top
        } else {
            primaryRecipient = nil
        }

        let alternateRecipients = orderedCandidates.filter { candidate in
            guard let primaryRecipient else {
                return true
            }
            return MailAddressBookStore.normalizedLookupKey(candidate.address)
                != MailAddressBookStore.normalizedLookupKey(primaryRecipient.address)
        }

        return MailRecipientResolution(
            primaryRecipient: primaryRecipient,
            alternateRecipients: alternateRecipients,
            unresolvedHints: unresolvedHints,
            isAmbiguous: isAmbiguous
        )
    }

    func shouldAutoSend(
        deliveryMode: MagicianMailDeliveryMode?,
        resolution: MailRecipientResolution
    ) -> Bool {
        guard deliveryMode == .autoSendIfResolved else {
            return false
        }
        guard let primaryRecipient = resolution.primaryRecipient else {
            return false
        }
        guard resolution.unresolvedHints.isEmpty else {
            return false
        }
        guard !resolution.isAmbiguous else {
            return false
        }
        return isEligiblePrimaryRecipient(primaryRecipient)
    }

    private func registerCandidate(
        _ candidate: ResolvedMailRecipient,
        hint: String,
        into storage: inout [String: ResolvedMailRecipient]
    ) {
        let hintKey = MailAddressBookStore.normalizedLookupKey(hint)
        let fallbackKey = MailAddressBookStore.normalizedLookupKey(candidate.address)
        let key = hintKey.isEmpty ? fallbackKey : hintKey
        guard !key.isEmpty else {
            return
        }

        if let existing = storage[key] {
            storage[key] = betterRecipient(existing, candidate)
        } else {
            storage[key] = candidate
        }
    }

    private func rankedCandidates(from recipients: [ResolvedMailRecipient]) -> [ResolvedMailRecipient] {
        var dedupedByAddress: [String: ResolvedMailRecipient] = [:]
        for recipient in recipients {
            let addressKey = MailAddressBookStore.normalizedLookupKey(recipient.address)
            guard !addressKey.isEmpty else {
                continue
            }
            if let existing = dedupedByAddress[addressKey] {
                dedupedByAddress[addressKey] = betterRecipient(existing, recipient)
            } else {
                dedupedByAddress[addressKey] = recipient
            }
        }

        return dedupedByAddress.values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            let lhsPriority = sourcePriority(lhs.source)
            let rhsPriority = sourcePriority(rhs.source)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhs.address.localizedCaseInsensitiveCompare(rhs.address) == .orderedAscending
        }
    }

    private func isTopCandidateAmbiguous(in candidates: [ResolvedMailRecipient]) -> Bool {
        guard candidates.count > 1 else {
            return false
        }
        let first = candidates[0]
        let second = candidates[1]
        let confidenceGap = first.confidence - second.confidence
        return confidenceGap < ambiguityGapThreshold
    }

    private func isEligiblePrimaryRecipient(_ recipient: ResolvedMailRecipient) -> Bool {
        switch recipient.source {
        case .explicit:
            return recipient.confidence >= 1.0
        case .addressBook:
            if recipient.confidence >= 1.0 {
                return true
            }
            return recipient.confidence >= confidenceThreshold
        case .llm:
            return recipient.confidence >= confidenceThreshold
        }
    }

    private func sourcePriority(_ source: ResolvedMailRecipientSource) -> Int {
        switch source {
        case .explicit:
            return 3
        case .addressBook:
            return 2
        case .llm:
            return 1
        }
    }

    private func betterRecipient(
        _ lhs: ResolvedMailRecipient,
        _ rhs: ResolvedMailRecipient
    ) -> ResolvedMailRecipient {
        if rhs.confidence > lhs.confidence {
            return rhs
        }
        if rhs.confidence < lhs.confidence {
            return lhs
        }
        if sourcePriority(rhs.source) > sourcePriority(lhs.source) {
            return rhs
        }
        return lhs
    }

    private func inferRecipientsWithLLM(
        command: String,
        selection: String,
        unresolvedHints: [String]
    ) async -> [LLMMailRecipientCandidate] {
        guard
            let providerSettingsStore,
            providerSettingsStore.isRewriteConfigurationValid,
            let apiKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider(),
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        let template = buildRecipientResolverPrompt(
            command: command,
            selection: selection,
            unresolvedHints: unresolvedHints,
            addressBookEntries: addressBookStore.entries
        )

        do {
            let response = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: template.systemPrompt,
                    userPrompt: template.userPrompt,
                    temperature: 0.1,
                    maxOutputTokens: 260
                ),
                configuration: providerSettingsStore.rewriteConfiguration,
                apiKey: apiKey
            )
            let payload: LLMMailRecipientPayload = try decodePayload(
                from: response.outputText
            )
            return payload.recipients
        } catch {
            return []
        }
    }

    private func buildRecipientResolverPrompt(
        command: String,
        selection: String,
        unresolvedHints: [String],
        addressBookEntries: [MailAddressBookEntry]
    ) -> RewritePromptTemplate {
        let addressBookText: String
        if addressBookEntries.isEmpty {
            addressBookText = "(empty)"
        } else {
            addressBookText = addressBookEntries.map { entry in
                let aliases = entry.aliases.isEmpty ? "(none)" : entry.aliases.joined(separator: ", ")
                let note = entry.note.isEmpty ? "(none)" : entry.note
                return "- name: \(entry.displayName)\n  email: \(entry.email)\n  aliases: \(aliases)\n  note: \(note)"
            }.joined(separator: "\n")
        }

        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a mail recipient resolver for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Output JSON schema:
        {
          "recipients": [
            {
              "address": "name@example.com",
              "matchedHint": "string",
              "confidence": 0.0
            }
          ]
        }

        Rules:
        1) Resolve each unresolved hint to the most likely email address when possible.
        2) You may use the address book as strong evidence, but you may also infer a new address when the spoken command strongly implies one.
        3) Confidence must be between 0 and 1.
        4) Only output valid email addresses.
        5) Do not fabricate extra recipients beyond the unresolved hints.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>

        Unresolved recipient hints:
        <<<HINTS
        \(unresolvedHints.joined(separator: "\n"))
        HINTS>>>

        Address book snapshot:
        <<<ADDRESS_BOOK
        \(addressBookText)
        ADDRESS_BOOK>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func decodePayload<T: Decodable>(from output: String) throws -> T {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped: String
        if trimmed.hasPrefix("```") {
            stripped = trimmed
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stripped = trimmed
        }

        guard
            let firstBrace = stripped.firstIndex(of: "{"),
            let lastBrace = stripped.lastIndex(of: "}")
        else {
            throw NSError(domain: "PulseType.MailRecipientResolver", code: 1)
        }

        let jsonText = String(stripped[firstBrace...lastBrace])
        guard let data = jsonText.data(using: .utf8) else {
            throw NSError(domain: "PulseType.MailRecipientResolver", code: 2)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func normalizeHints(_ hints: [String]) -> [String] {
        var deduped: [String] = []
        var seen = Set<String>()
        for hint in hints {
            let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if isValidEmail(trimmed) {
                continue
            }
            let key = MailAddressBookStore.normalizedLookupKey(trimmed)
            guard seen.insert(key).inserted else {
                continue
            }
            deduped.append(trimmed)
        }
        return deduped
    }

    private func normalizeEmails(_ values: [String]) -> [String] {
        var deduped: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEmail(trimmed) else {
                continue
            }
            let key = MailAddressBookStore.normalizedLookupKey(trimmed)
            guard seen.insert(key).inserted else {
                continue
            }
            deduped.append(trimmed)
        }
        return deduped
    }

    private func isValidEmail(_ value: String) -> Bool {
        Self.emailRegex.firstMatch(
            in: value,
            options: [],
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
        options: [.caseInsensitive]
    )
}
