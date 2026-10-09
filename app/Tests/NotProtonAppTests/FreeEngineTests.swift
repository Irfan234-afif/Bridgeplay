import Foundation
import Testing

@testable import NotProtonApp

@Suite("Free WineHQ engine")
struct FreeEngineTests {

    private func makeEngines() throws -> URL {
        let engines = FileManager.default.temporaryDirectory
            .appending(path: "np-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        return engines
    }

    @Test("The pinned release names a free build NotProton knows how to patch")
    func releaseIsSupported() throws {
        let build = try #require(SupportedRunners.build(id: FreeEngine.current.build))
        #expect(build.isFree)
        #expect(!NtdllPatcher.patches(for: build).isEmpty)
        #expect(SupportedRunners.all.filter(\.isFree).map(\.id).contains(FreeEngine.current.build))
    }

    @Test("A CrossOver-shaped tree whose loader is not a free build still needs a license")
    func crossOverKeepsItsLicenseCheck() throws {
        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let root = engines.appending(path: "Fake.app/Contents/SharedSupport/CrossOver")
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not wine".utf8).write(to: loader)

        #expect(CrossOverLicense.freeBuild(at: root) == nil)
        #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
    }

    // Runs against the real archive once it has been downloaded, by NotProton or by hand
    // into the cache NotProton uses.
    @Test("Unpacking the real archive yields a supported, license-free, patchable engine")
    func unpacksRealArchive() throws {
        let archive = FreeEngine.downloads.appending(path: FreeEngine.current.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngine.current.sha256 else { return }

        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let renderer = FreeEngine.downloads.appending(path: FreeEngine.current.renderer.archive)
        let dxvkArchive = FreeEngine.downloads.appending(path: FreeEngine.current.dxvk.archive)
        let haveRenderer = Digest.sha256IfPresent(renderer) == FreeEngine.current.renderer.sha256
            && Digest.sha256IfPresent(dxvkArchive) == FreeEngine.current.dxvk.sha256
        let install = try FreeEngine.unpack(
            archive, renderer: haveRenderer ? renderer : nil, dxvk: haveRenderer ? dxvkArchive : nil,
            release: FreeEngine.current, engines: engines
        )
        guard case .supported(let build) = install.support else {
            Issue.record("unpacked engine is \(install.support)")
            return
        }
        #expect(build.id == FreeEngine.current.build)
        #expect(install.isFree)
        #expect(FreeEngine.isInstalled(engines: engines) == haveRenderer)
        #expect(FreeEngine.hasRenderer(root: install.crossOverRoot) == haveRenderer)
        #expect(!FreeEngine.hasLegacyLayout(root: install.crossOverRoot))
        if haveRenderer { #expect(FreeEngine.layoutProblems(root: install.crossOverRoot).isEmpty) }
        #expect(CrossOverLicense.check(crossOverRoot: install.crossOverRoot).licensed)
        try RunnerInstaller.verifyClone(build: build, root: install.crossOverRoot)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: install.crossOverRoot, arch: patch.arch)
            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }
    }

    private func touch(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Builds a tree whose files hash to whatever the test hands in.
    private func release(table: [String: String]) -> FreeEngineRelease {
        FreeEngineRelease(
            build: "t", archive: "a", sha256: "", bases: [], bundleName: "T.app", wineTree: "w",
            renderer: RendererRelease(
                name: "r", archive: "r", sha256: "", bases: [], tree: "r",
                files: ["x86_64-windows/d3d11.dll": table["dxmt-d3d11"]!,
                        "x86_64-windows/winemetal.dll": table["winemetal"]!]),
            macDriver: table["mac"]!,
            stock: ["x86_64-windows/d3d11.dll": table["stock-d3d11"]!],
            dxvk: BackendRelease(
                name: "d", archive: "d", sha256: "", bases: [], tree: "d",
                files: ["x86_64-windows/d3d11.dll": table["dxvk-d3d11"]!])
        )
    }

    private func hash(_ text: String) -> String { Digest.sha256(of: Data(text.utf8)) }

    @Test("Layout paths keep Wine's D3D DLLs in lib/wine and put the backends beside it")
    func layoutPaths() {
        let r = FreeEngine.current.renderer
        #expect(r.installPath(of: "x86_64-windows/winemetal.dll") == "lib/wine/x86_64-windows/winemetal.dll")
        #expect(r.installPath(of: "i386-windows/winemetal.dll") == "lib/wine/i386-windows/winemetal.dll")
        #expect(r.installPath(of: "x86_64-unix/winemetal.so") == "lib/wine/x86_64-unix/winemetal.so")
        for name in ["dxgi", "d3d11", "d3d10core"] {
            for arch in ["x86_64-windows", "i386-windows"] {
                #expect(r.installPath(of: "\(arch)/\(name).dll")
                    == "lib/notproton-backends/dxmt/\(arch)/\(name).dll")
            }
        }
        #expect(FreeEngine.dxvkDirectory == "lib/notproton-backends/dxvk")
    }

    @Test("The hash table covers stock Wine, DXMT, DXVK and the mac driver, with no overlap")
    func hashTableCoverage() {
        let release = FreeEngine.current
        let table = FreeEngine.expectedFiles(release)
        for arch in ["x86_64-windows", "i386-windows"] {
            for name in ["dxgi", "d3d11", "d3d10core", "d3d12"] {
                #expect(table["lib/wine/\(arch)/\(name).dll"] == release.stock["\(arch)/\(name).dll"])
            }
            for name in ["dxgi", "d3d11", "d3d10core"] {
                #expect(table["lib/notproton-backends/dxmt/\(arch)/\(name).dll"] != nil)
            }
            for name in ["d3d11", "d3d10core"] {
                #expect(table["lib/notproton-backends/dxvk/\(arch)/\(name).dll"] != nil)
            }
            #expect(table["lib/wine/\(arch)/winemetal.dll"] != nil)
        }
        #expect(table["lib/wine/x86_64-unix/winemetal.so"] != nil)
        #expect(table[FreeEngine.macDriverPath] == release.macDriver)
        #expect(table.count == release.stock.count + release.renderer.files.count + release.dxvk.files.count + 1)
        // DXMT's D3D DLLs must differ from Wine's, or the migration check could not tell them apart.
        for (path, hash) in release.renderer.files where !path.contains("winemetal") {
            #expect(release.stock[path] != hash)
        }
    }

    @Test("Verification reports a tampered, missing or legacy file")
    func detectsTampering() throws {
        let root = try makeEngines()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = release(table: [
            "dxmt-d3d11": hash("dxmt"), "winemetal": hash("wm"), "mac": hash("mac"),
            "stock-d3d11": hash("stock"), "dxvk-d3d11": hash("dxvk"),
        ])
        #expect(!FreeEngine.hasRenderer(root: root, release: r))

        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        try touch(root, "lib/wine/x86_64-windows/winemetal.dll", "wm")
        try touch(root, "lib/notproton-backends/dxmt/x86_64-windows/d3d11.dll", "dxmt")
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "dxvk")
        try touch(root, FreeEngine.macDriverPath, "mac")
        #expect(FreeEngine.hasRenderer(root: root, release: r))
        #expect(!FreeEngine.hasLegacyLayout(root: root, release: r))

        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "tampered")
        #expect(FreeEngine.layoutProblems(root: root, release: r) == ["lib/wine/x86_64-windows/d3d11.dll"])
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "tampered")
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "dxvk")
        try FileManager.default.removeItem(at: root.appending(path: "lib/notproton-backends/dxmt"))
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
    }

    @Test("An engine with DXMT's DLLs baked into lib/wine is the old layout and no longer counts as installed")
    func migrationDetection() throws {
        let root = try makeEngines()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = release(table: [
            "dxmt-d3d11": hash("dxmt"), "winemetal": hash("wm"), "mac": hash("mac"),
            "stock-d3d11": hash("stock"), "dxvk-d3d11": hash("dxvk"),
        ])
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "dxmt")
        try touch(root, "lib/wine/x86_64-windows/winemetal.dll", "wm")
        try touch(root, FreeEngine.macDriverPath, "mac")
        #expect(FreeEngine.hasLegacyLayout(root: root, release: r))
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
        #expect(FreeEngine.layoutProblems(root: root, release: r).contains("lib/wine/x86_64-windows/d3d11.dll"))
        // A stock engine that simply has no backends yet is not "legacy", only incomplete.
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        #expect(!FreeEngine.hasLegacyLayout(root: root, release: r))
    }

    @Test("DXVK is pinned to a GitHub release asset with a hash for every DLL, both architectures")
    func dxvkPins() {
        let dxvk = FreeEngine.current.dxvk
        #expect(dxvk.bases.allSatisfy { $0.host() == "github.com" && $0.path().contains("Gcenx/DXVK-macOS") })
        #expect(dxvk.sha256.count == 64)
        #expect(dxvk.archive.hasSuffix(".tar.gz"))
        #expect(Set(dxvk.files.keys) == [
            "x86_64-windows/d3d10core.dll", "x86_64-windows/d3d11.dll",
            "i386-windows/d3d10core.dll", "i386-windows/d3d11.dll",
        ])
        #expect(dxvk.files.values.allSatisfy { $0.count == 64 })
        #expect(Set(dxvk.files.values).count == dxvk.files.count)
    }

    @Test("Runs against the real DXVK archive when cached")
    func unpacksRealDxvk() throws {
        let archive = FreeEngine.downloads.appending(path: FreeEngine.current.dxvk.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngine.current.dxvk.sha256 else { return }
        let work = try makeEngines()
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try Shell.run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)])
        #expect(result.status == 0)
        for (path, hash) in FreeEngine.current.dxvk.files {
            #expect(Digest.sha256IfPresent(work.appending(path: "\(FreeEngine.current.dxvk.tree)/\(path)")) == hash)
        }
    }

    @Test("Shipped game fixes are located in the payload and installed beside the user's own")
    func gamefixesDefaultInstall() throws {
        let work = try makeEngines()
        defer { try? FileManager.default.removeItem(at: work) }
        let payload = work.appending(path: "payload")
        try touch(payload, "gamefixes/1245620.conf", "BACKEND=dxmt\n")
        try touch(payload, "gamefixes/42.conf", "BACKEND=dxvk\n")
        try touch(payload, "gamefixes/.gitkeep", "")
        try touch(payload, "gamefixes/README", "x")

        let located = try InstallPayload.locateGamefixes(in: payload)
        #expect(located.map(\.lastPathComponent) == ["1245620.conf", "42.conf"])

        let support = work.appending(path: "support")
        let defaults = support.appending(path: "gamefixes-default")
        try touch(support, "gamefixes-default/stale.conf", "old")
        try touch(support, "gamefixes/mine.conf", "KEEP=1")
        for source in located {
            try SteamInstaller.installIfChanged(DeploymentContent.File(
                source: source, destination: defaults.appending(path: source.lastPathComponent),
                name: source.lastPathComponent))
        }
        SteamInstaller.pruneGamefixes(keeping: located.map(\.lastPathComponent), in: defaults)

        let names = try FileManager.default.contentsOfDirectory(atPath: defaults.path(percentEncoded: false)).sorted()
        #expect(names == ["1245620.conf", "42.conf"])
        #expect(try String(contentsOf: defaults.appending(path: "42.conf"), encoding: .utf8) == "BACKEND=dxvk\n")
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "gamefixes/mine.conf").path(percentEncoded: false)))
        #expect(SupportPaths.gamefixesDefault.lastPathComponent == "gamefixes-default")
        #expect(SupportPaths.gamefixesDefault.path(percentEncoded: false)
            == SupportPaths.support.path(percentEncoded: false) + "/gamefixes-default")
    }
}
