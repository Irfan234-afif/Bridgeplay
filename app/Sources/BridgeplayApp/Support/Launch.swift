import Foundation

@main
enum Launch {
    static func main() {
        // Before anything opens the support folder: the 3.0.0 move needs the old one intact.
        MainActor.assumeIsolated { MigrationLaunch.shared.runAtLaunch() }
        #if DEBUG
        if CommandLine.arguments.dropFirst().contains(SetupPreviewApp.flag) {
            SetupPreviewApp.main()
            return
        }
        #endif
        // The command line paths log as well, so a scripted run leaves the same trail.
        AppLog.start()
        MainActor.assumeIsolated { MigrationLaunch.shared.logLaunchResult() }
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            AppLog.note("command line: \(RemoveEverythingCommand.flag)")
            RemoveEverythingCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(InstallIntoSteamCommand.flag) {
            AppLog.note("command line: \(InstallIntoSteamCommand.flag)")
            InstallIntoSteamCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(SetupWinecxCommand.flag) {
            AppLog.note("command line: \(SetupWinecxCommand.flag)")
            SetupWinecxCommand.run()
        }
        BridgeplayApp.main()
    }
}
