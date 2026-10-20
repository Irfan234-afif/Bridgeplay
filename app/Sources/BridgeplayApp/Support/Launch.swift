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
            refuseWhileMigrating()
            InstallIntoSteamCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(SetupWinecxCommand.flag) {
            AppLog.note("command line: \(SetupWinecxCommand.flag)")
            refuseWhileMigrating()
            SetupWinecxCommand.run()
        }
        BridgeplayApp.main()
    }

    // The installs write the new support folder, which the pending 3.0 move must find as
    // it left it, so they wait for it like the app's own buttons do.
    private static func refuseWhileMigrating() {
        guard let refusal = MainActor.assumeIsolated({ MigrationLaunch.shared.refusal }) else { return }
        AppLog.note("command line refused: the 3.0 folder move is pending")
        FileHandle.standardError.write(Data("\(refusal)\n".utf8))
        exit(AppLog.finished(1))
    }
}
