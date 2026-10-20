import Sparkle

@MainActor
final class AppUpdater {

    // One updater for the app: the menu and the Status page's Refresh share it.
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        #if !DEBUG
        controller.checkForUpdates(nil)
        #endif
    }

}
