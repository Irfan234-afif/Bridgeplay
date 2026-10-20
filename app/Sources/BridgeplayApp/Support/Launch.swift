import Foundation

@main
enum Launch {
    static func main() {
        // Before anything opens the support folder: the 3.0.0 move needs the old one intact.
        MainActor.assumeIsolated { MigrationLaunch.shared.runAtLaunch() }
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(InstallIntoSteamCommand.flag) {
            InstallIntoSteamCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(SetupWinecxCommand.flag) {
            SetupWinecxCommand.run()
        }
        #if DEBUG
        if CommandLine.arguments.dropFirst().contains(SetupPreviewApp.flag) {
            SetupPreviewApp.main()
            return
        }
        #endif
        BridgeplayApp.main()
    }
}
