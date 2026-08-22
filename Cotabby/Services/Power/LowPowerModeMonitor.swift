import Combine
import Foundation

/// Bridges `ProcessInfo.isLowPowerModeEnabled` into the suggestion pipeline.
///
/// `CotabbyAppEnvironment` owns one instance for the process lifetime. The coordinator reads its
/// initial state synchronously and subscribes to later transitions. Main-actor isolation protects
/// `@Published` state because Foundation does not guarantee the notification's delivery queue.
///
/// This remains separate from `PowerSourceMonitor`, which tracks AC power rather than Low Power Mode.
@MainActor
final class LowPowerModeMonitor: ObservableObject {
    @Published private(set) var isLowPowerModeEnabled: Bool

    private var powerStateObserver: NSObjectProtocol?

    init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Foundation does not guarantee a delivery queue, so observe on the main queue.
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

    /// Refreshes the current value without emitting duplicate state changes.
    func refreshLowPowerModeState() {
        let latestValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard isLowPowerModeEnabled != latestValue else {
            return
        }

        isLowPowerModeEnabled = latestValue
    }
}

extension LowPowerModeMonitor: SuggestionLowPowerModeProviding {
    /// Omits `@Published`'s bootstrap emission because the protocol exposes initial state separately.
    var lowPowerModeChanges: AnyPublisher<Bool, Never> {
        $isLowPowerModeEnabled
            .dropFirst()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
