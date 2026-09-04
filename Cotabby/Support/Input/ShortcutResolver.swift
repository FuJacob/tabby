import CoreGraphics
import Foundation

/// Resolves the effective accept binding for the focused app. A matching per-app value wins;
/// otherwise the global binding is returned.
enum ShortcutResolver {
    struct ResolvedBinding: Equatable {
        let keyCode: CGKeyCode
        let modifiers: ShortcutModifierMask
        let label: String
    }

    static func acceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        if let binding = override(for: frontmostBundleIdentifier, in: overrides)?.acceptance {
            return ResolvedBinding(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                label: binding.label
            )
        }
        return ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
    }

    static func fullAcceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        if let binding = override(for: frontmostBundleIdentifier, in: overrides)?.fullAcceptance {
            return ResolvedBinding(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                label: binding.label
            )
        }
        return ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
    }

    private static func override(
        for bundleIdentifier: String?,
        in overrides: [PerAppShortcutOverride]
    ) -> PerAppShortcutOverride? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return overrides.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
