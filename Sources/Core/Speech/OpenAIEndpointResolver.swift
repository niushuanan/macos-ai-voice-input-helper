import Foundation

enum OpenAIEndpointResolver {
    static func transcriptionURL(baseURL: URL) -> URL {
        endpointURL(
            baseURL: baseURL,
            apiPath: "audio/transcriptions"
        )
    }

    static func chatCompletionsURL(baseURL: URL) -> URL {
        endpointURL(
            baseURL: baseURL,
            apiPath: "chat/completions"
        )
    }

    private static func endpointURL(baseURL: URL, apiPath: String) -> URL {
        let normalizedBase = baseURL.absoluteURL
        let cleanedPath = normalizedBase.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hasVersionSuffix = cleanedPath
            .split(separator: "/")
            .last?
            .lowercased() == "v1"

        var url = normalizedBase
        if !hasVersionSuffix {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent(apiPath)
        return url
    }
}
