// The second free engine: WineCX, CodeWeavers' LGPL CrossOver 26.3 Wine changes rebased
// onto wine-11.15 by dappermint (github.com/dappermint/winecx, wine1115 branch) and built
// into a Whisky runtime by dappermint/winecx-gptk's CI. Over the WineHQ engine it adds
// msync and the CrossOver hooks Apple's D3DMetal needs, and it carries DXMT and DXVK as
// backends a game opts into instead of replacing Wine's own Direct3D. docs/WINECX.md.

import Foundation

struct WinecxBackendFile: Sendable, Equatable {
    // Path inside the archive, below Libraries/.
    let source: String
    // Path below lib/notproton-backends/ in the engine.
    let destination: String
    let sha256: String
}

struct WinecxRelease: Sendable {
    let build: String
    // The winecx-gptk runtime version, which is what its WhiskyWineVersion.plist carries.
    let runtime: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    // Path of the Wine tree inside the archive.
    let wineTree: String
    let backends: [WinecxBackendFile]
}

enum FreeEngineWinecx {

    static let step = "Download free WineCX engine"

    // runtime 4.5.125 is the last wine1115 build (winecx 5b45f45, built from winecx-gptk
    // 7a0349b, minos 26.0). It is the 11.15 the bridge components are built against, and
    // the only 11.15 runtime with the msync spin fixes. The same bytes are mirrored on
    // dappermint/Whisky, which is what Whisky itself downloads.
    static let current = WinecxRelease(
        build: "winecx-11.15",
        runtime: "4.5.125",
        archive: "Libraries.tar.gz",
        sha256: "6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87",
        bases: [
            URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.5.125")!,
            URL(string: "https://github.com/dappermint/Whisky/releases/download/v4.5.125")!,
        ],
        bundleName: "WineCX 11.15.app",
        wineTree: "Libraries/Wine",
        // The archive's DXMT 0.80 frontends already have the builtin marker stripped, so
        // they load as native DLLs from a prefix. nvapi64 and nvngx are left out for the
        // reason FreeEngine gives. winemetal stays where the archive put it, a builtin in
        // lib/wine beside its unix half. The DXVK-macOS 1.10.3 repack ships no dxgi.
        backends: [
            WinecxBackendFile(source: "DXMT/x64/d3d10core.dll", destination: "dxmt/x86_64-windows/d3d10core.dll",
                              sha256: "24ca320249f0683d0bded170ef135f430c5b0f310b461e68108ee3c13e7e0aac"),
            WinecxBackendFile(source: "DXMT/x64/d3d11.dll", destination: "dxmt/x86_64-windows/d3d11.dll",
                              sha256: "8d4842aaf4fd3de3f115d1f51da13930f27764dad1bb217fc28e7d154c1612b3"),
            WinecxBackendFile(source: "DXMT/x64/dxgi.dll", destination: "dxmt/x86_64-windows/dxgi.dll",
                              sha256: "a9686960d8341a034cdfbb46015592b1d407922f4b2686274b7865bbc4c0683c"),
            WinecxBackendFile(source: "DXMT/x32/d3d10core.dll", destination: "dxmt/i386-windows/d3d10core.dll",
                              sha256: "e867d24efe319bbc5e54da8732cc67d4bf975a291a57782d0cf8517af11fca22"),
            WinecxBackendFile(source: "DXMT/x32/d3d11.dll", destination: "dxmt/i386-windows/d3d11.dll",
                              sha256: "7002dac2b38c757109c2a661832d90f391a0f5cee9bda469cae539de75ff6eec"),
            WinecxBackendFile(source: "DXMT/x32/dxgi.dll", destination: "dxmt/i386-windows/dxgi.dll",
                              sha256: "4ca0246cc6aac9f1d36ac4da495f31adca33c5a02bb42b3231bd84b940514fdd"),
            WinecxBackendFile(source: "DXVK/x64/d3d10core.dll", destination: "dxvk/x86_64-windows/d3d10core.dll",
                              sha256: "0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e"),
            WinecxBackendFile(source: "DXVK/x64/d3d11.dll", destination: "dxvk/x86_64-windows/d3d11.dll",
                              sha256: "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4"),
            WinecxBackendFile(source: "DXVK/x32/d3d10core.dll", destination: "dxvk/i386-windows/d3d10core.dll",
                              sha256: "2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327"),
            WinecxBackendFile(source: "DXVK/x32/d3d11.dll", destination: "dxvk/i386-windows/d3d11.dll",
                              sha256: "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0"),
        ]
    )

    // Appended to SupportedRunners.all. The hash-pinned loader is what makes it free, so a
    // CrossOver install can never be taken for it.
    static let runnerBuild = RunnerBuild(
        bundleVersion: "winecx-11.15",
        releaseVersion: "WineCX 11.15",
        flavor: nil,
        loaderSHA256: "a4b677428a6834f97f536a84d32c5da982c9a449e5d483c6be3d1c9b8f308998",
        cleanNtdll: [
            .x86_64Windows: "5710d16382c7a822ed8b1cba58d95fd86fe01905f039c296ca7224abff8f98e8",
            .i386Windows: "e1b208073c804a443e64ada577899d96a5c8eaee435813e4a30e0d143bca6e3c",
        ],
        patchedNtdll: [
            .x86_64Windows: "4efd956e573726777827cddaa89ef3b7f72d6cfd7b8e2049e41f5f5bdf4a6306",
            .i386Windows: "23ee72664f172d38d76ecb8969d5c5af7e6828864dfe298338ed0e773910bc5d",
        ],
        tools: [
            CompatTool(name: "notproton-winecx", flavor: .rosetta, display: "WineCX 11.15 (msync, D3DMetal)"),
        ],
        isFree: true
    )

    // Appended to NtdllPatcher.byBuild. From ntdll-patch/resolve.py on the archive's ntdlls,
    // payloads from build.sh and build32.sh with the variant winecx-11.15. The x86_64 hook is
    // the CrossOver one (cmp [rsp+0xf0], 0), and its .text padding holds the detour; the
    // i386 padding does not, so that one gets the appended section.
    static let ntdllPatches: [NtdllPatch] = [
        NtdllPatch(
            arch: .x86_64Windows,
            payloadResource: "detour2-winecx-11.15",
            payloadSHA256: "fde56854b9a7a32da19babe2427d19ff6a6b83de1917fe8d32aaddd2991fc6b9",
            caveRVA: 0x82b20,
            payloadRVA: 0x82b20,
            hooks: [
                NtdllHook(rva: 0x52e43,
                          stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]),
            ],
            caveSize: 1248,
            cavePad: 0x00,
            machine: 0x8664,
            magic: 0x20b,
            imageBase: 0x1_7000_0000
        ),
        NtdllPatch(
            arch: .i386Windows,
            payloadResource: "detour32-winecx-11.15",
            payloadSHA256: "37daf5f795535df91bc8fcbd356f22f4fd1ab379ec4acc97ddff44037d265556",
            caveRVA: 0xb9000,
            payloadRVA: 0xb9000,
            hooks: [
                NtdllHook(rva: 0x4f7c0, stolen: [0xf6, 0x45, 0xb4, 0x02, 0x75, 0x29]),
            ],
            caveSize: 0x1000,
            cavePad: 0x00,
            machine: 0x14c,
            magic: 0x10b,
            imageBase: 0x7bc0_0000,
            placement: .section
        ),
    ]

    // Runtime contract with compat_run.sh: the engine root says it can run msync, and the
    // backends sit outside lib/wine so Wine's own Direct3D stays the builtin.
    static let backendsPath = "lib/notproton-backends"
    static let msyncMarkerPath = ".notproton-msync"

    static var downloads: URL {
        SupportPaths.home.appending(
            path: "Library/Caches/\(SupportPaths.supportDirName)/engines/winecx-\(current.runtime)",
            directoryHint: .isDirectory
        )
    }

    static func bundle(for release: WinecxRelease = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: WinecxRelease = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return hasBackends(root: install.crossOverRoot, release: release)
    }

    static func hasBackends(root: URL, release: WinecxRelease = current) -> Bool {
        release.backends.allSatisfy { file in
            Digest.sha256IfPresent(backend(file.destination, in: root)) == file.sha256
        } && FileManager.default.fileExists(atPath: msyncMarker(in: root).path(percentEncoded: false))
    }

    static func backend(_ path: String, in root: URL) -> URL {
        root.appending(path: "\(backendsPath)/\(path)")
    }

    static func msyncMarker(in root: URL) -> URL {
        root.appending(path: msyncMarkerPath)
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking WineCX"
            }
        }
    }

    static func install(
        _ release: WinecxRelease = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        return try unpack(archive, release: release, engines: engines)
    }

    static func unpack(
        _ archive: URL,
        release: WinecxRelease,
        engines: URL,
        gptkRoots: [URL] = WinecxD3DMetal.searchRoots()
    ) throws -> CrossOverInstall {
        let fm = FileManager.default
        let target = bundle(for: release, engines: engines)
        let staging = engines.appending(path: ".\(release.bundleName).new", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let extracted = staging.appending(path: "extract", directoryHint: .isDirectory)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try untar(archive, into: extracted)

        let wine = extracted.appending(path: release.wineTree, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: wine.appending(path: "lib/wine").path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: "\(release.archive) has no Wine tree at \(release.wineTree).")
        }

        let shaped = staging.appending(path: release.bundleName, directoryHint: .isDirectory)
        let root = SupportPaths.crossOverRoot(inBundle: shaped)
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: wine, to: root)

        let libraries = wine.deletingLastPathComponent()
        for file in release.backends {
            let source = libraries.appending(path: file.source)
            guard Digest.sha256IfPresent(source) == file.sha256 else {
                throw StepFailure(step: step, detail: "\(release.archive) has no pinned \(file.source).")
            }
            let destination = backend(file.destination, in: root)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
        try Data("\(release.build)\n".utf8).write(to: msyncMarker(in: root))

        // The winecx tree keeps its unix loader beside the unix libraries the way
        // CrossOver does, so like the WineHQ engine it needs no reshaping inside.
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winehq.wine.notproton.winecx",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "winecx-", with: ""),
            "CFBundleVersion": release.build,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: shaped.appending(path: "Contents/Info.plist"))
        RunnerInstaller.scrubDownloadMarkers(at: shaped)

        let install = CrossOverSource.inspect(bundle: shaped)
        guard case .supported(let build) = install.support, build.id == release.build else {
            throw StepFailure(
                step: step,
                detail: "The unpacked Wine loader is not the \(release.build) build NotProton was made for."
            )
        }

        // Only links, and only to a Game Porting Toolkit the user installed. An engine
        // without one is complete, it just has no D3DMetal.
        WinecxD3DMetal.refresh(root: install.crossOverRoot, roots: gptkRoots)

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    private static func untar(_ archive: URL, into directory: URL) throws {
        let result = try Shell.run("/usr/bin/tar", [
            "-xf", archive.path(percentEncoded: false), "-C", directory.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Unpacking \(archive.lastPathComponent) failed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
