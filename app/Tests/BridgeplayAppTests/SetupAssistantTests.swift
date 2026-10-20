import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Setup Assistant")
struct SetupAssistantTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Steam counts as signed in once loginusers.vdf names an account")
    func signIn() throws {
        let dir = try folder()
        let file = dir.appending(path: "loginusers.vdf")
        #expect(!SetupChecks.steamSignedIn(loginUsers: file))
        try "\"users\"\n{\n}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!SetupChecks.steamSignedIn(loginUsers: file))
        try "\"users\"\n{\n\t\"7656\"\n\t{\n\t\t\"AccountName\"\t\t\"player\"\n\t}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SetupChecks.steamSignedIn(loginUsers: file))
    }

    @Test("The newest Game Porting Toolkit image in Downloads comes first, other files are ignored")
    func candidates() throws {
        let dir = try folder()
        for name in ["Game_Porting_Toolkit_4.0_beta_1.dmg", "Game_Porting_Toolkit_4.0_beta_2.dmg",
                     "Game_Porting_Toolkit_3.0.dmg", "Game_Porting_Toolkit_notes.pdf", "steam.dmg"] {
            FileManager.default.createFile(atPath: dir.appending(path: name).path(percentEncoded: false), contents: Data())
        }
        #expect(GPTKImport.candidates(in: dir).map(\.lastPathComponent) == [
            "Game_Porting_Toolkit_4.0_beta_2.dmg", "Game_Porting_Toolkit_4.0_beta_1.dmg", "Game_Porting_Toolkit_3.0.dmg",
        ])
    }

    @Test("The evaluation environment image inside Apple's outer image is found")
    func innerImage() throws {
        let dir = try folder()
        let inner = "Evaluation environment for Windows games 4.0 beta 2.dmg"
        for name in [inner, "Metal Shader Converter 4.0 beta 2.pkg", "Read Me.webloc"] {
            FileManager.default.createFile(atPath: dir.appending(path: name).path(percentEncoded: false), contents: Data())
        }
        #expect(GPTKImport.innerImage(in: dir)?.lastPathComponent == inner)
    }

    // Mounts Apple's real image, like FreeEngineWinecxTests.unpacksRealArchive, when
    // NOTPROTON_GPTK_DMG points at Game_Porting_Toolkit_<version>.dmg.
    @Test("Apple's Game Porting Toolkit image imports into a folder D3DMetal linking accepts",
          .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_GPTK_DMG"] != nil))
    func importsRealImage() throws {
        let image = URL(filePath: try #require(ProcessInfo.processInfo.environment["NOTPROTON_GPTK_DMG"]))
        let destination = try folder().appending(path: "gptk", directoryHint: .isDirectory)
        let payload = try GPTKImport.importImage(image, into: destination)
        #expect(payload.libRoot.standardizedFileURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "external/D3DMetal.framework").path(percentEncoded: false)))
        #expect(payload.version != nil)
    }

    @Test("Rosetta counts as installed only when its runtime exists")
    func rosetta() throws {
        let dir = try folder()
        let runtime = dir.appending(path: "libRosettaRuntime")
        #expect(!SetupChecks.rosettaInstalled(runtime: runtime))
        FileManager.default.createFile(atPath: runtime.path(percentEncoded: false), contents: Data())
        #expect(SetupChecks.rosettaInstalled(runtime: runtime))
    }

    @Test("The assistant stays away once the user finished or dismissed it")
    @MainActor
    func finishedFlag() throws {
        let defaults = try #require(UserDefaults(suiteName: "setup-\(UUID().uuidString)"))
        defaults.set(true, forKey: SetupAssistant.finishedKey)
        #expect(!SetupAssistant.shouldShow(nil, defaults: defaults))
    }
}

@Suite("Setup checks")
struct SetupChecksTests {

    @Test("Downloads is not read when a Game Porting Toolkit is already installed")
    func downloadsScanGated() {
        var scans = 0
        let scan: () -> [URL] = { scans += 1; return [URL(filePath: "/Downloads/Game_Porting_Toolkit_3.0.dmg")] }
        #expect(GPTKImport.candidatesIfMissing(installed: true, scan: scan).isEmpty)
        #expect(scans == 0)
        #expect(GPTKImport.candidatesIfMissing(installed: false, scan: scan).count == 1)
        #expect(scans == 1)
    }

    @Test("Rosetta failures read as plain sentences")
    func rosettaMessages() {
        let cancelled = CommandFailure(command: "osascript", status: 1, stderr: "0:120: execution error: User canceled. (-128)")
        #expect(SetupChecks.rosettaFailure(cancelled).contains("password window was closed"))
        let denied = CommandFailure(command: "osascript", status: 1, stderr: "execution error: The administrator user name or password was incorrect. (-60005)")
        #expect(SetupChecks.rosettaFailure(denied).contains("administrator"))
        let other = CommandFailure(command: "osascript", status: 1, stderr: "softwareupdate: network down")
        let message = SetupChecks.rosettaFailure(other)
        #expect(!message.contains("osascript"))
        #expect(message.contains("internet"))
    }

    @Test("The App Management advice explains the switch that looks on after an update")
    func appManagementAdvice() {
        #expect(Remedy.appManagement.advice.contains("App Management"))
        #expect(Remedy.appManagement.advice.contains("off and on again"))
    }
}
