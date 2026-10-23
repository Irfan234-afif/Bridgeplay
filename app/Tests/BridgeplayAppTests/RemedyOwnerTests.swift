import Foundation
import Testing

@testable import BridgeplayApp

// #391: a Steam.app root owns (MDM, `sudo cp`) was blamed on another account on this Mac.
@Suite("Who owns a refused path")
struct RemedyOwnerTests {

    private static let user: uid_t = 501
    private static let staff: gid_t = 20
    private static let admin: gid_t = 80

    private static func owned(by uid: uid_t, group: gid_t = 0, mode: Int = 0o755) -> (String) -> Remedy.Owner? {
        { _ in Remedy.Owner(uid: uid, gid: group, mode: mode) }
    }

    private func remedy(_ path: String, _ owner: @escaping (String) -> Remedy.Owner?,
                        groups: Set<gid_t> = [staff]) -> Remedy {
        Remedy(forPath: path, owner: owner, user: Self.user, groups: groups)
    }

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

        let found = remedy(steam.inside, Self.owned(by: 0))

        #expect(found == .rootOwned(bundle: steam.app.path(percentEncoded: false)))
        #expect(found.settingsPane == nil)
    }

    @Test("A refusal inside a nested app names the outer bundle")
    func nestedAppNamesTheOuterBundle() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }
        let helper = steam.app.appending(path: "Contents/MacOS/Frameworks/Steam Helper.app")
        try FileManager.default.createDirectory(
            at: helper.appending(path: "Contents/MacOS"), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: helper.appending(path: "Contents/Info.plist"))

        let inside = helper.appending(path: "Contents/MacOS").path(percentEncoded: false)

        #expect(remedy(inside, Self.owned(by: 0)) == .rootOwned(bundle: steam.app.path(percentEncoded: false)))
    }

    @Test("A root folder outside a bundle gets no chown command")
    func rootOwnedFolder() {
        let found = remedy("/nonexistent/folder", Self.owned(by: 0))

        #expect(found == .rootOwned(bundle: nil))
        #expect(!found.advice.contains("chown"))
        #expect(!found.advice.contains("its owner"), "advised taking over a system folder")
    }

    // /Applications itself is root:admin 775. A target missing under it is looked up there.
    @Test("A missing target under /Applications is not advised to take over /Applications")
    func missingTargetUnderApplications() {
        let found = remedy("/Applications/np-missing-\(UUID().uuidString).app",
                           Self.owned(by: 0, group: Self.admin, mode: 0o775))

        #expect(found == .rootOwned(bundle: nil))
        #expect(!found.advice.contains("chown"))
    }

    @Test("A root:admin group-writable bundle asks an admin for App Management")
    func groupWritableBundleAsksForAppManagement() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }
        let owner = Self.owned(by: 0, group: Self.admin, mode: 0o775)

        #expect(remedy(steam.inside, owner, groups: [Self.staff, Self.admin]) == .appManagement)
        #expect(remedy(steam.inside, owner, groups: [Self.staff]) == .rootOwned(bundle: steam.app.path(percentEncoded: false)))
    }

    @Test("A world-writable bundle another account owns asks for App Management")
    func worldWritableBundleAsksForAppManagement() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(remedy(steam.inside, Self.owned(by: 502, group: Self.staff, mode: 0o777)) == .appManagement)
    }

    @Test("A bundle another user owns is still another account's")
    func otherUser() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(remedy(steam.inside, Self.owned(by: 502, group: Self.staff)) == .otherAccount)
    }

    @Test("Root running the app owns what root owns")
    func rootIsItsOwnAccount() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(Remedy(forPath: steam.inside, owner: Self.owned(by: 0), user: 0, groups: [0]) == .appManagement)
    }

    @Test("An own folder inside a bundle asks for App Management")
    func ownBundle() throws {
        let steam = try steamBundle()
        defer { try? FileManager.default.removeItem(at: steam.root) }

        #expect(Remedy(forPath: steam.inside) == .appManagement)
        #expect(remedy(steam.inside, Self.owned(by: Self.user, group: Self.staff)) == .appManagement)
    }

    @Test("An own folder outside a bundle asks to check ownership")
    func ownFolder() throws {
        let root = URL.temporaryDirectory.appending(path: "np-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Remedy(forPath: root.path(percentEncoded: false)) == .ownership)
    }

    @Test("The real lookup reads owner, group and mode")
    func realLookup() throws {
        let owner = try #require(Remedy.owner(of: "/usr/bin"))

        #expect(owner.uid == 0)
        #expect(!owner.letsWrite(Self.user, groups: [Self.staff, Self.admin]))
        #expect(Remedy.groups().contains(getgid()))
    }

    @Test("The remedy is fixed when the write is refused")
    func remedyIsTakenAtRefusal() throws {
        let steam = try steamBundle()
        let refusal = WriteRefused(path: steam.inside)
        try FileManager.default.removeItem(at: steam.root)

        #expect(refusal.remedy == .appManagement)
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

    @Test("Refusals root owns in one bundle keep the command")
    func oneRootBundleKeepsTheCommand() throws {
        let steam = Remedy.rootOwned(bundle: "/Applications/Steam.app")
        let report = try #require(FailureReport([
            WriteRefused(path: "/Applications/Steam.app/Contents/MacOS", remedy: steam),
            WriteRefused(path: "/Applications/Steam.app/Contents/Info.plist", remedy: steam),
        ]))

        #expect(report.remedy == steam)
        #expect(report.message.contains("sudo chown -R"))
    }

    @Test("Refusals root owns in different places still get advice")
    func rootRefusalsInDifferentPlacesShareAdvice() throws {
        let report = try #require(FailureReport([
            WriteRefused(path: "/Applications/Steam.app/Contents/MacOS",
                         remedy: .rootOwned(bundle: "/Applications/Steam.app")),
            WriteRefused(path: "/Library/Shared/np", remedy: .rootOwned(bundle: nil)),
        ]))

        #expect(report.remedy == .rootOwned(bundle: nil))
        #expect(report.message.contains("belongs to the system (root)"))
        #expect(!report.message.contains("chown"))
    }

    @Test("Refusals with different causes share no advice")
    func mixedRefusalsShareNothing() throws {
        let report = try #require(FailureReport([
            WriteRefused(path: "/a", remedy: .rootOwned(bundle: nil)),
            WriteRefused(path: "/b", remedy: .otherAccount),
        ]))

        #expect(report.remedy == nil)
    }

    @Test("Installing into a root-owned Steam says root owns it, not another account")
    func installerNamesRoot() throws {
        let root = Remedy.rootOwned(bundle: "/Applications/Steam.app")

        let unpatched = try #require(SteamInstaller.refusalDetail(root, deployed: false))
        #expect(unpatched == root.advice)

        let mismatch = try #require(SteamInstaller.refusalDetail(root, deployed: true))
        #expect(mismatch.hasPrefix("Steam has a different copy of Bridgeplay, and this account cannot update it."))
        #expect(mismatch.hasSuffix(root.advice))

        for detail in [unpatched, mismatch] {
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

    @Test("The command line gives the app's advice, except for App Management")
    func commandLineSharesTheAdvice() {
        let root = Remedy.rootOwned(bundle: "/Applications/Steam.app")

        #expect(RemoveEverythingCommand.failureMessage(WriteRefused(path: "/x", remedy: root))
            == "Could not write /x. \(root.advice)")
        #expect(RemoveEverythingCommand.failureMessage(WriteRefused(path: "/x", remedy: .appManagement))
            .contains("Allow your terminal app"))
    }
}
