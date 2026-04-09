import Combine
import Foundation

enum DesktopSection: String, CaseIterable, Identifiable {
    case home
    case memory
    case dictionary
    case model
    case timeMachine
    case magician
    case agentBrainstorm
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .memory:
            return "历史"
        case .dictionary:
            return "词典"
        case .model:
            return "引擎"
        case .timeMachine:
            return "时光机"
        case .magician:
            return "魔术先生"
        case .agentBrainstorm:
            return "讨论整理"
        case .settings:
            return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "house"
        case .memory:
            return "clock"
        case .dictionary:
            return "text.book.closed"
        case .model:
            return "slider.horizontal.3"
        case .timeMachine:
            return "calendar.badge.clock"
        case .magician:
            return "sparkles"
        case .agentBrainstorm:
            return "bubble.left.and.bubble.right"
        case .settings:
            return "gearshape"
        }
    }
}

@MainActor
final class ControlCenterState: ObservableObject {
    @Published var selectedSection: DesktopSection = .home
    @Published var memoryFilter: LocalHistoryFilter = .all
    @Published private(set) var homeStatsSnapshot: HistoryLifetimeSnapshot = .zero

    private var cancellables = Set<AnyCancellable>()

    init(localHistoryStore: LocalHistoryStore) {
        homeStatsSnapshot = localHistoryStore.lifetimeStatistics()

        localHistoryStore.$lifetimeSnapshot
            .sink { [weak self] snapshot in
                self?.homeStatsSnapshot = snapshot
            }
            .store(in: &cancellables)
    }
}
