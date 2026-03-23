import Combine
import Foundation

enum DesktopSection: String, CaseIterable, Identifiable {
    case home
    case memory
    case skills
    case dictionary
    case model
    case settings
    case agentBrainstorm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .memory:
            return "记忆"
        case .skills:
            return "Skill"
        case .agentBrainstorm:
            return "Agent-头脑风暴（Beta）"
        case .dictionary:
            return "词典"
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
        case .agentBrainstorm:
            return "person.2.wave.2"
        case .dictionary:
            return "text.book.closed"
        case .model:
            return "cpu"
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
