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
        NotProtonApp.main()
    }
}
