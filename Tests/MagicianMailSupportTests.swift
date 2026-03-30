import XCTest
@testable import PulseType

@MainActor
final class MagicianMailSupportTests: XCTestCase {
    func testMailAddressBookStorePersistsAndDeduplicatesAliases() {
        let defaults = makeDefaults(suffix: "store")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("store")) }

        let store = MailAddressBookStore(defaults: defaults)
        _ = store.save(
            displayName: "小庄",
            email: "1379804870zhk@gmail.com",
            aliases: ["小庄", " 1379804870 ", "小庄"],
            note: "Gmail"
        )

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.aliases, ["小庄", "1379804870"])

        let reloaded = MailAddressBookStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.displayName, "小庄")
    }

    func testMailAddressBookPanelModelSupportsCreateSearchEditAndDelete() {
        let defaults = makeDefaults(suffix: "panel")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("panel")) }

        let store = MailAddressBookStore(defaults: defaults)
        let model = MailAddressBookPanelModel(store: store)

        model.beginCreate()
        model.displayNameDraft = "小庄"
        model.emailDraft = "1379804870zhk@gmail.com"
        model.aliasesDraft = "1379804870, 谷歌邮箱"
        model.noteDraft = "Gmail"
        XCTAssertEqual(model.saveDraft(), .created("已加入邮箱名库。"))
        XCTAssertEqual(store.entries.count, 1)

        model.searchQuery = "谷歌"
        XCTAssertEqual(model.filteredEntries.map(\.displayName), ["小庄"])

        XCTAssertNotNil(model.selectedEntry)
        model.noteDraft = "主 Gmail"
        XCTAssertEqual(model.saveDraft(), .updated("邮箱名库已更新。"))
        XCTAssertEqual(store.entries.first?.note, "主 Gmail")

        XCTAssertEqual(model.deleteSelected(), .deleted("已删除 小庄。"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testMailRecipientResolverUsesExplicitEmailBeforeAnythingElse() async {
        let defaults = makeDefaults(suffix: "resolver.explicit")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.explicit")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(outputTexts: [])
        let store = MailAddressBookStore(defaults: defaults)
        let resolver = LLMMailRecipientResolver(
            addressBookStore: store,
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给 team@example.com",
            selection: "",
            explicitRecipients: ["team@example.com"],
            recipientHints: []
        )

        XCTAssertEqual(
            resolution.recipients,
            [
                ResolvedMailRecipient(
                    address: "team@example.com",
                    source: .explicit,
                    confidence: 1.0,
                    matchedHint: "team@example.com"
                )
            ]
        )
        XCTAssertTrue(resolution.unresolvedHints.isEmpty)
        XCTAssertEqual(generationProvider.callCount, 0)
    }

    func testMailRecipientResolverDeduplicatesExplicitEmailAndKeepsSinglePrimary() async {
        let defaults = makeDefaults(suffix: "resolver.single-primary")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.single-primary")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(outputTexts: [])
        let store = MailAddressBookStore(defaults: defaults)
        let resolver = LLMMailRecipientResolver(
            addressBookStore: store,
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给 team@example.com",
            selection: "",
            explicitRecipients: ["team@example.com"],
            recipientHints: ["team@example.com"]
        )

        XCTAssertEqual(resolution.primaryRecipient?.address, "team@example.com")
        XCTAssertTrue(resolution.alternateRecipients.isEmpty)
        XCTAssertFalse(resolution.isAmbiguous)
        XCTAssertEqual(generationProvider.callCount, 0)
    }

    func testMailRecipientResolverMatchesAddressBookBeforeLLM() async {
        let defaults = makeDefaults(suffix: "resolver.addressbook")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.addressbook")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(outputTexts: [])
        let store = MailAddressBookStore(defaults: defaults)
        _ = store.save(
            displayName: "小庄",
            email: "1379804870zhk@gmail.com",
            aliases: ["1379804870", "谷歌邮箱"],
            note: ""
        )
        let resolver = LLMMailRecipientResolver(
            addressBookStore: store,
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给小庄",
            selection: "",
            explicitRecipients: [],
            recipientHints: ["小庄"]
        )

        XCTAssertEqual(resolution.recipients.first?.address, "1379804870zhk@gmail.com")
        XCTAssertEqual(resolution.recipients.first?.source, .addressBook)
        XCTAssertEqual(resolution.recipients.first?.confidence, 1.0)
        XCTAssertTrue(resolution.unresolvedHints.isEmpty)
        XCTAssertEqual(generationProvider.callCount, 0)
    }

    func testMailRecipientResolverAllowsLLMToInferNewAddress() async {
        let defaults = makeDefaults(suffix: "resolver.llm")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.llm")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(
            outputTexts: [
                #"{"recipients":[{"address":"1379804870zhk@gmail.com","matchedHint":"1379804870 的谷歌邮箱","confidence":0.82}]}"#
            ]
        )
        let store = MailAddressBookStore(defaults: defaults)
        let resolver = LLMMailRecipientResolver(
            addressBookStore: store,
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给 1379804870 的谷歌邮箱",
            selection: "",
            explicitRecipients: [],
            recipientHints: ["1379804870 的谷歌邮箱"]
        )

        XCTAssertEqual(resolution.recipients.count, 1)
        XCTAssertEqual(resolution.recipients.first?.address, "1379804870zhk@gmail.com")
        XCTAssertEqual(resolution.recipients.first?.source, .llm)
        XCTAssertEqual(resolution.unresolvedHints, [])
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testMailRecipientResolverBlocksAutoSendWhenConfidenceTooLow() async {
        let defaults = makeDefaults(suffix: "resolver.threshold")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.threshold")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(
            outputTexts: [
                #"{"recipients":[{"address":"guess@example.com","matchedHint":"小庄","confidence":0.62}]}"#
            ]
        )
        let store = MailAddressBookStore(defaults: defaults)
        let resolver = LLMMailRecipientResolver(
            addressBookStore: store,
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给小庄",
            selection: "",
            explicitRecipients: [],
            recipientHints: ["小庄"]
        )

        XCTAssertFalse(
            resolver.shouldAutoSend(
                deliveryMode: .autoSendIfResolved,
                resolution: resolution
            )
        )
    }

    func testMailRecipientResolverMarksAmbiguousCandidatesAndBlocksAutoSend() async {
        let defaults = makeDefaults(suffix: "resolver.ambiguous")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("resolver.ambiguous")) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForMailTests(storage: ["text.primary": "sk-test"])
        )
        let generationProvider = TrackingTextGenerationProviderForMailTests(
            outputTexts: [
                #"{"recipients":[{"address":"xiaozhuang@example.com","matchedHint":"小庄","confidence":0.78},{"address":"xiaowang@example.com","matchedHint":"小王","confidence":0.74}]}"#
            ]
        )
        let resolver = LLMMailRecipientResolver(
            addressBookStore: MailAddressBookStore(defaults: defaults),
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let resolution = await resolver.resolve(
            command: "发给小庄和小王",
            selection: "",
            explicitRecipients: [],
            recipientHints: ["小庄", "小王"]
        )

        XCTAssertNil(resolution.primaryRecipient)
        XCTAssertEqual(resolution.alternateRecipients.count, 2)
        XCTAssertTrue(resolution.isAmbiguous)
        XCTAssertFalse(
            resolver.shouldAutoSend(
                deliveryMode: .autoSendIfResolved,
                resolution: resolution
            )
        )
    }

    func testMailAdapterAutoSendUsesAppleScriptSendPath() async throws {
        let addressBookStore = MailAddressBookStore(defaults: makeDefaults(suffix: "adapter.send"))
        _ = addressBookStore.save(
            displayName: "小庄",
            email: "1379804870zhk@gmail.com",
            aliases: ["小庄"],
            note: ""
        )
        let resolver = StubMailRecipientResolver(
            resolution: MailRecipientResolution(
                recipients: [
                    ResolvedMailRecipient(
                        address: "1379804870zhk@gmail.com",
                        source: .addressBook,
                        confidence: 1.0,
                        matchedHint: "小庄"
                    )
                ],
                unresolvedHints: []
            ),
            shouldAutoSend: true
        )
        let appleScripter = RecordingMailAppleScripter(
            result: MagicianProcessResult(
                exitCode: 0,
                stdout: "mail_status=sent\nmessage_id=<fake-message-id>\nsubject=路线图同步\nrecipients=1379804870zhk@gmail.com\nmailbox=sent",
                stderr: ""
            )
        )
        let fallbackOpener = RecordingMailFallbackOpener(result: false)

        let adapter = MagicianMailAdapter(
            addressBookStore: addressBookStore,
            recipientResolver: resolver,
            appleScripter: appleScripter,
            fallbackOpener: fallbackOpener,
            mailCapabilityProvider: {
                MagicianMailCapabilitySnapshot(
                    composeEmailServiceAvailable: true,
                    mailtoAvailable: true,
                    mailAppAvailable: true
                )
            }
        )

        let result = try await adapter.execute(
            intent: MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 0.9,
                sourceText: "路线图同步",
                params: MagicianIntentParams(
                    mailRecipientHints: ["小庄"],
                    mailDeliveryMode: .autoSendIfResolved,
                    mailSubject: "路线图同步",
                    mailBody: "小庄你好，这是路线图同步邮件。"
                )
            ),
            context: MagicianExecutionContext(
                command: "发给小庄",
                selection: nil,
                focusContext: testFocusContext()
            )
        )

        XCTAssertEqual(result.userMessage, "邮件已发出")
        XCTAssertEqual(appleScripter.lastShouldSend, true)
        XCTAssertEqual(appleScripter.lastRecipients, ["1379804870zhk@gmail.com"])
        XCTAssertEqual(fallbackOpener.callCount, 0)
        XCTAssertNotNil(addressBookStore.entries.first?.lastUsedAt)
    }

    func testMailAdapterLeavesMailOpenWhenRecipientNotFullyResolved() async throws {
        let resolver = StubMailRecipientResolver(
            resolution: MailRecipientResolution(
                recipients: [],
                unresolvedHints: ["小庄"]
            ),
            shouldAutoSend: false
        )
        let appleScripter = RecordingMailAppleScripter(
            result: MagicianProcessResult(
                exitCode: 0,
                stdout: "mail_status=draft\ndraft_id=42\nsubject=活动通知\nrecipients=\nvisible=true",
                stderr: ""
            )
        )

        let adapter = MagicianMailAdapter(
            addressBookStore: MailAddressBookStore(defaults: makeDefaults(suffix: "adapter.draft")),
            recipientResolver: resolver,
            appleScripter: appleScripter,
            fallbackOpener: RecordingMailFallbackOpener(result: false),
            mailCapabilityProvider: {
                MagicianMailCapabilitySnapshot(
                    composeEmailServiceAvailable: true,
                    mailtoAvailable: true,
                    mailAppAvailable: true
                )
            }
        )

        let result = try await adapter.execute(
            intent: MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 0.82,
                sourceText: "活动通知",
                params: MagicianIntentParams(
                    mailRecipientHints: ["小庄"],
                    mailDeliveryMode: .autoSendIfResolved,
                    mailSubject: "活动通知",
                    mailBody: "大家好，这是活动通知。"
                )
            ),
            context: MagicianExecutionContext(
                command: "发给小庄",
                selection: nil,
                focusContext: testFocusContext()
            )
        )

        XCTAssertEqual(result.userMessage, "邮箱目标不够明确，已打开草稿窗")
        XCTAssertEqual(appleScripter.lastShouldSend, false)
    }

    func testMailAdapterSummarizesDraftSubjectAndBodyBeforeOutput() async throws {
        let resolver = StubMailRecipientResolver(
            resolution: MailRecipientResolution(
                recipients: [],
                unresolvedHints: ["产品组"]
            ),
            shouldAutoSend: false
        )
        let appleScripter = RecordingMailAppleScripter(
            result: MagicianProcessResult(
                exitCode: 0,
                stdout: "mail_status=draft\ndraft_id=108\nsubject=周会纪要和风险同步\nrecipients=\nvisible=true",
                stderr: ""
            )
        )

        let adapter = MagicianMailAdapter(
            addressBookStore: MailAddressBookStore(defaults: makeDefaults(suffix: "adapter.summary")),
            recipientResolver: resolver,
            appleScripter: appleScripter,
            fallbackOpener: RecordingMailFallbackOpener(result: false),
            mailCapabilityProvider: {
                MagicianMailCapabilitySnapshot(
                    composeEmailServiceAvailable: true,
                    mailtoAvailable: true,
                    mailAppAvailable: true
                )
            }
        )

        let result = try await adapter.execute(
            intent: MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 0.91,
                sourceText: "",
                params: MagicianIntentParams(
                    mailRecipientHints: ["产品组"],
                    mailDeliveryMode: .draftOnly,
                    mailSubject: "周会纪要和风险同步",
                    mailBody: "今天和研发、设计、测试做了周会，确认版本计划。第一，语音链路已稳定。第二，联系人编辑面板存在超出显示区域的问题。第三，需要本周内完成 UI 调整并回归验证。"
                )
            ),
            context: MagicianExecutionContext(
                command: "给产品组写一封周会同步邮件",
                selection: nil,
                focusContext: testFocusContext()
            )
        )

        XCTAssertNotNil(appleScripter.lastSubject)
        XCTAssertNotNil(appleScripter.lastBody)
        XCTAssertLessThanOrEqual(appleScripter.lastSubject?.count ?? 0, 36)
        XCTAssertTrue((appleScripter.lastBody ?? "").contains("\n"))
        XCTAssertTrue((result.outputText ?? "").contains("标题："))
        XCTAssertTrue((result.outputText ?? "").contains("正文："))
    }

    func testMailAdapterReportsAutomationDeniedClearly() async {
        let resolver = StubMailRecipientResolver(
            resolution: MailRecipientResolution(
                recipients: [
                    ResolvedMailRecipient(
                        address: "team@example.com",
                        source: .explicit,
                        confidence: 1.0,
                        matchedHint: "team@example.com"
                    )
                ],
                unresolvedHints: []
            ),
            shouldAutoSend: true
        )
        let appleScripter = RecordingMailAppleScripter(
            result: MagicianProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "Not authorized to send Apple events to Mail (-1743)"
            )
        )

        let adapter = MagicianMailAdapter(
            addressBookStore: MailAddressBookStore(defaults: makeDefaults(suffix: "adapter.denied")),
            recipientResolver: resolver,
            appleScripter: appleScripter,
            fallbackOpener: RecordingMailFallbackOpener(result: false),
            mailCapabilityProvider: {
                MagicianMailCapabilitySnapshot(
                    composeEmailServiceAvailable: false,
                    mailtoAvailable: false,
                    mailAppAvailable: true
                )
            }
        )

        do {
            _ = try await adapter.execute(
                intent: MagicianIntent(
                    intent: .composeEmailDraft,
                    confidence: 0.9,
                    sourceText: "",
                    params: MagicianIntentParams(
                        mailTo: ["team@example.com"],
                        mailDeliveryMode: .autoSendIfResolved,
                        mailSubject: "主题",
                        mailBody: "正文"
                    )
                ),
                context: MagicianExecutionContext(
                    command: "发给 team@example.com",
                    selection: nil,
                    focusContext: testFocusContext()
                )
            )
            XCTFail("Expected automation denied")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .mailAutomationDenied)
            XCTAssertTrue(error.userMessage.contains("自动化权限"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName(suffix)) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName(suffix))
        return defaults
    }

    private func defaultsSuiteName(_ suffix: String) -> String {
        "MagicianMailSupportTests.\(name).\(suffix)"
    }

    private func testFocusContext() -> FocusedAppContext {
        FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea",
            hasEditableTarget: true,
            strategyHint: "ax-direct"
        )
    }
}

private final class MemoryCredentialStoreForMailTests: ProviderCredentialStore {
    private var storage: [String: String]

    init(storage: [String: String]) {
        self.storage = storage
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        _ = allowUserInteraction
        return storage[profileID]?.isEmpty == false
    }
}

private final class TrackingTextGenerationProviderForMailTests: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]
    private(set) var callCount = 0
    private let outputTexts: [String]

    init(outputTexts: [String]) {
        self.outputTexts = outputTexts
    }

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        _ = request
        _ = configuration
        _ = apiKey
        callCount += 1
        let output = outputTexts.isEmpty
            ? #"{"recipients":[]}"#
            : outputTexts[min(callCount - 1, outputTexts.count - 1)]
        return TextGenerationResult(
            providerType: .openAI,
            providerName: "Fake OpenAI",
            modelName: "fake-model",
            outputText: output
        )
    }
}

@MainActor
private final class StubMailRecipientResolver: MagicianMailRecipientResolving {
    let resolution: MailRecipientResolution
    let shouldAutoSend: Bool

    init(resolution: MailRecipientResolution, shouldAutoSend: Bool) {
        self.resolution = resolution
        self.shouldAutoSend = shouldAutoSend
    }

    func resolve(
        command: String,
        selection: String,
        explicitRecipients: [String],
        recipientHints: [String]
    ) async -> MailRecipientResolution {
        _ = command
        _ = selection
        _ = explicitRecipients
        _ = recipientHints
        return resolution
    }

    func shouldAutoSend(
        deliveryMode: MagicianMailDeliveryMode?,
        resolution: MailRecipientResolution
    ) -> Bool {
        _ = deliveryMode
        _ = resolution
        return shouldAutoSend
    }
}

private final class RecordingMailAppleScripter: MagicianMailAppleScripting {
    private let result: MagicianProcessResult
    private(set) var lastRecipients: [String] = []
    private(set) var lastShouldSend: Bool?
    private(set) var lastSubject: String?
    private(set) var lastBody: String?

    init(result: MagicianProcessResult) {
        self.result = result
    }

    func openMessage(
        recipients: [String],
        subject: String,
        body: String,
        shouldSend: Bool
    ) async -> MagicianProcessResult {
        lastSubject = subject
        lastBody = body
        lastRecipients = recipients
        lastShouldSend = shouldSend
        return result
    }
}

private final class RecordingMailFallbackOpener: MagicianMailDraftFallbackOpening {
    private let result: Bool
    private(set) var callCount = 0

    init(result: Bool) {
        self.result = result
    }

    func openDraft(
        recipients: [String],
        subject: String,
        body: String
    ) -> Bool {
        _ = recipients
        _ = subject
        _ = body
        callCount += 1
        return result
    }
}
