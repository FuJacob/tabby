import Combine
import Foundation

/// Tracks whether macOS Low Power Mode is currently enabled and publishes changes so power-aware
/// features (such as automatically pausing autocomplete to save battery) can react live.
///
/// Lives on the main actor because `@Published` feeds SwiftUI and `SuggestionCoordinator`'s gating
/// logic, and `NSProcessInfoPowerStateDidChange` is delivered on an unspecified thread — the
/// subscription below hops back to main before touching `@Published` state. Distinct from
/// `PowerSourceMonitor` (which tracks AC vs. battery via IOKit): Low Power Mode is a separate OS-level
/// toggle the user (or the system, automatically below 20% battery) can flip independently of whether
/// the Mac is plugged in.
@MainActor
final class LowPowerModeMonitor: ObservableObject {
    @Published private(set) var isLowPowerModeEnabled: Bool

    private var powerStateObserver: NSObjectProtocol?

    init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // `NSProcessInfoPowerStateDidChange` does not guarantee a delivery queue, unlike
        // `NSWorkspace` notifications elsewhere in this folder, so this explicitly targets the main
        // queue rather than assuming the callback is already there.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLowPowerModeState()
            }
        }
    }

    deinit {
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    func refreshLowPowerModeState() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension LowPowerModeMonitor: SuggestionLowPowerModeProviding {
    /// The coordinator subscribes through this erased publisher so it can depend on
    /// `SuggestionLowPowerModeProviding` instead of this type's concrete `@Published` storage.
    var isLowPowerModeEnabledPublisher: AnyPublisher<Bool, Never> {
        $isLowPowerModeEnabled.eraseToAnyPublisher()
    }
}
