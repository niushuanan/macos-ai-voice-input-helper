import Foundation

struct V4MailComposeTool: V4Tool {
    struct Request: Equatable, Sendable {
        let command: String
        let subject: String?
        let body: String?
        let recipients: [String]
        let recipientHints: [String]
        let deliveryMode: MagicianMailDeliveryMode
        let selectionText: String?
    }

    struct Response: Equatable, Sendable {
        let userMessage: String
        let outputText: String?
        let historyDisplayText: String?
        let evidenceSummary: String?
        let verificationStatus: MagicianAgentVerificationStatus
        let targetSummary: String?
        let autoRepairApplied: Bool
        let rawFields: [String: String]
    }

    typealias ExecuteHandler = @Sendable (Request) async throws -> Response

    let spec = V4ToolSpec(
        toolName: "apple.mail.compose",
        displayName: "整理邮件",
        summary: "整理主题与正文，必要时直接发邮件，并返回结构化 Mail 证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始命令"),
                V4ToolInputField(name: "subject", kind: .string, isRequired: false, summary: "邮件主题"),
                V4ToolInputField(name: "body", kind: .string, isRequired: false, summary: "邮件正文"),
                V4ToolInputField(name: "recipients", kind: .array, isRequired: false, itemKind: .string, summary: "明确收件人"),
                V4ToolInputField(name: "recipientHints", kind: .array, isRequired: false, itemKind: .string, summary: "收件人提示"),
                V4ToolInputField(name: "deliveryMode", kind: .string, isRequired: false, summary: "draft_only 或 auto_send_if_resolved")
            ]
        ),
        requiresPermission: true,
        permissionScope: .appleNativeApps,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let executeHandler: ExecuteHandler
    private let errorCatalog = V4ToolErrorCatalog()

    init(
        addressBookStore: MailAddressBookStore? = nil,
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: (any TextGenerationProvider)? = nil,
        executeHandler: ExecuteHandler? = nil
    ) {
        if let executeHandler {
            self.executeHandler = executeHandler
        } else {
            self.executeHandler = Self.liveExecuteHandler(
                addressBookStore: addressBookStore,
                providerSettingsStore: providerSettingsStore,
                generationProvider: generationProvider ?? OpenAITextGenerationProvider()
            )
        }
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if command.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "mail command empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let request = Request(
            command: arguments.string(for: "command") ?? context.request.inputText,
            subject: arguments.string(for: "subject")?.trimmedNilIfEmpty,
            body: arguments.string(for: "body")?.trimmedNilIfEmpty,
            recipients: arguments.stringArray(for: "recipients") ?? [],
            recipientHints: arguments.stringArray(for: "recipientHints") ?? [],
            deliveryMode: deliveryMode(from: arguments),
            selectionText: context.request.selectionText
        )

        let response = try await executeHandler(request)
        let rawPayload = payload(from: request, response: response)
        return V4ToolExecutionOutput(
            outputText: response.outputText ?? response.userMessage,
            evidenceSummary: response.evidenceSummary ?? "",
            rawPayload: rawPayload
        )
    }

    private func deliveryMode(from arguments: V4ToolArguments) -> MagicianMailDeliveryMode {
        guard let rawValue = arguments.string(for: "deliveryMode")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = MagicianMailDeliveryMode(rawValue: rawValue)
        else {
            return .draftOnly
        }
        return mode
    }

    private func payload(
        from request: Request,
        response: Response
    ) -> V4ToolValue {
        var object: [String: V4ToolValue] = [
            "userMessage": .string(response.userMessage),
            "outputText": .string(response.outputText ?? ""),
            "historyDisplayText": .string(response.historyDisplayText ?? ""),
            "verificationStatus": .string(response.verificationStatus.rawValue),
            "autoRepairApplied": .boolean(response.autoRepairApplied),
            "subject": .string(request.subject ?? ""),
            "bodyPreview": .string(String((request.body ?? "").prefix(120))),
            "targetSummary": .string(response.targetSummary ?? "")
        ]

        let normalizedFields = response.rawFields
        object["mailStatus"] = normalizedFields["mail_status"].map(V4ToolValue.string) ?? .string("")
        if let draftID = normalizedFields["draft_id"] {
            object["draftID"] = .string(draftID)
        }
        if let messageID = normalizedFields["message_id"] {
            object["messageID"] = .string(messageID)
        }
        if let mailbox = normalizedFields["mailbox"] {
            object["mailbox"] = .string(mailbox)
        }
        if let recipients = normalizedFields["recipients"] {
            object["recipients"] = .array(
                recipients
                    .split(separator: "|")
                    .map { .string(String($0)) }
            )
        } else if !request.recipients.isEmpty {
            object["recipients"] = .array(request.recipients.map(V4ToolValue.string))
        }

        return .object(object)
    }

    private static func liveExecuteHandler(
        addressBookStore: MailAddressBookStore?,
        providerSettingsStore: ProviderSettingsStore?,
        generationProvider: any TextGenerationProvider
    ) -> ExecuteHandler {
        { request in
            let adapter = await MainActor.run {
                MagicianMailAdapter(
                    addressBookStore: addressBookStore,
                    providerSettingsStore: providerSettingsStore,
                    generationProvider: generationProvider
                )
            }
            let intent = MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 1,
                sourceText: request.body ?? request.command,
                params: MagicianIntentParams(
                    mailTo: request.recipients.isEmpty ? nil : request.recipients,
                    mailRecipientHints: request.recipientHints.isEmpty ? nil : request.recipientHints,
                    mailDeliveryMode: request.deliveryMode,
                    mailSubject: request.subject,
                    mailBody: request.body
                )
            )
            let context = MagicianExecutionContext(
                command: request.command,
                selection: request.selectionText.map {
                    FocusedSelectionSnapshot(
                        focusContext: FocusedAppContext(
                            appName: "PulseType",
                            bundleID: "app.pulsetype",
                            focusedRole: nil,
                            hasEditableTarget: true,
                            strategyHint: "v4_tool_kernel"
                        ),
                        selectedText: $0
                    )
                },
                focusContext: FocusedAppContext(
                    appName: "PulseType",
                    bundleID: "app.pulsetype",
                    focusedRole: nil,
                    hasEditableTarget: true,
                    strategyHint: "v4_tool_kernel"
                )
            )
            let result = try await adapter.execute(intent: intent, context: context)
            let evidenceSummary = result.observation?.evidenceSummary

            return Response(
                userMessage: result.userMessage,
                outputText: result.outputText,
                historyDisplayText: result.historyDisplayText,
                evidenceSummary: evidenceSummary,
                verificationStatus: result.observation?.verificationStatus ?? .assumed,
                targetSummary: result.observation?.targetSummary,
                autoRepairApplied: result.observation?.autoRepairApplied ?? result.fallbackUsed,
                rawFields: parseEvidenceFields(from: evidenceSummary)
            )
        }
    }

    private static func parseEvidenceFields(from evidenceSummary: String?) -> [String: String] {
        guard let evidenceSummary else {
            return [:]
        }
        let normalized = evidenceSummary
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var fields: [String: String] = [:]
        for item in normalized {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            fields[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
