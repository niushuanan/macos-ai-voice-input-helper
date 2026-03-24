import Foundation

enum HomeStatsFormatter {
    static func speedText(snapshot: HistoryLifetimeSnapshot) -> String {
        guard snapshot.speedSampleCount > 0 else {
            return "—"
        }
        let safe = max(0, Int(snapshot.averageCharactersPerMinute.rounded()))
        return "\(safe)"
    }
}
