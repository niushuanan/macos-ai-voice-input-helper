import Foundation

struct V4ToolManifestIndex: Sendable {
    private let manifestsByID: [String: V4ToolManifest]
    private let orderedToolIDs: [String]

    init(manifests: [V4ToolManifest]) {
        var mapping = [String: V4ToolManifest]()
        for manifest in manifests {
            mapping[manifest.toolID] = manifest
        }
        manifestsByID = mapping
        orderedToolIDs = manifests.map(\.toolID).sorted()
    }

    func manifest(for toolID: String) -> V4ToolManifest? {
        manifestsByID[toolID]
    }

    func search(keyword: String) -> [V4ToolManifest] {
        orderedToolIDs
            .compactMap { manifestsByID[$0] }
            .filter { $0.matches(keyword: keyword) }
    }

    func list(by feature: MagicianFeatureID?) -> [V4ToolManifest] {
        orderedToolIDs
            .compactMap { manifestsByID[$0] }
            .filter { $0.requiredFeature == feature }
    }

    func all() -> [V4ToolManifest] {
        orderedToolIDs.compactMap { manifestsByID[$0] }
    }
}
