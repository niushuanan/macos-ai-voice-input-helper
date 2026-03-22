import Combine
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
            return "Skill"
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

@MainActor
final class ControlCenterState: ObservableObject {
    @Published var selectedSection: DesktopSection = .home
    @Published var memoryFilter: LocalHistoryFilter = .all
    @Published private(set) var homeStatsSnapshot: HistoryStatisticsSnapshot = .zero

    private var cancellables = Set<AnyCancellable>()

    init(localHistoryStore: LocalHistoryStore) {
        homeStatsSnapshot = localHistoryStore.todayStatistics()

        localHistoryStore.$entries
            .sink { [weak self, weak localHistoryStore] _ in
                guard
                    let self,
                    let localHistoryStore
                else {
                    return
                }
                self.homeStatsSnapshot = localHistoryStore.todayStatistics()
            }
            .store(in: &cancellables)
    }
}
