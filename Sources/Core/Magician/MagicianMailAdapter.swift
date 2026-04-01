import AppKit
import Foundation

protocol MagicianMailAppleScripting {
    func openMessage(
        recipients: [String],
        subject: String,
        body: String,
        shouldSend: Bool
    ) async -> MagicianProcessResult
}

protocol MagicianMailDraftFallbackOpening {
    func openDraft(
        recipients: [String],
        subject: String,
        body: String
    ) -> Bool
}

struct DefaultMagicianMailAppleScripter: MagicianMailAppleScripting {
    func openMessage(
        recipients: [String],
        subject: String,
        body: String,
        shouldSend: Bool
    ) async -> MagicianProcessResult {
        var arguments = [subject, body, shouldSend ? "1" : "0"]
        arguments.append(contentsOf: recipients)
        return await runOsaScript(
            lines: [
                "on joinList(itemList, delimiterValue)",
                "set previousDelimiters to AppleScript's text item delimiters",
                "set AppleScript's text item delimiters to delimiterValue",
                "set joinedValue to itemList as string",
                "set AppleScript's text item delimiters to previousDelimiters",
                "return joinedValue",
                "end joinList",
                "on recipientAddresses(recipientItems)",
                "set outputList to {}",
                "repeat with recipientItem in recipientItems",
                "set end of outputList to (address of recipientItem) as string",
                "end repeat",
                "return outputList",
                "end recipientAddresses",
                "on recipientSummaryMatches(candidateRecipients, expectedRecipients)",
                "if (count of candidateRecipients) is not (count of expectedRecipients) then return false",
                "repeat with expectedRecipient in expectedRecipients",
                "if (contents of expectedRecipient) is not in candidateRecipients then return false",
                "end repeat",
                "return true",
                "end recipientSummaryMatches",
                "on run argv",
                "set mailSubject to item 1 of argv",
                "set mailBody to item 2 of argv",
                "set shouldSendNow to (item 3 of argv) is equal to \"1\"",
                "set recipientList to {}",
                "if (count of argv) > 3 then",
                "repeat with idx from 4 to (count of argv)",
                "set end of recipientList to (item idx of argv)",
                "end repeat",
                "end if",
                "set recipientSummary to my joinList(recipientList, \"|\")",
                "tell application \"Mail\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                "set draftMessage to make new outgoing message with properties {visible:true, subject:mailSubject, content:mailBody & return & return}",
                "tell draftMessage",
                "repeat with addr in recipientList",
                "make new to recipient at end of to recipients with properties {address:(contents of addr)}",
                "end repeat",
                "end tell",
                "set draftID to \"missing\"",
                "try",
                "set draftID to (id of draftMessage) as string",
                "end try",
                "if shouldSendNow then",
                "set sentMessageID to \"\"",
                "set verifyDeadline to (current date) + 8",
                "send draftMessage",
                "repeat while sentMessageID is \"\" and ((current date) < verifyDeadline)",
                "try",
                "set sentCandidates to (messages of sent mailbox whose subject is mailSubject)",
                "repeat with sentCandidate in sentCandidates",
                "set candidateRecipients to my recipientAddresses(to recipients of sentCandidate)",
                "if my recipientSummaryMatches(candidateRecipients, recipientList) then",
                "set sentMessageID to (message id of sentCandidate) as string",
                "if sentMessageID is not \"\" then exit repeat",
                "end if",
                "end if",
                "end repeat",
                "end try",
                "if sentMessageID is \"\" then delay 0.25",
                "end repeat",
                "if sentMessageID is \"\" then error \"mail send verification failed\"",
                "return \"mail_status=sent\" & return & \"message_id=\" & sentMessageID & return & \"subject=\" & mailSubject & return & \"recipients=\" & recipientSummary & return & \"mailbox=sent\"",
                "end if",
                "return \"mail_status=draft\" & return & \"draft_id=\" & draftID & return & \"subject=\" & mailSubject & return & \"recipients=\" & recipientSummary & return & \"visible=\" & ((visible of draftMessage) as string)",
                "end tell",
                "end run"
            ],
            arguments: arguments
        )
    }
}

struct DefaultMagicianMailDraftFallbackOpener: MagicianMailDraftFallbackOpening {
    func openDraft(
        recipients: [String],
        subject: String,
        body: String
    ) -> Bool {
        if
            let service = NSSharingService(named: .composeEmail),
            service.canPerform(withItems: [body as NSString])
        {
            service.recipients = recipients
            service.subject = subject
            service.perform(withItems: [body])
            return true
        }

        var components = URLComponents()
        components.scheme = "mailto"
        if !recipients.isEmpty {
            components.path = recipients.joined(separator: ",")
        }
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        guard let url = components.url else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
struct MagicianMailAdapter {
    private struct MailDraftSummary {
        let title: String
        let body: String
    }

    private struct MailScriptEvidence {
        let status: String
        let draftID: String?
        let messageID: String?
        let subject: String
        let recipients: [String]
        let mailbox: String?
        let visible: Bool?

        var evidenceSummary: String {
            var parts: [String] = ["mail_status=\(status)"]
            if let draftID {
                parts.append("draft_id=\(draftID)")
            }
            if let messageID {
                parts.append("message_id=\(messageID)")
            }
            if let mailbox {
                parts.append("mailbox=\(mailbox)")
            }
            if let visible {
                parts.append("visible=\(visible)")
            }
            if !recipients.isEmpty {
                parts.append("recipients=\(recipients.joined(separator: "|"))")
            }
            parts.append("subject=\(subject)")
            return parts.joined(separator: "; ")
        }

        var isVerifiedDraft: Bool {
            status == "draft" && draftID != nil && visible == true
        }

        var isVerifiedSent: Bool {
            status == "sent" && messageID != nil && mailbox == "sent"
        }
    }

    private struct MailSummaryPayload: Codable {
        let title: String
        let body: String
    }

    private let addressBookStore: MailAddressBookStore
    private let recipientResolver: any MagicianMailRecipientResolving
    private let appleScripter: any MagicianMailAppleScripting
    private let fallbackOpener: any MagicianMailDraftFallbackOpening
    private let mailCapabilityProvider: () -> MagicianMailCapabilitySnapshot
    private let providerSettingsStore: ProviderSettingsStore?
    private let generationProvider: any TextGenerationProvider

    init(
        addressBookStore: MailAddressBookStore? = nil,
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        recipientResolver: (any MagicianMailRecipientResolving)? = nil,
        appleScripter: any MagicianMailAppleScripting = DefaultMagicianMailAppleScripter(),
        fallbackOpener: any MagicianMailDraftFallbackOpening = DefaultMagicianMailDraftFallbackOpener(),
        mailCapabilityProvider: @escaping () -> MagicianMailCapabilitySnapshot = {
            MagicianMailCapabilitySnapshot.current()
        }
    ) {
        let resolvedAddressBookStore = addressBookStore ?? MailAddressBookStore()
        self.addressBookStore = resolvedAddressBookStore
        self.recipientResolver = recipientResolver ?? LLMMailRecipientResolver(
            addressBookStore: resolvedAddressBookStore,
            providerSettingsStore: providerSettingsStore,
            generationProvider: generationProvider
        )
        self.appleScripter = appleScripter
        self.fallbackOpener = fallbackOpener
        self.mailCapabilityProvider = mailCapabilityProvider
        self.providerSettingsStore = providerSettingsStore
        self.generationProvider = generationProvider
    }

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        let subject = resolvedSubject(intent: intent, context: context)
        let body = resolvedBody(intent: intent, context: context)
        let resolution = await recipientResolver.resolve(
            command: context.command,
            selection: context.selectedText,
            explicitRecipients: intent.params.mailTo ?? [],
            recipientHints: intent.params.mailRecipientHints ?? []
        )
        let recipients = resolution.addresses
        let shouldSend = recipientResolver.shouldAutoSend(
            deliveryMode: intent.params.mailDeliveryMode,
            resolution: resolution
        )
        let capability = mailCapabilityProvider()

        if capability.mailAppAvailable {
            let scriptResult = await appleScripter.openMessage(
                recipients: recipients,
                subject: subject,
                body: body,
                shouldSend: shouldSend
            )
            if scriptResult.exitCode == 0 {
                let evidence = parsedMailScriptEvidence(from: scriptResult.stdout)
                if let primaryRecipient = resolution.primaryRecipient?.address {
                    addressBookStore.markUsed(addresses: [primaryRecipient])
                }
                if shouldSend {
                    guard
                        let evidence,
                        evidence.isVerifiedSent,
                        evidence.subject == subject,
                        evidence.recipients == recipients
                    else {
                        throw MagicianError(
                            code: .toolExecutionFailed,
                            userMessage: "邮件发送缺少硬证据，已判定失败。",
                            debugMessage: "mail send unverified; stdout=\(scriptResult.stdout)",
                            recoverAction: "retry_command"
                        )
                    }
                    return buildResult(
                        subject: subject,
                        body: body,
                        resolution: resolution,
                        shouldSend: shouldSend,
                        fallbackUsed: false,
                        evidence: evidence
                    )
                }
                if
                    let evidence,
                    evidence.isVerifiedDraft,
                    evidence.subject == subject,
                    evidence.recipients == recipients
                {
                    return buildResult(
                        subject: subject,
                        body: body,
                        resolution: resolution,
                        shouldSend: false,
                        fallbackUsed: false,
                        evidence: evidence
                    )
                }
                return buildDraftWindowOpenedResult(
                    subject: subject,
                    body: body,
                    resolution: resolution,
                    fallbackUsed: false,
                    evidenceSummary: "Mail 草稿窗口已打开，但未返回完整草稿证据。"
                )
            }

            if shouldSend {
                throw mapMailFailure(from: scriptResult.detail)
            }

            if fallbackOpener.openDraft(recipients: recipients, subject: subject, body: body) {
                return buildDraftWindowOpenedResult(
                    subject: subject,
                    body: body,
                    resolution: resolution,
                    fallbackUsed: true,
                    evidenceSummary: "Mail fallback 已打开邮件窗口，请确认收件人、标题和正文。"
                )
            }

            throw mapMailFailure(from: scriptResult.detail)
        }

        if shouldSend {
            throw MagicianError(
                code: .mailUnavailable,
                userMessage: "当前无法直接发送邮件，请先打开 Mail 并完成账号配置。",
                debugMessage: "mail app unavailable for auto send",
                recoverAction: "configure_mail_account"
            )
        }

        guard fallbackOpener.openDraft(recipients: recipients, subject: subject, body: body) else {
            throw MagicianError(
                code: .mailUnavailable,
                userMessage: "当前无法打开邮件窗口，请先打开 Mail 并完成账号配置。",
                debugMessage: "mail app unavailable and fallback opener failed",
                recoverAction: "configure_mail_account"
            )
        }

        return buildDraftWindowOpenedResult(
            subject: subject,
            body: body,
            resolution: resolution,
            fallbackUsed: true,
            evidenceSummary: "mailto 已打开邮件窗口，请确认收件人、标题和正文。"
        )
    }

    private func parsedMailScriptEvidence(from stdout: String) -> MailScriptEvidence? {
        let lines = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return nil
        }

        var fields: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                fields[key] = value
            }
        }

        guard
            let status = fields["mail_status"],
            let subject = fields["subject"]
        else {
            return nil
        }

        let recipients = fields["recipients"]?
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return MailScriptEvidence(
            status: status,
            draftID: sanitizedMailEvidenceValue(fields["draft_id"]),
            messageID: sanitizedMailEvidenceValue(fields["message_id"]),
            subject: subject,
            recipients: recipients,
            mailbox: sanitizedMailEvidenceValue(fields["mailbox"]),
            visible: fields["visible"].map { $0.lowercased() == "true" }
        )
    }

    private func sanitizedMailEvidenceValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value == "missing" ? nil : value
    }

    private func buildResult(
        subject: String,
        body: String,
        resolution: MailRecipientResolution,
        shouldSend: Bool,
        fallbackUsed: Bool,
        evidence: MailScriptEvidence
    ) -> MagicianExecutionResult {
        let historyText: String
        if shouldSend {
            let target = resolution.primaryRecipient?.address ?? "未填写收件人"
            historyText = "已发送邮件：\(summarizedHistoryText(subject)) -> \(target)"
        } else {
            historyText = "邮件待确认：\(summarizedHistoryText(subject))"
        }

        return MagicianExecutionResult(
            intent: .composeEmailDraft,
            userMessage: shouldSend ? "邮件已发出" : "邮件已填入，待你确认",
            outputText: "标题：\(subject)\n正文：\(body)\n\(evidence.evidenceSummary)",
            historyDisplayText: historyText,
            fallbackUsed: fallbackUsed,
            observation: MagicianAgentObservation(
                verificationStatus: .verified,
                targetSummary: resolution.primaryRecipient?.address,
                evidenceSummary: evidence.evidenceSummary,
                autoRepairApplied: fallbackUsed
            )
        )
    }

    private func buildDraftWindowOpenedResult(
        subject: String,
        body: String,
        resolution: MailRecipientResolution,
        fallbackUsed: Bool,
        evidenceSummary: String
    ) -> MagicianExecutionResult {
        let historyText = "邮件待确认：\(summarizedHistoryText(subject))"
        return MagicianExecutionResult(
            intent: .composeEmailDraft,
            userMessage: "邮件窗口已打开，请你确认",
            outputText: "标题：\(subject)\n正文：\(body)",
            historyDisplayText: historyText,
            fallbackUsed: fallbackUsed,
            observation: MagicianAgentObservation(
                verificationStatus: .assumed,
                targetSummary: resolution.primaryRecipient?.address,
                evidenceSummary: evidenceSummary,
                autoRepairApplied: fallbackUsed
            )
        )
    }

    private func mapMailFailure(from detail: String) -> MagicianError {
        let lowered = detail.lowercased()
        if lowered.contains("-1743") || lowered.contains("not authorized") || lowered.contains("automation") {
            return MagicianError(
                code: .mailAutomationDenied,
                userMessage: "Mail 自动化权限未开启，请在系统设置里允许 PulseType 控制 Mail。",
                debugMessage: detail,
                recoverAction: "open_automation_settings"
            )
        }
        return MagicianError(
            code: .mailAppleScriptFailed,
            userMessage: "Mail 打开失败，请稍后再试。",
            debugMessage: detail,
            recoverAction: "retry_command"
        )
    }

    private func resolvedSubject(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let selected = context.selectedText
        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = intent.params.mailSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !subject.isEmpty {
            if
                !selected.isEmpty,
                isLikelyInstructionPhrase(
                    subject,
                    command: command,
                    actionTokens: ["邮件", "草稿", "写邮件", "发邮件", "mail", "email", "主题", "subject"]
                )
            {
                return String(selected.prefix(48))
            }
            return String(subject.prefix(48))
        }
        if let payload = magicianResolvedPayload(
            selectedText: selected,
            sourceText: intent.sourceText,
            command: command,
            actionTokens: ["邮件", "草稿", "写邮件", "发邮件", "mail", "email", "主题", "subject", "发给", "发送"],
            extraCommandTokens: ["正文", "内容", "整理", "写", "写一封", "写个", "一个", "一封"],
            stripRecipientDirectives: true
        ) {
            return defaultMailSubject(from: payload)
        }
        return "邮件草稿"
    }

    private func resolvedBody(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let selected = context.selectedText
        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = intent.params.mailBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty {
            if
                !selected.isEmpty,
                isLikelyInstructionPhrase(
                    body,
                    command: command,
                    actionTokens: ["邮件", "草稿", "写邮件", "发邮件", "mail", "email"]
                )
            {
                return selected
            }
            return body
        }
        return magicianResolvedPayload(
            selectedText: selected,
            sourceText: intent.sourceText,
            command: command,
            actionTokens: ["邮件", "草稿", "写邮件", "发邮件", "mail", "email", "发给", "发送"],
            extraCommandTokens: ["主题", "正文", "内容", "整理", "写", "写一封", "写个", "一个", "一封"],
            stripRecipientDirectives: true
        ) ?? "（请补充邮件正文）"
    }

    private func defaultMailSubject(from text: String) -> String {
        String(
            text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(48)
        )
    }

    private func summarizedDraft(subject: String, body: String) async -> MailDraftSummary {
        let normalizedBody = normalizeTextForSummary(body)
        let normalizedSubject = normalizeTextForSummary(subject)
        let bodySummary = summarizeBody(normalizedBody)
        let titleSummary = summarizeTitle(preferred: normalizedSubject, fallbackBody: bodySummary)
        return MailDraftSummary(title: titleSummary, body: bodySummary)
    }

    private func summarizedDraftWithModel(
        subject: String,
        body: String
    ) async -> MailDraftSummary? {
        guard
            let providerSettingsStore,
            providerSettingsStore.isRewriteConfigurationValid,
            let apiKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            return nil
        }

        let template = buildMailSummaryPrompt(subject: subject, body: body)
        do {
            let response = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: template.systemPrompt,
                    userPrompt: template.userPrompt,
                    temperature: 0.2,
                    maxOutputTokens: 420
                ),
                configuration: providerSettingsStore.rewriteConfiguration,
                apiKey: apiKey
            )
            let payload: MailSummaryPayload = try decodeSummaryPayload(from: response.outputText)
            let normalizedTitle = normalizeTextForSummary(payload.title)
            let normalizedBody = normalizeTextForSummary(payload.body)
            guard !normalizedTitle.isEmpty, !normalizedBody.isEmpty else {
                return nil
            }
            return MailDraftSummary(
                title: String(normalizedTitle.prefix(36)),
                body: String(normalizedBody.prefix(520))
            )
        } catch {
            return nil
        }
    }

    private func buildMailSummaryPrompt(subject: String, body: String) -> RewritePromptTemplate {
        let normalizedSubject = normalizeTextForSummary(subject)
        let normalizedBody = normalizeTextForSummary(body)
        let subjectBlock = normalizedSubject.isEmpty ? "（无）" : normalizedSubject
        let bodyBlock = normalizedBody.isEmpty ? "（无）" : normalizedBody

        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a mail drafting editor for PulseType.
        Your job: convert rough input into a ready-to-review email draft with a clear title and a complete body.

        Hard requirements:
        1) Output JSON only. No markdown, no prose around JSON.
        2) JSON schema:
           {
             "title": "string",
             "body": "string"
           }
        3) Title must be concise and specific, max 36 characters in Chinese context.
        4) Body must be richer than a one-line abstract:
           - keep key facts, intent, action items, and constraints
           - use complete sentences
           - length target: 120-420 Chinese characters when source has enough detail
        5) Do not invent facts, dates, names, commitments, or metrics.
        6) Keep neutral professional tone suitable for email.
        """

        let userPrompt = """
        Existing subject draft:
        <<<SUBJECT
        \(subjectBlock)
        SUBJECT>>>

        Existing body draft:
        <<<BODY
        \(bodyBlock)
        BODY>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func decodeSummaryPayload<T: Decodable>(from output: String) throws -> T {
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
            throw NSError(domain: "PulseType.MailSummary", code: 1)
        }

        let jsonText = String(stripped[firstBrace...lastBrace])
        guard let data = jsonText.data(using: .utf8) else {
            throw NSError(domain: "PulseType.MailSummary", code: 2)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func summarizeBody(_ text: String) -> String {
        let placeholder = "（请补充邮件正文）"
        guard !text.isEmpty, text != placeholder else {
            return placeholder
        }

        let sentenceSeparators = CharacterSet(charactersIn: "。！？!?；;\n")
        let sentences = text
            .components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.isEmpty {
            return String(text.prefix(220))
        }

        var summarySentences: [String] = []
        var totalLength = 0
        for sentence in sentences {
            let trimmed = sentence.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !trimmed.isEmpty else {
                continue
            }
            let projectedLength = totalLength + trimmed.count
            if projectedLength > 220, !summarySentences.isEmpty {
                break
            }
            summarySentences.append(trimmed)
            totalLength = projectedLength
            if summarySentences.count >= 4 {
                break
            }
        }

        if summarySentences.isEmpty {
            return String(text.prefix(220))
        }
        return summarySentences.joined(separator: "\n")
    }

    private func summarizeTitle(preferred: String, fallbackBody: String) -> String {
        let candidate = preferred.isEmpty ? fallbackBody : preferred
        let compact = normalizeTextForSummary(candidate)
        guard !compact.isEmpty else {
            return "邮件草稿"
        }

        let splitters = CharacterSet(charactersIn: "\n。！？!?；;，,：:")
        let firstSegment = compact
            .components(separatedBy: splitters)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? compact
        let bounded = firstSegment.isEmpty ? compact : firstSegment
        return String(bounded.prefix(36))
    }

    private func normalizeTextForSummary(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
