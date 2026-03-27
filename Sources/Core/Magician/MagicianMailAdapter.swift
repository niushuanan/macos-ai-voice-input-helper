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
                "tell application \"Mail\"",
                "if not running then launch",
                "activate",
                "set draftMessage to make new outgoing message with properties {visible:true, subject:mailSubject, content:mailBody & return & return}",
                "tell draftMessage",
                "repeat with addr in recipientList",
                "make new to recipient at end of to recipients with properties {address:(contents of addr)}",
                "end repeat",
                "end tell",
                "if shouldSendNow then",
                "send draftMessage",
                "end if",
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
struct MagicianMailAdapter: MagicianMailExecuting {
    private let addressBookStore: MailAddressBookStore
    private let recipientResolver: any MagicianMailRecipientResolving
    private let appleScripter: any MagicianMailAppleScripting
    private let fallbackOpener: any MagicianMailDraftFallbackOpening
    private let mailCapabilityProvider: () -> MagicianMailCapabilitySnapshot

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
                if let primaryRecipient = resolution.primaryRecipient?.address {
                    addressBookStore.markUsed(addresses: [primaryRecipient])
                }
                return buildResult(
                    subject: subject,
                    body: body,
                    resolution: resolution,
                    deliveryMode: intent.params.mailDeliveryMode,
                    shouldSend: shouldSend,
                    fallbackUsed: false
                )
            }

            if shouldSend {
                throw mapMailFailure(from: scriptResult.detail)
            }

            if fallbackOpener.openDraft(recipients: recipients, subject: subject, body: body) {
                return buildResult(
                    subject: subject,
                    body: body,
                    resolution: resolution,
                    deliveryMode: intent.params.mailDeliveryMode,
                    shouldSend: false,
                    fallbackUsed: true
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

        return buildResult(
            subject: subject,
            body: body,
            resolution: resolution,
            deliveryMode: intent.params.mailDeliveryMode,
            shouldSend: false,
            fallbackUsed: true
        )
    }

    private func buildResult(
        subject: String,
        body: String,
        resolution: MailRecipientResolution,
        deliveryMode: MagicianMailDeliveryMode?,
        shouldSend: Bool,
        fallbackUsed: Bool
    ) -> MagicianExecutionResult {
        let historyText: String
        let message: String
        if shouldSend {
            let target = resolution.primaryRecipient?.address ?? "未填写收件人"
            historyText = "已发送邮件：\(summarizedHistoryText(subject)) -> \(target)"
            message = "邮件已发出"
        } else {
            historyText = "邮件待确认：\(summarizedHistoryText(subject))"
            if
                deliveryMode == .autoSendIfResolved,
                resolution.primaryRecipient == nil
                    || resolution.isAmbiguous
                    || !resolution.unresolvedHints.isEmpty
            {
                message = "邮箱目标不够明确，已打开草稿窗"
            } else {
                message = "邮件已起草，待你确认"
            }
        }

        return MagicianExecutionResult(
            intent: .composeEmailDraft,
            userMessage: message,
            outputText: body,
            historyDisplayText: historyText,
            fallbackUsed: fallbackUsed
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
}
