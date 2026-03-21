import AppKit
import Foundation

@main
struct WritebackProbeRunner {
    static func main() async {
        let detector = AccessibilityContextDetector()
        let focus = detector.focusedAppContext()
        print("focus.app=\(focus.appName)")
        print("focus.bundle=\(focus.bundleID)")
        print("focus.editable=\(focus.hasEditableTarget)")
        print("focus.role=\(focus.focusedRole ?? "nil")")
        print("focus.hint=\(focus.strategyHint)")

        let logger = TextOutputLogger(
            diagnosticsDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )

        let coordinator = AccessibilityTextOutputCoordinator(logger: logger)
        let payload = CommandLine.arguments.dropFirst().joined(separator: " ")
        let text = payload.isEmpty
            ? "[PulseType probe] writeback \(ISO8601DateFormatter().string(from: Date()))"
            : payload

        do {
            let result = try await coordinator.write(
                request: TextOutputRequest(
                    text: text,
                    operation: .insertText,
                    focusContext: focus
                )
            )
            print("writeback.success=true")
            print("writeback.path=\(result.path.rawValue)")
            print("writeback.fallback=\(result.usedFallback)")
        } catch {
            print("writeback.success=false")
            print("writeback.error=\(error.localizedDescription)")
        }
    }
}
