import Foundation
import Sparkle
import Observation

@Observable
@MainActor
final class CheckForUpdatesModel: NSObject {
    var canCheckForUpdates = false

    let updaterController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        observation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }
}
