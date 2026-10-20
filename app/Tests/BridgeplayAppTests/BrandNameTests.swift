import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Bridgeplay names and the ones before 3.0")
struct BrandNameTests {

    @Test("A legacy tool name maps to its bridgeplay-proton spelling; any other name is unchanged")
    func migratesToolNames() {
        #expect(ToolName.migrated("notproton") == "bridgeplay-proton")
        #expect(ToolName.migrated("notproton-winecx-11.17") == "bridgeplay-proton-winecx-11.17")
        #expect(ToolName.migrated("notproton-fex-rosetta-41073") == "bridgeplay-proton-fex-rosetta-41073")
        #expect(ToolName.migrated("bridgeplay-proton-winecx") == "bridgeplay-proton-winecx")
        #expect(ToolName.migrated("GE-Proton9-1") == "GE-Proton9-1")
        #expect(ToolName.migrated("proton-notproton") == "proton-notproton")
    }

    @Test("Both spellings are Bridgeplay's tools, nothing else is")
    func recognisesBothPrefixes() {
        #expect(ToolName.isOurs("bridgeplay-proton"))
        #expect(!ToolName.isOurs("bridgeplay"))
        #expect(ToolName.isOurs("bridgeplay-proton-winecx-11.17"))
        #expect(ToolName.isOurs("notproton"))
        #expect(ToolName.isOurs("notproton-26.3"))
        #expect(!ToolName.isOurs("GE-Proton9-1"))
        #expect(!ToolName.isOurs("proton_9"))
        #expect(ToolName.isLegacy("notproton-winecx"))
        #expect(!ToolName.isLegacy("bridgeplay-proton-winecx"))
    }

    @Test("Every tool Bridgeplay serves is named bridgeplay-proton, so Steam Cloud maps its saves")
    func servedToolsUseTheNewPrefix() {
        let names = SupportedRunners.all.flatMap(\.tools).map(\.name)
            + FreeEngineWinecx.current.runner.tools.map(\.name)
            + SupportedRunners.toolPreference
            + [SupportedRunners.legacyToolName]
        #expect(!names.isEmpty)
        for name in names {
            #expect(name.hasPrefix(ToolName.prefix), "\(name)")
            #expect(name.contains("proton"), "\(name)")
        }
    }

    @Test("Support, caches and the home folder have new names and legacy twins")
    func pathsAndLegacyPaths() {
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        #expect(path(SupportPaths.support).hasSuffix("/Library/Application Support/bridgeplay"))
        #expect(path(SupportPaths.legacyApplicationSupport).hasSuffix("/Library/Application Support/notproton"))
        #expect(path(SupportPaths.caches).hasSuffix("/Library/Caches/bridgeplay"))
        #expect(path(SupportPaths.legacyCaches).hasSuffix("/Library/Caches/notproton"))
        #expect(path(SupportPaths.homeDir).hasSuffix("/.bridgeplay"))
        #expect(path(SupportPaths.legacyHomeDir).hasSuffix("/.notproton"))
        #expect(path(SupportPaths.packageDownloads).hasPrefix(path(SupportPaths.caches)))
        #expect(path(SupportPaths.winetricksDownloads).hasPrefix(path(SupportPaths.caches)))
        #expect(SupportPaths.steamBundlesRecord.lastPathComponent == "bridgeplay-steam-bundles.json")
        #expect(SupportPaths.legacySteamBundlesRecord.lastPathComponent == "notproton-steam-bundles.json")
        #expect(SupportPaths.dylibName == "notproton.dylib")
    }

    @Test("The list of modified Steam bundles is read from its old name and moved on the next write")
    func steamBundlesRecordFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-bundles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appending(path: "notproton-steam-bundles.json")
        let current = root.appending(path: "bridgeplay-steam-bundles.json")
        try JSONEncoder().encode(["/Applications/Steam.app"]).write(to: legacy)
        let modifications = SteamModifications(
            file: current, legacyRecord: root.appending(path: "install-build.json"), legacyFile: legacy)

        #expect(try modifications.paths().map(\.path) == ["/Applications/Steam.app"])

        try modifications.mark(URL(filePath: "/Volumes/Games/Steam.app"))
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
        #expect(try modifications.paths().map(\.path) == ["/Applications/Steam.app", "/Volumes/Games/Steam.app"])
    }

    @Test("An Info.plist backup under the old name counts, and is removed with the new one")
    func plistBackupUnderEitherName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let plist = root.appending(path: "Info.plist")
        try Data("modified".utf8).write(to: plist)
        try Data("pristine".utf8).write(to: backups.appending(path: SteamBundle.legacyPlistBackupName))

        #expect(try SteamInstaller.backUpPlist(plist, into: backups) == false)
        #expect(!FileManager.default.fileExists(
            atPath: backups.appending(path: SteamBundle.plistBackupName).path(percentEncoded: false)))

        #expect(try SteamRepair.removeStaleBackup(from: backups))
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).isEmpty)
    }
}
