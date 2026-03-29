import Foundation

enum MagicianPermissionAction: Equatable {
    case requestAccessibility
    case requestCalendarAccess
    case openSystemSettings(urlString: String)
    case openExternalURL(urlString: String)
    case openShortcutsApp
    case openNotesApp
    case openMailApp
    case openMusicApp
}

struct MagicianPermissionPromptModel: Identifiable, Equatable {
    let feature: MagicianFeatureID
    let title: String
    let message: String
    let primaryButtonTitle: String
    let secondaryButtonTitle: String
    let primaryAction: MagicianPermissionAction

    var id: String { feature.rawValue }
}
