// We couldn't write? Logic for that

import AppKit
import Foundation

struct WriteRefused: LocalizedError {
    let path: String

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

    var remedy: Remedy { Remedy(forPath: path) }
}

// A write failure generally equals App Management permission error
// or bad folder ownership
enum Remedy: Hashable {
    case appManagement
    case otherAccount
    // Root owns it (MDM, `sudo cp`). Only a bundle gets a chown command: a root folder
    // outside one may be /Applications itself.
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
            String(localized: "This folder belongs to the system (root), not to your account, so Bridgeplay cannot change it. An administrator has to make your account its owner.")
        case .ownership: String(localized: "Check permissions, make sure your user owns the folder.")
        }
    }

    // Names this account rather than $(whoami): the administrator may run it from their own.
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

    static func owner(of path: String) -> uid_t? {
        let files = FileManager.default
        let url = URL(filePath: path)
        for candidate in [url, url.deletingLastPathComponent()] {
            guard
                let attributes = try? files.attributesOfItem(
                    atPath: candidate.path(percentEncoded: false)
                ),
                let owner = attributes[.ownerAccountID] as? NSNumber
            else { continue }
            return uid_t(owner.uint32Value)
        }
        return nil
    }

    static func enclosingBundle(of path: String) -> String? {
        let files = FileManager.default
        var directory = URL(filePath: path)
        while directory.pathComponents.count > 1 {
            let plist = directory.appending(path: "Contents/Info.plist")
            if files.fileExists(atPath: plist.path(percentEncoded: false)) {
                var bundle = directory.path(percentEncoded: false)
                if bundle.count > 1, bundle.hasSuffix("/") { bundle.removeLast() }
                return bundle
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    init(
        forPath path: String,
        owner: (String) -> uid_t? = Remedy.owner(of:),
        user: uid_t = getuid()
    ) {
        let bundle = Self.enclosingBundle(of: path)
        switch owner(path) {
        case 0? where user != 0: self = .rootOwned(bundle: bundle)
        case let other? where other != user: self = .otherAccount
        default: self = bundle == nil ? .ownership : .appManagement
        }
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
        let wanted = Set(refusals.map(\.remedy))
        remedy = refusals.count == errors.count && wanted.count == 1 ? wanted.first : nil

        var parts = reasons
        if let advice = remedy?.advice { parts.append(advice) }
        message = parts.joined(separator: " ")
    }
}
