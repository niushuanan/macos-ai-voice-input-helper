import Foundation

protocol TextOutputCoordinator {
    var insertionStrategy: String { get }
}

struct StubTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "Accessibility-assisted insertion with a pasteboard fallback"
}
