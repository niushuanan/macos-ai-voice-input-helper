import Foundation

struct SpeechProviderRegistry {
    private let providersByID: [SpeechProviderID: any SpeechTranscriptionProvider]

    init(providers: [any SpeechTranscriptionProvider]) {
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    func provider(for providerID: SpeechProviderID) -> (any SpeechTranscriptionProvider)? {
        providersByID[providerID]
    }
}
