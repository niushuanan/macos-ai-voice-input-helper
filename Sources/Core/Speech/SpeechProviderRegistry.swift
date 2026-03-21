import Foundation

struct SpeechProviderRegistry {
    private let providersByType: [ProviderType: any SpeechTranscriptionProvider]

    init(providers: [any SpeechTranscriptionProvider]) {
        var map: [ProviderType: any SpeechTranscriptionProvider] = [:]
        for provider in providers {
            for type in provider.supportedProviderTypes {
                map[type] = provider
            }
        }
        providersByType = map
    }

    func provider(for providerType: ProviderType) -> (any SpeechTranscriptionProvider)? {
        providersByType[providerType]
    }
}
