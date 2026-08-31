import Foundation

struct TranscriptLedger: Sendable {
    private struct Item: Sendable {
        let id: String
        var confirmedText: String
        var tentativeText: String
        var completedText: String?

        var previewText: String {
            TranscriptTextComposer.join(confirmedText, tentativeText)
        }
    }

    private var orderedIDs: [String] = []
    private var itemsByID: [String: Item] = [:]

    var snapshot: TranscriptSnapshot {
        let committedSegments = orderedIDs.compactMap { id -> String? in
            guard let text = itemsByID[id]?.completedText else {
                return nil
            }
            return text
        }
        let tentativeSegments = orderedIDs.compactMap { id -> String? in
            guard
                let item = itemsByID[id],
                item.completedText == nil,
                !item.previewText.isEmpty
            else {
                return nil
            }
            return item.previewText
        }

        return TranscriptSnapshot(
            committedText: compose(committedSegments),
            tentativeText: compose(tentativeSegments)
        )
    }

    init() {}

    mutating func apply(_ event: StreamingTranscriptEvent) {
        switch event {
        case .sessionReady, .speechStarted, .sessionFinished:
            return

        case let .delta(itemID, confirmedText, tentativeText):
            let normalizedID = normalizedItemID(itemID)
            guard !normalizedID.isEmpty else {
                return
            }
            ensureItem(id: normalizedID)
            guard itemsByID[normalizedID]?.completedText == nil else {
                return
            }
            itemsByID[normalizedID]?.confirmedText = confirmedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            itemsByID[normalizedID]?.tentativeText = tentativeText
                .trimmingCharacters(in: .whitespacesAndNewlines)

        case let .completed(itemID, transcript):
            let normalizedID = normalizedItemID(itemID)
            guard !normalizedID.isEmpty else {
                return
            }
            ensureItem(id: normalizedID)
            let normalizedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedText.isEmpty {
                itemsByID[normalizedID]?.completedText = normalizedText
            } else if let previewText = itemsByID[normalizedID]?.previewText, !previewText.isEmpty {
                itemsByID[normalizedID]?.completedText = previewText
            }
        }
    }

    private mutating func ensureItem(id: String) {
        guard itemsByID[id] == nil else {
            return
        }
        orderedIDs.append(id)
        itemsByID[id] = Item(
            id: id,
            confirmedText: "",
            tentativeText: "",
            completedText: nil
        )
    }

    private func normalizedItemID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compose(_ segments: [String]) -> String {
        segments.reduce(into: "") { result, segment in
            result = TranscriptTextComposer.join(result, segment)
        }
    }
}
