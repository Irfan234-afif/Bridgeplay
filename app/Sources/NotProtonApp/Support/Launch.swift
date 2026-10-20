import Foundation

@main
enum Launch {
    static func main() {
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
        NotProtonApp.main()
    }
}
