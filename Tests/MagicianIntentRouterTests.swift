import XCTest
@testable import PulseType

@MainActor
final class MagicianIntentRouterTests: XCTestCase {
    func testHeuristicRouterRejectsRemovedSearchIntent() async {
        let router = HeuristicMagicianIntentRouter()

        do {
            _ = try await router.route(
                command: "帮我搜索一下",
                selection: "OpenAI o3",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected removed feature error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("快速搜索已下线"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHeuristicRouterRejectsTextTransformWhenSelectionMissing() async {
        let router = HeuristicMagicianIntentRouter()

        do {
            _ = try await router.route(
                command: "帮我润色一下",
                selection: nil,
                enabledFeatures: [.textTransform]
            )
            XCTFail("Expected selectionEmpty error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .selectionEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSchemaValidatorRejectsDisabledIntent() {
        let validator = MagicianIntentSchemaValidator()
        let intent = MagicianIntent(
            intent: .createEvent,
            confidence: 0.9,
            sourceText: "周五下午开会",
            params: .empty
        )

        XCTAssertThrowsError(
            try validator.validate(intent, enabledFeatures: [.createNote])
        ) { error in
            let magicianError = error as? MagicianError
            XCTAssertEqual(magicianError?.code, .intentParseFailed)
        }
    }

    func testLLMRouterFailsWhenRewriteConfigurationInvalid() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )
        providerStore.updateTextModel("")

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "OpenAI",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("文本模型"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterRejectsRemovedSearchIntentBeforeCallingModel() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "帮我搜索一下",
                selection: "OpenAI 最新发布",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected removed feature error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("快速搜索已下线"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterFailsWhenRewriteAPIKeyMissing() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: [:])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "会议纪要",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("API"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterParsesJSONFromCodeFence() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            ```json
            {"intent":"create_note","confidence":0.91,"sourceText":"记录这段内容","params":{"noteBody":"记录这段内容"}}
            ```
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "记到备忘录",
            selection: "记录这段内容",
            enabledFeatures: [.createNote]
        )

        XCTAssertEqual(intent.intent, .createNote)
        XCTAssertEqual(intent.params.noteBody, "记录这段内容")
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testLLMRouterNormalizesInstructionPhraseToSelectionForCreateNote() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.83,"sourceText":"帮我写进备忘录","params":{"noteBody":"帮我写进备忘录"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "帮我写进备忘录",
            selection: "周五 15:00 在 A 会议室评审 PRD",
            enabledFeatures: [.createNote]
        )

        XCTAssertEqual(intent.intent, .createNote)
        XCTAssertEqual(intent.sourceText, "周五 15:00 在 A 会议室评审 PRD")
        XCTAssertEqual(intent.params.noteBody, "周五 15:00 在 A 会议室评审 PRD")
    }

    func testLLMRouterNormalizesInstructionPhraseToSelectionForCreateEvent() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_event","confidence":0.82,"sourceText":"帮我建立日程","params":{"title":"帮我建立日程"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let selectionText = "4月1日 14:30 在上海办公室和产品团队开路标会"
        let intent = try await router.route(
            command: "帮我建立日程",
            selection: selectionText,
            enabledFeatures: [.createEvent]
        )

        XCTAssertEqual(intent.intent, .createEvent)
        XCTAssertEqual(intent.sourceText, selectionText)
        XCTAssertEqual(intent.params.title, String(selectionText.prefix(60)))
    }

    func testLLMRouterUsesSelectionForMailBodyAndKeepsRecipientsFromCommand() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"compose_email_draft","confidence":0.9,"sourceText":"发邮件给 team@example.com","params":{"mailTo":["team@example.com"],"mailSubject":"发邮件给 team@example.com","mailBody":"发邮件给 team@example.com"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let selection = "大家好，明天下午三点我们在 A 会议室过一遍路线图。"
        let intent = try await router.route(
            command: "发邮件给 team@example.com",
            selection: selection,
            enabledFeatures: [.composeEmailDraft]
        )

        XCTAssertEqual(intent.intent, .composeEmailDraft)
        XCTAssertEqual(intent.sourceText, selection)
        XCTAssertEqual(intent.params.mailBody, selection)
        XCTAssertEqual(intent.params.mailTo, ["team@example.com"])
        XCTAssertEqual(intent.params.mailSubject, String(selection.prefix(24)))
    }

    func testSchemaValidatorAllowsCommandFallbackWithoutSelection() throws {
        let validator = MagicianIntentSchemaValidator()
        let validated = try validator.validate(
            MagicianIntent(
                intent: .createNote,
                confidence: 0.81,
                sourceText: "",
                params: .empty
            ),
            enabledFeatures: [.createNote],
            command: "记一下周五下午和产品开会",
            selection: nil
        )

        XCTAssertEqual(validated.sourceText, "")
        XCTAssertEqual(validated.params.noteBody, "记一下周五下午和产品开会")
    }

    func testLLMRouterRejectsInvalidJSONWithoutHeuristicFallback() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: "这不是合法 JSON"
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "OpenAI o3",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertEqual(generationProvider.callCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var defaultsSuiteName: String {
        "MagicianIntentRouterTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private final class MemoryCredentialStore: ProviderCredentialStore {
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
        storage[profileID]?.isEmpty == false
    }
}

private final class TrackingTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]
    private(set) var callCount: Int = 0
    private let outputText: String

    init(outputText: String) {
        self.outputText = outputText
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
        return TextGenerationResult(
            providerType: .openAI,
            providerName: "Fake OpenAI",
            modelName: "fake-model",
            outputText: outputText
        )
    }
}
