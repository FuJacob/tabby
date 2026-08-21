import Combine
import Foundation

/// Tracks whether macOS Low Power Mode is currently enabled and publishes changes so power-aware
/// features (such as automatically pausing autocomplete to save battery) can react live.
///
/// `CotabbyAppEnvironment` owns one monitor for the process lifetime. The monitor reads the current
/// `ProcessInfo` value synchronously, then turns Foundation notifications into a changes-only stream
/// consumed by `SuggestionCoordinator`; it stays separate from suggestion orchestration so the OS
/// observation boundary can be shared without duplicating observers.
///
/// Lives on the main actor because `@Published` feeds SwiftUI and `SuggestionCoordinator`'s gating
/// logic, and `NSProcessInfoPowerStateDidChange` is delivered on an unspecified thread — the
/// subscription below hops back to main before touching `@Published` state. Distinct from
/// `PowerSourceMonitor` (which tracks AC vs. battery via IOKit): Low Power Mode is a separate OS-level
/// policy that can change independently of whether the Mac is plugged in.
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
        let latestValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard isLowPowerModeEnabled != latestValue else {
            return
        }

        isLowPowerModeEnabled = latestValue
    }
}

extension LowPowerModeMonitor: SuggestionLowPowerModeProviding {
    /// `@Published` begins with the current value. The coordinator already reads that value through
    /// `isLowPowerModeEnabled`, so this boundary drops the bootstrap emission and exposes only later
    /// changes. `removeDuplicates` also protects against redundant Foundation notifications.
    var lowPowerModeChanges: AnyPublisher<Bool, Never> {
        $isLowPowerModeEnabled
            .dropFirst()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
