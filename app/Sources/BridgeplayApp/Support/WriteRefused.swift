// We couldn't write? Logic for that

import AppKit
import Foundation

struct WriteRefused: LocalizedError {
    let path: String
    // Worked out when the write fails, while the folder is as the write found it.
    let remedy: Remedy

    init(path: String, remedy: Remedy? = nil) {
        self.path = path
        self.remedy = remedy ?? Remedy(forPath: path)
    }

    var errorDescription: String? { String(localized: "Could not write files.") }
}

extension WriteRefused {
    static func catching<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: path)
        }
    }

    static func catching<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try catching(url.path(percentEncoded: false), body)
    }
}

// A write failure generally equals App Management permission error
// or bad folder ownership
enum Remedy: Hashable {
    case appManagement
    case otherAccount
    // Root owns it (MDM, `sudo cp`). Only a bundle gets a chown command: a root folder
    // outside one may be /Applications itself, which nobody should take over.
    case rootOwned(bundle: String?)
    case ownership

    var advice: String {
        switch self {
        // macOS ties the permission to the app's signature, so after an update the switch can
        // stay on while no longer applying.
        case .appManagement:
            String(localized: "Bridgeplay needs the App Management permission. Turn on Bridgeplay in System Settings › Privacy & Security › App Management. After a Bridgeplay update the switch can look on but no longer work: turn it off and on again.")
        case .otherAccount:
            String(localized: "Steam was installed by another account on this Mac. Only that account can modify it. Log in to macOS with that account to reinstall Bridgeplay.")
        case .rootOwned(let bundle?):
            String(localized: "\(bundle) belongs to the system (root), not to your account, so Bridgeplay cannot change it. An administrator has to make your account its owner, for example by running this in Terminal: \(Self.chownCommand(bundle))")
        case .rootOwned(nil):
            String(localized: "This folder belongs to the system (root), and your account cannot write to it. Try again from an administrator account, or ask an administrator for help.")
        case .ownership: String(localized: "Check permissions, make sure your user owns the folder.")
        }
    }

    // Names this account rather than $(whoami): the administrator may run it from their own.
    // One owning account is what dragging Steam.app in gives; other accounts are already
    // handled as .otherAccount.
    static func chownCommand(_ path: String, user: String = NSUserName()) -> String {
        func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "sudo chown -R \(quoted(user)) \(quoted(path))"
    }

    static let settingsButton = String(localized: "Open System Settings")

    private static let appManagementPane =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"

    var settingsPane: URL? {
        switch self {
        case .appManagement: URL(string: Self.appManagementPane)
        case .otherAccount, .rootOwned, .ownership: nil
        }
    }

    @MainActor
    static func openSettings(_ pane: URL) {
        AppLog.note("opening App Management settings")
        NSWorkspace.shared.open(pane)
    }

    struct Owner: Equatable {
        var uid: uid_t
        var gid: gid_t
        var mode: Int

        // The POSIX check: owner bits for the owner, group bits for a member, other bits otherwise.
        func letsWrite(_ user: uid_t, groups: Set<gid_t>) -> Bool {
            if uid == user { return mode & 0o200 != 0 }
            if groups.contains(gid) { return mode & 0o020 != 0 }
            return mode & 0o002 != 0
        }
    }

    static func owner(of path: String) -> Owner? {
        let files = FileManager.default
        let url = URL(filePath: path)
        for candidate in [url, url.deletingLastPathComponent()] {
            guard
                let attributes = try? files.attributesOfItem(
                    atPath: candidate.path(percentEncoded: false)
                ),
                let uid = attributes[.ownerAccountID] as? NSNumber,
                let gid = attributes[.groupOwnerAccountID] as? NSNumber,
                let mode = attributes[.posixPermissions] as? NSNumber
            else { continue }
            return Owner(uid: uid_t(uid.uint32Value), gid: gid_t(gid.uint32Value), mode: mode.intValue)
        }
        return nil
    }

    static func groups(of user: String = NSUserName(), primary: gid_t = getgid()) -> Set<gid_t> {
        var size: Int32 = 64
        while size <= 4096 {
            var list = [Int32](repeating: 0, count: Int(size))
            var count = size
            if getgrouplist(user, Int32(bitPattern: primary), &list, &count) == 0 {
                return Set(list.prefix(Int(count)).map { gid_t(bitPattern: $0) })
            }
            size *= 2
        }
        return [primary]
    }

    // The outermost one, so a refusal inside Steam Helper.app names Steam.app.
    static func enclosingBundle(of path: String) -> String? {
        let files = FileManager.default
        var directory = URL(filePath: path)
        var outermost: String?
        while directory.pathComponents.count > 1 {
            let plist = directory.appending(path: "Contents/Info.plist")
            if files.fileExists(atPath: plist.path(percentEncoded: false)) {
                var bundle = directory.path(percentEncoded: false)
                if bundle.count > 1, bundle.hasSuffix("/") { bundle.removeLast() }
                outermost = bundle
            }
            directory = directory.deletingLastPathComponent()
        }
        return outermost
    }

    init(
        forPath path: String,
        owner: (String) -> Owner? = Remedy.owner(of:),
        user: uid_t = getuid(),
        groups: @autoclosure () -> Set<gid_t> = Remedy.groups()
    ) {
        // A folder the permissions let this account write was refused by App Management,
        // whoever owns it (a root:admin 775 Steam.app, for an admin).
        if let owner = owner(path), owner.uid != user, !owner.letsWrite(user, groups: groups()) {
            self = owner.uid == 0 ? .rootOwned(bundle: Self.enclosingBundle(of: path)) : .otherAccount
            return
        }
        self = Self.enclosingBundle(of: path) == nil ? .ownership : .appManagement
    }

    // One piece of advice for several refusals. Root-owned folders in different places
    // share theirs without a command, since no single chown covers them all.
    static func shared(by remedies: [Remedy]) -> Remedy? {
        let distinct = Set(remedies)
        if distinct.count == 1 { return distinct.first }
        let allRoot = !distinct.isEmpty && distinct.allSatisfy {
            if case .rootOwned = $0 { true } else { false }
        }
        return allRoot ? .rootOwned(bundle: nil) : nil
    }
}

struct FailureReport {
    let message: String
    let remedy: Remedy?

    var settingsPane: URL? { remedy?.settingsPane }

    init?(_ errors: [Error]) {
        guard !errors.isEmpty else { return nil }

        var seen = Set<String>()
        let reasons = errors.map(\.localizedDescription).filter { seen.insert($0).inserted }

        let refusals = errors.compactMap { $0 as? WriteRefused }
        remedy = refusals.count == errors.count ? Remedy.shared(by: refusals.map(\.remedy)) : nil

        var parts = reasons
        if let advice = remedy?.advice { parts.append(advice) }
        message = parts.joined(separator: " ")
    }
}
