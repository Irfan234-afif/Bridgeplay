import Foundation

// Steam's default compatibility tool: CompatToolMapping's "0" entry in config.vdf, which
// applies to every app without a mapping of its own. Steam rewrites config.vdf when it quits,
// so this is only written while Steam is closed.
enum SteamDefaultTool {
    static let globalPriority = "75"

    static var config: URL {
        SupportPaths.Steam.userData.appending(path: "config/config.vdf")
    }

    static func set(_ tool: String, in file: URL = config) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw StepFailure(step: step, detail: "Steam has no config.vdf yet. Open Steam once, log in, quit it and run this again.")
        }
        guard let result = updated(text, tool: tool) else {
            throw StepFailure(step: step, detail: "config.vdf has no InstallConfigStore > Software > Valve > Steam section.")
        }
        if result != text {
            try result.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static let step = "Set Steam's default compatibility tool"

    // Replaces the "0" entry under CompatToolMapping, or adds it (and CompatToolMapping) when
    // missing. nil when the file has no Valve > Steam section to put it in.
    static func updated(_ text: String, tool: String) -> String? {
        var lines = text.components(separatedBy: "\n")

        if let mapping = keyLine(lines, "CompatToolMapping", from: 0) {
            let depth = indent(lines[mapping])
            guard let open = openBrace(lines, after: mapping), let close = closeBrace(lines, open: open) else { return nil }
            let entryDepth = depth + 1
            if let zero = (open + 1 ..< close).first(where: {
                indent(lines[$0]) == entryDepth && key(lines[$0]) == "0"
            }), let zeroOpen = openBrace(lines, after: zero), let zeroClose = closeBrace(lines, open: zeroOpen) {
                lines.replaceSubrange(zero ... zeroClose, with: entry(tool, depth: entryDepth))
            } else {
                lines.insert(contentsOf: entry(tool, depth: entryDepth), at: open + 1)
            }
            return lines.joined(separator: "\n")
        }

        guard let valve = keyLine(lines, "Valve", from: 0),
              let steam = keyLine(lines, "Steam", from: valve + 1),
              let open = openBrace(lines, after: steam)
        else { return nil }
        let depth = indent(lines[steam]) + 1
        let tabs = String(repeating: "\t", count: depth)
        let block = ["\(tabs)\"CompatToolMapping\"", "\(tabs){"] + entry(tool, depth: depth + 1) + ["\(tabs)}"]
        lines.insert(contentsOf: block, at: open + 1)
        return lines.joined(separator: "\n")
    }

    private static func entry(_ tool: String, depth: Int) -> [String] {
        let tabs = String(repeating: "\t", count: depth)
        return [
            "\(tabs)\"0\"",
            "\(tabs){",
            "\(tabs)\t\"name\"\t\t\"\(tool)\"",
            "\(tabs)\t\"config\"\t\t\"\"",
            "\(tabs)\t\"priority\"\t\t\"\(globalPriority)\"",
            "\(tabs)}",
        ]
    }

    // A line holding only a quoted key (a section name), compared case-insensitively as
    // Steam's KeyValues does.
    private static func key(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
              trimmed.dropFirst().dropLast().contains("\"") == false
        else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func keyLine(_ lines: [String], _ name: String, from start: Int) -> Int? {
        guard start < lines.count else { return nil }
        return (start ..< lines.count).first {
            key(lines[$0])?.caseInsensitiveCompare(name) == .orderedSame
                && openBrace(lines, after: $0) == $0 + 1
        }
    }

    private static func openBrace(_ lines: [String], after line: Int) -> Int? {
        let next = line + 1
        guard next < lines.count, lines[next].trimmingCharacters(in: .whitespaces) == "{" else { return nil }
        return next
    }

    private static func closeBrace(_ lines: [String], open: Int) -> Int? {
        var depth = 0
        for index in open ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "{" { depth += 1 }
            if trimmed == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == "\t" }.count
    }
}
