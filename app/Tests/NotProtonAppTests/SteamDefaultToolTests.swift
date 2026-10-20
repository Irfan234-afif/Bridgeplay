import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam default compatibility tool")
struct SteamDefaultToolTests {

    private static let head = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        """
    private static let tail = """
        \t\t\t}
        \t\t}
        \t}
        }
        """

    private static func entry(_ tool: String) -> String {
        """
        \t\t\t\t\t"0"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"\(tool)"
        \t\t\t\t\t\t"config"\t\t""
        \t\t\t\t\t\t"priority"\t\t"75"
        \t\t\t\t\t}
        """
    }

    @Test("Adds CompatToolMapping with the default when Steam has none")
    func addsMapping() throws {
        let text = Self.head + "\n\t\t\t\t\"SentryFile\"\t\t\"x\"\n" + Self.tail
        let result = try #require(SteamDefaultTool.updated(text, tool: "notproton-winecx-11.17"))
        #expect(result == Self.head + "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n" + Self.entry("notproton-winecx-11.17")
            + "\n\t\t\t\t}\n\t\t\t\t\"SentryFile\"\t\t\"x\"\n" + Self.tail)
    }

    @Test("Adds the default beside per-app mappings and keeps them")
    func keepsAppMappings() throws {
        let app = "\t\t\t\t\t\"3764200\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"other\"\n\t\t\t\t\t}"
        let text = Self.head + "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n" + app + "\n\t\t\t\t}\n" + Self.tail
        let result = try #require(SteamDefaultTool.updated(text, tool: "t"))
        #expect(result == Self.head + "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n" + Self.entry("t") + "\n" + app
            + "\n\t\t\t\t}\n" + Self.tail)
    }

    @Test("Replaces an existing default and is idempotent")
    func replacesDefault() throws {
        let text = Self.head + "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n" + Self.entry("old") + "\n\t\t\t\t}\n" + Self.tail
        let once = try #require(SteamDefaultTool.updated(text, tool: "new"))
        #expect(once == Self.head + "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n" + Self.entry("new") + "\n\t\t\t\t}\n" + Self.tail)
        #expect(SteamDefaultTool.updated(once, tool: "new") == once)
    }

    @Test("Refuses a file without a Valve > Steam section")
    func refusesUnknownLayout() {
        #expect(SteamDefaultTool.updated("\"InstallConfigStore\"\n{\n}\n", tool: "t") == nil)
    }
}
