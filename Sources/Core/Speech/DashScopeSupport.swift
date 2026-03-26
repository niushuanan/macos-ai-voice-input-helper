import Foundation

struct DashScopeASRPayload: Encodable {
    struct Input: Encodable {
        let messages: [Message]
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Content: Encodable {
        let text: String?
        let audio: String?

        static func text(_ value: String) -> Content {
            Content(text: value, audio: nil)
        }

        static func audio(_ value: String) -> Content {
            Content(text: nil, audio: value)
        }
    }

    struct Parameters: Encodable {
        let resultFormat: String

        struct ASROptions: Encodable {
            let enableITN: Bool

            enum CodingKeys: String, CodingKey {
                case enableITN = "enable_itn"
            }
        }

        let asrOptions: ASROptions

        enum CodingKeys: String, CodingKey {
            case resultFormat = "result_format"
            case asrOptions = "asr_options"
        }
    }

    let model: String
    let input: Input
    let parameters: Parameters
}

struct DashScopeASRResponse: Decodable {
    let output: DashScopeASROutput?
    let choices: [DashScopeASRChoice]?

    struct DashScopeASROutput: Decodable {
        let choices: [DashScopeASRChoice]?
        let text: String?
    }

    struct DashScopeASRChoice: Decodable {
        let message: DashScopeASRMessage?
        let text: String?
    }

    struct DashScopeASRMessage: Decodable {
        let content: DashScopeASRContent
    }

    enum DashScopeASRContent: Decodable {
        case string(String)
        case items([DashScopeASRContentItem])
        case empty

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
                return
            }
            if let items = try? container.decode([DashScopeASRContentItem].self) {
                self = .items(items)
                return
            }
            self = .empty
        }
    }

    struct DashScopeASRContentItem: Decodable {
        let text: String?
    }
}

struct DashScopeBusinessError: Equatable {
    let code: String?
    let message: String

    var displayMessage: String {
        if let code, !code.isEmpty {
            return "\(code)：\(message)"
        }
        return message
    }
}

enum DashScopeResponseParser {
    static func transcript(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(DashScopeASRResponse.self, from: data),
            let parsed = transcript(from: payload),
            !parsed.isEmpty
        {
            return parsed
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            return ""
        }

        let fromOutputChoices = parseChoices(
            from: (json["output"] as? [String: Any])?["choices"]
        )
        if !fromOutputChoices.isEmpty {
            return fromOutputChoices.joined(separator: "\n")
        }

        let fromTopChoices = parseChoices(from: json["choices"])
        if !fromTopChoices.isEmpty {
            return fromTopChoices.joined(separator: "\n")
        }

        if
            let output = json["output"] as? [String: Any],
            let outputText = normalizeText(output["text"])
        {
            return outputText
        }

        if let text = normalizeText(json["text"]) {
            return text
        }

        return ""
    }

    static func businessError(from data: Data) -> DashScopeBusinessError? {
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        {
            let directMessage = normalizeText(json["message"])
            let directCode = normalizeText(json["code"])

            if
                let errorObject = json["error"] as? [String: Any],
                let nestedMessage = normalizeText(errorObject["message"])
            {
                let nestedCode = normalizeText(errorObject["code"]) ?? directCode
                return DashScopeBusinessError(code: nestedCode, message: nestedMessage)
            }

            if let directMessage {
                return DashScopeBusinessError(code: directCode, message: directMessage)
            }
        }

        return nil
    }

    private static func transcript(from payload: DashScopeASRResponse) -> String? {
        let outputChoiceText = collectChoiceText(from: payload.output?.choices)
        if !outputChoiceText.isEmpty {
            return outputChoiceText.joined(separator: "\n")
        }

        let topChoiceText = collectChoiceText(from: payload.choices)
        if !topChoiceText.isEmpty {
            return topChoiceText.joined(separator: "\n")
        }

        if let outputText = payload.output?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            return outputText
        }
        return nil
    }

    private static func collectChoiceText(from choices: [DashScopeASRResponse.DashScopeASRChoice]?) -> [String] {
        guard let choices else {
            return []
        }
        return uniqueNonEmpty(
            choices.compactMap { choice in
                if let content = choice.message?.content {
                    switch content {
                    case let .string(text):
                        return text
                    case let .items(items):
                        return items.compactMap(\.text).joined(separator: "\n")
                    case .empty:
                        return choice.text
                    }
                }
                return choice.text
            }
        )
    }

    private static func parseChoices(from value: Any?) -> [String] {
        guard let choices = value as? [[String: Any]] else {
            return []
        }

        var fragments: [String] = []
        for choice in choices {
            if
                let message = choice["message"] as? [String: Any],
                let content = message["content"]
            {
                fragments.append(contentsOf: parseContent(content))
            }
            if let text = normalizeText(choice["text"]) {
                fragments.append(text)
            }
        }
        return uniqueNonEmpty(fragments)
    }

    private static func parseContent(_ value: Any) -> [String] {
        if let text = normalizeText(value) {
            return [text]
        }
        if let items = value as? [[String: Any]] {
            return uniqueNonEmpty(items.compactMap { normalizeText($0["text"]) })
        }
        if let strings = value as? [String] {
            return uniqueNonEmpty(strings)
        }
        return []
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizeText(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

enum DashScopeEndpointResolver {
    static func generationURL(baseURL: URL) -> URL {
        let normalized = baseURL.absoluteURL
        let rawPath = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rawPath.hasSuffix("api/v1/services/aigc/multimodal-generation/generation") {
            return normalized
        }

        var url = normalized
        if rawPath.hasSuffix("api/v1") {
            url.appendPathComponent("services")
            url.appendPathComponent("aigc")
            url.appendPathComponent("multimodal-generation")
            url.appendPathComponent("generation")
            return url
        }

        url.appendPathComponent("api")
        url.appendPathComponent("v1")
        url.appendPathComponent("services")
        url.appendPathComponent("aigc")
        url.appendPathComponent("multimodal-generation")
        url.appendPathComponent("generation")
        return url
    }
}
