import Foundation

enum PermissionState: String {
    case notRequested
    case pending
    case granted
    case denied
}

struct PermissionSnapshot {
    let microphone: PermissionState
    let accessibility: PermissionState
}

struct PermissionsCenter {
    func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: .notRequested,
            accessibility: .notRequested
        )
    }
}
