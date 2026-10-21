import Foundation
import SystemConfiguration

// What a compatibility report says about this Mac and the game's last launch, and the
// redaction its public log copy goes through. Sent by PlayReports.
enum GameReport {

    // The options of the Mac chip and memory dropdowns in .github/ISSUE_TEMPLATE/game-report.yml,
    // so reports from the app and from the form read the same.
    static let chips = ["M1", "M1 Pro", "M1 Max", "M1 Ultra", "M2", "M2 Pro", "M2 Max", "M2 Ultra",
                        "M3", "M3 Pro", "M3 Max", "M3 Ultra", "M4", "M4 Pro", "M4 Max",
                        "M5", "M5 Pro", "M5 Max"]
    static let memorySizes = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]
    static let backends = ["dxmt", "dxvk", "wined3d", "d3dmetal"]

    struct Machine: Equatable {
        var chip: String
        var memoryBytes: UInt64
        var macOS: String
        var bridgeplay: String
    }

    static var thisMac: Machine {
        Machine(chip: SetupChecks.chipName, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                macOS: SetupChecks.macOSDisplay,
                bridgeplay: ProductVersion.build.map { "\(ProductVersion.short) (\($0))" } ?? ProductVersion.short)
    }

    // "Apple M5 Max" → "M5 Max"; a chip the form doesn't list is "Other".
    static func chip(_ brand: String) -> String {
        let name = brand.replacingOccurrences(of: "Apple ", with: "").trimmingCharacters(in: .whitespaces)
        return chips.contains(name) ? name : "Other"
    }

    static func memory(_ bytes: UInt64) -> String {
        let gb = Int((Double(bytes) / 1_073_741_824).rounded())
        return memorySizes.contains(gb) ? "\(gb) GB" : "Other"
    }

    // The engine and backend of the most recent launch in bridgeplay-run.log:
    //   runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /…
    //   graphics: backend=d3dmetal (carried over from the last launch)
    static func lastLaunch(in log: String) -> (engine: String?, backend: String?) {
        var engine: String?, backend: String?
        for line in log.split(separator: "\n") {
            if line.hasPrefix("runner: build "), let open = line.firstIndex(of: "("),
               let close = line.range(of: ") at ", options: .backwards) {
                engine = String(line[line.index(after: open)..<close.lowerBound])
            } else if line.hasPrefix("graphics: backend=") {
                let value = line.dropFirst("graphics: backend=".count).prefix { !$0.isWhitespace }
                if backends.contains(String(value)) { backend = String(value) }
            }
        }
        return (engine, backend)
    }

    // Reports are public. Besides the home folder, run logs carry the Steam account name
    // and a video token in the passed-through Steam environment, the SteamID64 in Steam API
    // lines, the macOS user name in lsof output, and external drive names in library paths.
    static func redacted(_ log: String, home: String = NSHomeDirectory(), user: String = NSUserName(),
                         computerNames: [String] = thisMacNames) -> String {
        var text = home.isEmpty ? log : log.replacingOccurrences(of: home, with: "~")
        let rules: [(String, String)] = [
            (#"(?m)^(SteamUser|SteamAppUser|STEAMVIDEOTOKEN|DSB_TOKEN)=.*$"#, "$1=<redacted>"),
            (#"\b7656119\d{10}\b"#, "<steamid>"),
            (#"\[U:1:\d+\]"#, "[U:1:<redacted>]"),
            (#"[\w.+-]{1,64}@[\w-]{1,63}(\.[\w-]{1,63})+"#, "<email>"),
            (#"/Volumes/(?!Preboot/|Macintosh HD/)[^/\n:]+"#, "/Volumes/<drive>"),
        ]
        for name in [user] + computerNames where name.count >= 3 {
            text = text.replacingOccurrences(of: #"\b\#(NSRegularExpression.escapedPattern(for: name))\b"#,
                                             with: name == user ? "<user>" : "<computer>",
                                             options: [.regularExpression, .caseInsensitive])
        }
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    static var thisMacNames: [String] {
        [SCDynamicStoreCopyComputerName(nil, nil), SCDynamicStoreCopyLocalHostName(nil)]
            .compactMap { $0 as String? }
    }
}
