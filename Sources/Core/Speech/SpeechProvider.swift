import Foundation

struct TranscriptionRequest {
    let lane: InputLane
    let contextSummary: String
}

struct TranscriptionResult {
    let providerName: String
    let renderedText: String
}

protocol SpeechProvider {
    var providerName: String { get }
}

struct PlaceholderSpeechProvider: SpeechProvider {
    let providerName: String = "User-supplied cloud provider key"
}
