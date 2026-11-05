import Combine
import Foundation
import Observation
import Sparkle

/// App updates through Sparkle. The feed URL and the public key that update archives are checked
/// against are in Info.plist (`SUFeedURL`, `SUPublicEDKey`).
///
/// Sparkle asks on the second launch whether to check automatically; until then, and if the answer
/// is no, Muesli only goes online for updates when "Check for Updates…" is chosen.
@MainActor
@Observable
final class Updater: NSObject {
    private(set) var canCheckForUpdates = false
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// True while relaunching would cut off a recording or a final pass.
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] can in self?.canCheckForUpdates = can }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    /// An update that's ready to install waits until no meeting is being recorded or processed,
    /// then relaunches.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle calls this on the main thread.
        let install = UncheckedSendable(installHandler)
        return MainActor.assumeIsolated {
            guard isBusy() else { return false }
            waitTask?.cancel()
            waitTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.isBusy() {
                    try? await Task.sleep(for: .seconds(5))
                }
                if !Task.isCancelled { install.value() }
            }
            return true
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// A menu bar app shouldn't put an update window in front of a meeting. Sparkle shows it
    /// without taking focus instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
