import Foundation
import Testing

@testable import BridgeplayApp

// #391: a Steam.app root owns (MDM, `sudo cp`) was blamed on another account on this Mac.
@Suite("Who owns a refused path")
struct RemedyOwnerTests {

    private static let user: uid_t = 501

    private func steamBundle() throws -> (root: URL, app: URL, inside: String) {
        let root = URL.temporaryDirectory.appending(path: "np-owner-\(UUID().uuidString)")
        let app = root.appending(path: "Steam.app")
        let inside = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: app.appending(path: "Contents/Info.plist"))
        return (root, app, inside.path(percentEncoded: false))
    }

    @Test("A bundle root owns is root's, with the bundle to hand over")
    func rootOwnedBundle() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        let remedy = Remedy(forPath: steam.inside, owner: { _ in 0 }, user: Self.user)

        #expect(remedy == .rootOwned(bundle: steam.app.path(percentEncoded: false)))
        #expect(remedy.settingsPane == nil)
    }

    @Test("A root folder outside a bundle gets no chown command")
    func rootOwnedFolder() {
        let remedy = Remedy(forPath: "/nonexistent/folder", owner: { _ in 0 }, user: Self.user)

        #expect(remedy == .rootOwned(bundle: nil))
        #expect(!remedy.advice.contains("chown"))
    }

    @Test("A bundle another user owns is still another account's")
    func otherUser() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(Remedy(forPath: steam.inside, owner: { _ in 502 }, user: Self.user) == .otherAccount)
    }

    @Test("Root running the app owns what root owns")
    func rootIsItsOwnAccount() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(Remedy(forPath: steam.inside, owner: { _ in 0 }, user: 0) == .appManagement)
    }

    @Test("An own folder inside a bundle asks for App Management")
    func ownBundle() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(Remedy(forPath: steam.inside) == .appManagement)
        #expect(Remedy(forPath: steam.inside, owner: { _ in Self.user }, user: Self.user) == .appManagement)
    }

    @Test("An own folder outside a bundle asks to check ownership")
    func ownFolder() throws {
        let root = URL.temporaryDirectory.appending(path: "np-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Remedy(forPath: root.path(percentEncoded: false)) == .ownership)
    }

    @Test("The advice names the bundle and a command that hands it over")
    func adviceCarriesTheCommand() {
        let advice = Remedy.rootOwned(bundle: "/Applications/Steam.app").advice

        #expect(advice.contains("/Applications/Steam.app belongs to the system (root)"))
        #expect(advice.contains("sudo chown -R '\(NSUserName())' '/Applications/Steam.app'"))
        #expect(!advice.contains("another account"))
    }

    @Test("The command quotes paths with spaces and apostrophes")
    func commandQuotesThePath() {
        #expect(
            Remedy.chownCommand("/Volumes/Ray's Drive/Steam.app", user: "ray")
                == #"sudo chown -R 'ray' '/Volumes/Ray'\''s Drive/Steam.app'"#
        )
    }

    @Test("Installing into a root-owned Steam says root owns it, not another account")
    func installerNamesRoot() throws {
        let root = Remedy.rootOwned(bundle: "/Applications/Steam.app")

        for deployed in [false, true] {
            let detail = try #require(SteamInstaller.refusalDetail(root, deployed: deployed))
            #expect(detail.contains("(root)"))
            #expect(detail.contains("sudo chown -R"))
            #expect(!detail.contains("another account"))
            #expect(!detail.contains("account that owns Steam"))
        }
    }

    @Test("Installing into another account's Steam keeps its own messages")
    func installerNamesOtherAccount() throws {
        let unpatched = try #require(SteamInstaller.refusalDetail(.otherAccount, deployed: false))
        let mismatch = try #require(SteamInstaller.refusalDetail(.otherAccount, deployed: true))

        #expect(unpatched.contains("Install from the account that owns Steam"))
        #expect(mismatch.contains("installed by another account"))
        #expect(SteamInstaller.refusalDetail(.appManagement, deployed: false) == nil)
        #expect(SteamInstaller.refusalDetail(.ownership, deployed: true) == nil)
    }

    @Test("The command line says root owns it")
    func commandLineNamesRoot() {
        let refusal = WriteRefused(path: "/usr/bin")
        let message = RemoveEverythingCommand.failureMessage(refusal)

        #expect(message.contains("belongs to root"))
        #expect(!message.contains("another account"))
    }
}
