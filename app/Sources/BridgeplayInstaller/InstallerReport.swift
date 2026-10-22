import Foundation
import BridgeplayInstallerCore

/// A GitHub issue prefilled from the bug report form. The user reviews it before posting.
enum InstallerReport {
    static func issueURL(failure: String, version: String, installed: String?) -> URL? {
        let summary = failure.split(separator: "\n").first.map(String.init) ?? failure
        let fields = [
            ("template", "bug-report.yml"),
            ("title", "Installer: \(summary.prefix(80))"),
            ("what", "The installer stopped with:\n\n\(failure)"),
            ("version", "Installer, offering \(version)" + (installed.map { ", installed \($0)" } ?? "")),
            ("macos", InstallerLog.system),
            ("logs", InstallerLog.tail()),
        ]
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = fields.compactMap { name, value in
            value.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(name)=\($0)" }
        }.joined(separator: "&")
        return URL(string: "https://github.com/raymondchins/Bridgeplay/issues/new?\(query)")
    }
}
