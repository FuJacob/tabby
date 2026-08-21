import Foundation

/// Shortcut choices for one app. A `nil` action inherits its global binding; the disabled-key
/// sentinel remains an explicit override.
struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    var acceptance: SuggestionShortcutBindingSettings?
    var fullAcceptance: SuggestionShortcutBindingSettings?

    var id: String { bundleIdentifier }
}
