import Foundation

struct ContextSnapshot {
    let frontmostApplication: String
    let rewriteAvailable: Bool
    let styleHint: String
}

protocol ContextDetector {
    func currentSnapshot() -> ContextSnapshot
}

struct StubContextDetector: ContextDetector {
    func currentSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            frontmostApplication: "Unknown App",
            rewriteAvailable: true,
            styleHint: "Adaptive"
        )
    }
}
