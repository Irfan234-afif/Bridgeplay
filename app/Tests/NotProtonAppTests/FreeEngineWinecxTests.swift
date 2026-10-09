import Foundation
import Testing

@testable import NotProtonApp

@Suite("Free WineCX engine")
struct FreeEngineWinecxTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "np-winecx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The pinned release names a free build NotProton knows how to patch")
    func releaseIsSupported() throws {
        let build = try #require(SupportedRunners.build(id: FreeEngineWinecx.current.build))
        #expect(build == FreeEngineWinecx.runnerBuild)
        #expect(build.isFree)
        #expect(Set(NtdllPatcher.patches(for: build).map(\.arch)) == [.x86_64Windows, .i386Windows])
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256)?.id == build.id)
        #expect(build.tools.map(\.name) == ["notproton-winecx"])
        #expect(build.tools.first?.display == "WineCX 11.15 (msync, D3DMetal)")
        #expect(build.tools.first?.flavor == .rosetta)
    }

    @Test("Both free engines stay separate builds with their own loaders and tools")
    func coexistsWithWineHQ() throws {
        let free = SupportedRunners.all.filter(\.isFree)
        #expect(Set(free.map(\.id)) == [FreeEngine.current.build, FreeEngineWinecx.current.build])
        #expect(Set(free.map(\.loaderSHA256)).count == free.count)
        #expect(Set(free.flatMap(\.tools).map(\.name)).count == free.flatMap(\.tools).count)
        #expect(FreeEngineWinecx.current.bundleName != FreeEngine.current.bundleName)
    }

    // The license gate keys on the loader hash alone: a CrossOver-shaped tree whose loader
    // is anything else still needs CodeWeavers' license, wherever it sits.
    @Test("A tree that only looks like WineCX is not free")
    func lookalikeNeedsLicense() throws {
        let engines = try makeDirectory("engines")
        defer { try? FileManager.default.removeItem(at: engines) }

        let root = FreeEngineWinecx.bundle(engines: engines).appending(path: "Contents/SharedSupport/CrossOver")
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not winecx".utf8).write(to: loader)
        try Data("winecx-11.15\n".utf8).write(to: FreeEngineWinecx.msyncMarker(in: root))

        #expect(CrossOverLicense.freeBuild(at: root) == nil)
        #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
        #expect(!FreeEngineWinecx.isInstalled(engines: engines))
        #expect(!WinecxD3DMetal.isWinecx(root: root))
    }

    @Test("Backends follow the compat_run.sh layout and never shadow lib/wine")
    func backendLayout() {
        let backends = FreeEngineWinecx.current.backends
        #expect(!backends.isEmpty)
        #expect(Set(backends.map(\.destination)).count == backends.count)
        for file in backends {
            let parts = file.destination.split(separator: "/").map(String.init)
            #expect(parts.count == 3, "\(file.destination)")
            #expect(["dxmt", "dxvk"].contains(parts[0]), "\(file.destination)")
            #expect(["x86_64-windows", "i386-windows"].contains(parts[1]), "\(file.destination)")
            #expect(!["nvapi64.dll", "nvngx.dll"].contains(parts[2]))
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit))
            #expect(FreeEngineWinecx.backend(file.destination, in: URL(filePath: "/r")).path(percentEncoded: false)
                == "/r/lib/notproton-backends/\(file.destination)")
        }
        for backend in ["dxmt", "dxvk"] {
            for arch in ["x86_64-windows", "i386-windows"] {
                #expect(backends.contains { $0.destination == "\(backend)/\(arch)/d3d11.dll" })
            }
        }
        #expect(FreeEngineWinecx.msyncMarker(in: URL(filePath: "/r")).path(percentEncoded: false)
            == "/r/.notproton-msync")
        #expect(WinecxD3DMetal.enabledMarker(in: URL(filePath: "/r")).path(percentEncoded: false)
            == "/r/lib/notproton-backends/d3dmetal.enabled")
    }

    @Test("Downloads come only from the pinned GitHub release mirrors")
    func pinnedSources() {
        let release = FreeEngineWinecx.current
        #expect(release.sha256 == "6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87")
        #expect(release.bases.allSatisfy { $0.host() == "github.com" })
        #expect(release.bases.allSatisfy { $0.path().hasSuffix(release.runtime) })
        #expect(FreeEngineWinecx.downloads.lastPathComponent == "winecx-\(release.runtime)")
    }

    // MARK: - D3DMetal linking

    // A stand-in for Apple's redist/lib: the names and the builtin marker, none of the code.
    private func makePayload(in folder: URL, version: String? = "3.0", builtin: Bool = true) throws -> URL {
        let fm = FileManager.default
        let lib = folder
        let external = lib.appending(path: "external")
        let framework = external.appending(path: "D3DMetal.framework")
        try fm.createDirectory(at: framework.appending(path: "Versions/A/Resources"), withIntermediateDirectories: true)
        if let version {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try plist.write(to: framework.appending(path: "Versions/A/Resources/Info.plist"))
        }
        try Data("dylib".utf8).write(to: external.appending(path: "libd3dshared.dylib"))
        let pe = lib.appending(path: "wine/x86_64-windows")
        try fm.createDirectory(at: pe, withIntermediateDirectories: true)
        var image = Data(repeating: 0, count: 0x80)
        image[0] = 0x4d
        image[1] = 0x5a
        if builtin { image.replaceSubrange(0x40 ..< 0x51, with: Array("Wine builtin DLL".utf8) + [0]) }
        for name in WinecxD3DMetal.forwarders {
            try image.write(to: pe.appending(path: name))
        }
        return lib
    }

    private func makeEngineRoot(in folder: URL) throws -> URL {
        let root = folder.appending(path: "CrossOver")
        let external = root.appending(path: "lib/external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("winecx readme".utf8).write(to: external.appending(path: "README"))
        return root
    }

    private func destination(of link: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))
    }

    @Test("A Game Porting Toolkit is found in each shape users have it in, user folder first")
    func locatesPayloadShapes() throws {
        let base = try makeDirectory("shapes")
        defer { try? FileManager.default.removeItem(at: base) }

        let lib = try makePayload(in: base.appending(path: "plain"))
        let redist = try makePayload(in: base.appending(path: "volume/redist/lib"))
        let app = try makePayload(in: base.appending(path: "GPTK.app/Contents/Resources/wine/lib"))
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(WinecxD3DMetal.payloadRoot(under: lib) == lib)
        #expect(WinecxD3DMetal.payloadRoot(under: base.appending(path: "volume"))?.standardizedFileURL
            == redist.standardizedFileURL)
        #expect(WinecxD3DMetal.payloadRoot(under: base.appending(path: "GPTK.app"))?.standardizedFileURL
            == app.standardizedFileURL)
        #expect(WinecxD3DMetal.payloadRoot(under: empty) == nil)

        let found = try #require(WinecxD3DMetal.locate(in: [empty, base.appending(path: "volume"), lib]))
        #expect(found.libRoot.standardizedFileURL == redist.standardizedFileURL)
        #expect(found.version == "3.0")

        let roots = WinecxD3DMetal.searchRoots(home: URL(filePath: "/Users/u"))
        #expect(roots.map { $0.path(percentEncoded: false) } == [
            "/Users/u/Library/Application Support/notproton/gptk/",
            "/Applications/Game Porting Toolkit.app/",
            "/Users/u/Applications/Game Porting Toolkit.app/",
        ])
    }

    @Test("Forwarders without the builtin marker, or a payload missing pieces, are refused")
    func rejectsIncompletePayloads() throws {
        let base = try makeDirectory("reject")
        defer { try? FileManager.default.removeItem(at: base) }

        let native = try makePayload(in: base.appending(path: "native"), builtin: false)
        #expect(!WinecxD3DMetal.isPayloadRoot(native))

        let partial = try makePayload(in: base.appending(path: "partial"))
        try FileManager.default.removeItem(at: partial.appending(path: "wine/x86_64-windows/d3d12.dll"))
        #expect(!WinecxD3DMetal.isPayloadRoot(partial))

        let noFramework = try makePayload(in: base.appending(path: "noframework"))
        try FileManager.default.removeItem(at: noFramework.appending(path: "external/D3DMetal.framework"))
        #expect(!WinecxD3DMetal.isPayloadRoot(noFramework))

        #expect(WinecxD3DMetal.locate(in: [native, partial, noFramework]) == nil)
    }

    @Test("Linking writes only symlinks into the user's copy, then the marker")
    func linksPayload() throws {
        let base = try makeDirectory("link")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        let payload = try #require(WinecxD3DMetal.locate(in: [lib]))
        try WinecxD3DMetal.link(payload, root: root)

        #expect(WinecxD3DMetal.isLinked(root: root))
        let source = lib.standardizedFileURL
        #expect(try destination(of: root.appending(path: "lib/external/libd3dshared.dylib"))
            == source.appending(path: "external/libd3dshared.dylib").path(percentEncoded: false))
        #expect(try destination(of: root.appending(path: "lib/external/D3DMetal.framework"))
            == source.appending(path: "external/D3DMetal.framework").path(percentEncoded: false))
        for name in WinecxD3DMetal.forwarders {
            let pe = root.appending(path: "lib/notproton-backends/d3dmetal/x86_64-windows/\(name)")
            #expect(try destination(of: pe)
                == source.appending(path: "wine/x86_64-windows/\(name)").path(percentEncoded: false))
            let unix = root.appending(
                path: "lib/notproton-backends/d3dmetal/x86_64-unix/\((name as NSString).deletingPathExtension).so")
            #expect(try destination(of: unix) == "../../../external/libd3dshared.dylib")
            // The relative link has to land on the shared library through lib/external.
            #expect(try Data(contentsOf: unix) == Data("dylib".utf8))
        }
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))
        // Nothing lands in lib/wine.
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/wine").path(percentEncoded: false)))

        let marker = try String(contentsOf: WinecxD3DMetal.enabledMarker(in: root), encoding: .utf8)
        #expect(marker.contains("version=3.0\n"))
        #expect(marker.contains("libd3dshared=lib/external/libd3dshared.dylib\n"))
        #expect(marker.contains("dllpath=lib/notproton-backends/d3dmetal\n"))

        // Relinking is idempotent.
        try WinecxD3DMetal.link(payload, root: root)
        #expect(WinecxD3DMetal.isLinked(root: root))
    }

    @Test("A Game Porting Toolkit that went away reads as unlinked, and unlinking keeps winecx's files")
    func unlinksCleanly() throws {
        let base = try makeDirectory("unlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        try WinecxD3DMetal.link(try #require(WinecxD3DMetal.locate(in: [lib])), root: root)

        try fm.removeItem(at: lib)
        #expect(!WinecxD3DMetal.isLinked(root: root))

        WinecxD3DMetal.unlink(root: root)
        #expect(!fm.fileExists(atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/notproton-backends/d3dmetal").path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: root.appending(path: "lib/external/libd3dshared.dylib").path(percentEncoded: false))) == nil)
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))

        // A real file in lib/external is never removed, only links are.
        let real = root.appending(path: "lib/external/libd3dshared.dylib")
        try Data("placed by hand".utf8).write(to: real)
        WinecxD3DMetal.unlink(root: root)
        #expect(fm.fileExists(atPath: real.path(percentEncoded: false)))
    }

    @Test("Refresh never writes into a tree that is not WineCX")
    func refreshOnlyTouchesWinecx() throws {
        let base = try makeDirectory("refresh")
        defer { try? FileManager.default.removeItem(at: base) }

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("crossover loader".utf8).write(to: loader)

        #expect(WinecxD3DMetal.refresh(root: root, roots: [lib]) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "lib/notproton-backends").path(percentEncoded: false)))
    }

    // MARK: - Against the real archive

    // Runs once the archive is in NotProton's cache, or at NOTPROTON_WINECX_ARCHIVE.
    private static var realArchive: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["NOTPROTON_WINECX_ARCHIVE"].map { URL(filePath: $0) },
            FreeEngineWinecx.downloads.appending(path: FreeEngineWinecx.current.archive),
        ].compactMap { $0 }
        return candidates.first { Digest.sha256IfPresent($0) == FreeEngineWinecx.current.sha256 }
    }

    @Test("Unpacking the real archive yields a free, patchable engine with the runtime contract")
    func unpacksRealArchive() throws {
        guard let archive = Self.realArchive else { return }
        let fm = FileManager.default
        let base = try makeDirectory("real")
        defer { try? fm.removeItem(at: base) }

        let engines = base.appending(path: "engines")
        let gptk = try makePayload(in: base.appending(path: "gptk"))
        let install = try FreeEngineWinecx.unpack(
            archive, release: FreeEngineWinecx.current, engines: engines, gptkRoots: [gptk]
        )
        guard case .supported(let build) = install.support else {
            Issue.record("unpacked engine is \(install.support)")
            return
        }
        let root = install.crossOverRoot
        #expect(build.id == FreeEngineWinecx.current.build)
        #expect(install.isFree)
        #expect(FreeEngineWinecx.isInstalled(engines: engines))
        #expect(FreeEngineWinecx.hasBackends(root: root))
        #expect(CrossOverLicense.check(crossOverRoot: root).licensed)
        try RunnerInstaller.verifyClone(build: build, root: root)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: root, arch: patch.arch)
            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }

        // lib/wine keeps Wine's own Direct3D: none of it is a backend copy.
        let pinned = Set(FreeEngineWinecx.current.backends.map(\.sha256))
        for arch in ["x86_64-windows", "i386-windows"] {
            for name in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d12.dll"] {
                let stock = root.appending(path: "lib/wine/\(arch)/\(name)")
                let hash = try #require(Digest.sha256IfPresent(stock), "\(arch)/\(name)")
                #expect(!pinned.contains(hash), "\(arch)/\(name)")
            }
        }
        // DXMT's builtin half and the unix loader winecx's DXMT and D3DMetal hooks live in.
        #expect(fm.fileExists(atPath: root.appending(path: "lib/wine/x86_64-unix/winemetal.so").path(percentEncoded: false)))
        #expect(try String(contentsOf: FreeEngineWinecx.msyncMarker(in: root), encoding: .utf8) == "winecx-11.15\n")

        // The fixture GPTK was linked into the real tree, through winecx's own lib/external.
        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))
        WinecxD3DMetal.unlink(root: root)
        #expect(!WinecxD3DMetal.isLinked(root: root))
        #expect(WinecxD3DMetal.refresh(root: root, roots: [gptk]) != nil)
        try fm.removeItem(at: gptk)
        #expect(WinecxD3DMetal.refresh(root: root, roots: [gptk]) == nil)
        #expect(!fm.fileExists(atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
    }
}
