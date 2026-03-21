import Foundation

enum DesktopSection: String, CaseIterable, Identifiable {
    case home
    case memory
    case skills
    case model
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .memory:
            return "记忆"
        case .skills:
            return "技能"
        case .model:
            return "模型"
        case .settings:
            return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "house"
        case .memory:
            return "clock.arrow.circlepath"
        case .skills:
            return "slider.horizontal.3"
        case .model:
            return "cpu"
        case .settings:
            return "gearshape"
        }
    }
}

enum MemoryFilterOption: String, CaseIterable, Identifiable {
    case all
    case dictation
    case selectionRewrite
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        case .failed:
            return "失败"
        }
    }
}

struct HomeStatsSnapshot: Equatable {
    var totalDurationSeconds: Double
    var totalCharacters: Int
    var charactersPerMinute: Double

    static let zero = HomeStatsSnapshot(
        totalDurationSeconds: 0,
        totalCharacters: 0,
        charactersPerMinute: 0
    )
}

@MainActor
final class ControlCenterState: ObservableObject {
    @Published var selectedSection: DesktopSection = .home
    @Published var memoryFilter: MemoryFilterOption = .all
    @Published var homeStatsSnapshot: HomeStatsSnapshot = .zero
}
