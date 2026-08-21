import CoreGraphics
import Foundation

/// File overview:
/// One application's per-app shortcut customization. Each field is **optional** so the
/// "no custom shortcut → fall back to the global binding" state is first-class instead of a
/// sentinel value: if `acceptKeyCode == nil`, the accept binding for this app is inherited
/// from `SuggestionSettingsModel.acceptanceKeyCode`.
///
/// The bundle identifier is the durable identity used by the suggestion pipeline and the input
/// monitor's event-time provider closures. The display name is saved alongside so Settings can
/// render a readable list without having to resolve installed applications on every launch.
///
/// `ShortcutResolver` is the only place that should consume these overrides; rely on it so the
/// precedence rule (per-app → global) stays in a single, testable spot.
struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    /// `nil` for any field means "inherit the global binding for that action". The three accept
    /// fields move as a unit — UI and resolver both treat (keyCode, modifiers, label) as one
    /// binding — so cleared overrides set all three to nil.
    var acceptKeyCode: CGKeyCode?
    var acceptKeyModifiers: ShortcutModifierMask?
    var acceptKeyLabel: String?
    var fullAcceptKeyCode: CGKeyCode?
    var fullAcceptKeyModifiers: ShortcutModifierMask?
    var fullAcceptKeyLabel: String?

    var id: String { bundleIdentifier }

    /// A copy with any *partially*-specified binding collapsed back to "inherit global". Each binding
    /// is a unit of (keyCode, modifiers, label) and `ShortcutResolver` only fires when all three are
    /// present, so a row persisted with — say — a key code but no label would otherwise appear in
    /// Settings yet never fire at event time. Normalizing on load keeps the stored shape matching
    /// exactly what the resolver honors while preserving intentionally inherited rows.
    var bindingsNormalized: PerAppShortcutOverride {
        var normalized = self
        if acceptKeyCode == nil || acceptKeyModifiers == nil || acceptKeyLabel == nil {
            normalized.acceptKeyCode = nil
            normalized.acceptKeyModifiers = nil
            normalized.acceptKeyLabel = nil
        }
        if fullAcceptKeyCode == nil || fullAcceptKeyModifiers == nil || fullAcceptKeyLabel == nil {
            normalized.fullAcceptKeyCode = nil
            normalized.fullAcceptKeyModifiers = nil
            normalized.fullAcceptKeyLabel = nil
        }
        return normalized
    }

    /// Whether this row pins an accept key (i.e. the user explicitly chose one, including the
    /// "no key" sentinel for "this app should never accept word-by-word").
    var hasAcceptOverride: Bool { acceptKeyCode != nil }
    var hasFullAcceptOverride: Bool { fullAcceptKeyCode != nil }
}
