// Downloads a free WineHQ build and lays it out like a CrossOver bundle, so the
// rest of the runner setup treats it as just another source to clone from.

import Foundation

struct FreeEngineRelease: Sendable {
    let build: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    // Path of the Wine tree inside the archive.
    let wineTree: String
    let renderer: RendererRelease
    // sha256 of the winemac.so NotProton ships for this build (winemac-patch/), which
    // exports the macdrv entry points DXMT needs to put Metal into a window.
    let macDriver: String
    // arch/file -> sha256 of Wine's own file, which stays in lib/wine untouched.
    let stock: [String: String]
    // DXVK-macOS, staged beside DXMT for games that do better on it.
    let dxvk: BackendRelease
}

// DXMT replaces Wine's own D3D10/11 and DXGI. Wine's wined3d goes through macOS
// OpenGL 4.1, which tops out below feature level 11 and so fails any Unreal or
// Unity game that needs it, and DXVK pays for a second translation through
// MoltenVK. DXMT goes to Metal directly, the way D3DMetal does, and is MIT licensed.
struct RendererRelease: Sendable {
    let name: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let tree: String
    // Path inside the archive tree -> sha256. The winemetal pair goes into lib/wine,
    // where the unix half and its PE stub are found by the loader; the D3D DLLs go to
    // FreeEngine.dxmtDirectory, so lib/wine keeps Wine's own.
    let files: [String: String]

    func installPath(of path: String) -> String {
        path.hasSuffix("/winemetal.dll") || path.hasSuffix("/winemetal.so")
            ? "lib/wine/\(path)" : "\(FreeEngine.dxmtDirectory)/\(path)"
    }
}

// A set of D3D DLLs the launcher can swap in per game. Nothing here is loaded by default.
struct BackendRelease: Sendable {
    let name: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let tree: String
    // Path inside the archive tree -> sha256, installed at FreeEngine.dxvkDirectory/<path>.
    let files: [String: String]
}

enum FreeEngine {

    static let step = "Download free Wine engine"

    // Gcenx's WineHQ packages. 11.15 is the Wine the bridge components are built
    // against (bridge/setup-wine-tree.sh), so the unix halves speak its protocol.
    static let current = FreeEngineRelease(
        build: "winehq-11.15",
        archive: "wine-devel-11.15-osx64.tar.xz",
        sha256: "3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2",
        bases: [URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15")!],
        bundleName: "WineHQ 11.15.app",
        wineTree: "Wine Devel.app/Contents/Resources/wine",
        renderer: RendererRelease(
            name: "DXMT 0.80",
            archive: "dxmt-v0.80-builtin.tar.gz",
            sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
            bases: [URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80")!],
            tree: "v0.80",
            // nvapi64 and nvngx are left out: they only serve DLSS to MetalFX, and an
            // nvapi that answers makes some games take NVIDIA-only paths.
            files: [
                "x86_64-unix/winemetal.so": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
                "x86_64-windows/d3d10core.dll": "833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26",
                "x86_64-windows/d3d11.dll": "7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47",
                "x86_64-windows/dxgi.dll": "fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544",
                "x86_64-windows/winemetal.dll": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
                "i386-windows/d3d10core.dll": "c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f",
                "i386-windows/d3d11.dll": "9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d",
                "i386-windows/dxgi.dll": "7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319",
                "i386-windows/winemetal.dll": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3",
            ]
        ),
        macDriver: "68d1c10cb4ec80beb2e97dcb8df5f81768f4f6e62848932d6bee5270dcf54982",
        stock: [
            "x86_64-windows/d3d10core.dll": "ff08e21a331e4160779ae140b0fd67c25f1557803b0f865467025a55e6133800",
            "x86_64-windows/d3d11.dll": "66d08df71bdb897b55d6f5d12f44b90846dec362641baab2100c0cdf6615c809",
            "x86_64-windows/d3d12.dll": "7dfa70d5b9ac50541c81801d8539be4cd31f37079ea1d93a495fe70c93f95d9a",
            "x86_64-windows/dxgi.dll": "ed8d22612d121415063e54283e7284ae294a07a6b6d83b65dcd91abaadde2e49",
            "i386-windows/d3d10core.dll": "7f9d10eaf361d7d7ad0a76fcedda037014184df9abe3ef0a65c4966a74bcd98d",
            "i386-windows/d3d11.dll": "9f7a4f6ed76c75e902b8f27c45ba9a8d7cadb3205d3e4ab16a6f8a29aedfd30e",
            "i386-windows/d3d12.dll": "501a94c7f2689f996b658ceee101b5b7bd44845dfc53a9336b4ece848ed343e1",
            "i386-windows/dxgi.dll": "5e7310cc1c80650a467a4022e924d34ec07ce58933383ad06f530a61c82afc9d",
        ],
        // Gcenx's repack carries d3d10core and d3d11 only: it drops dxgi and d3d9 as
        // unwanted on macOS, so DXVK games run on Wine's stock dxgi.
        dxvk: BackendRelease(
            name: "DXVK-macOS 1.10.3",
            archive: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
            sha256: "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00",
            bases: [URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack")!],
            tree: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin",
            files: [
                "x86_64-windows/d3d10core.dll": "225562562050d9fae1d4d5d2ca0537020bac268c80dec9aa0633dc0d338a2840",
                "x86_64-windows/d3d11.dll": "173980cb6c51fdd53dc37b9a17f0de7c5dfdebda18f52059aa7d5a6f1871299c",
                "i386-windows/d3d10core.dll": "9e0202437af13a6d0acdb992954321f00a641b2eb98897908c41635ffddc1fc8",
                "i386-windows/d3d11.dll": "2173b081a8660dd70a089dac875a829da6cd1a6230b23fd1daa2a7d7baa1cb03",
            ]
        )
    )

    static let macDriverPath = "lib/wine/x86_64-unix/winemac.so"

    // Wine keeps its own dxgi, d3d11 and d3d10core in lib/wine. The launcher picks a
    // backend per game from these, so no game is forced onto one by the engine itself.
    static let backendsDirectory = "lib/notproton-backends"
    static let dxmtDirectory = "\(backendsDirectory)/dxmt"
    static let dxvkDirectory = "\(backendsDirectory)/dxvk"

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/engines")
    }

    static func bundle(for release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return hasRenderer(root: install.crossOverRoot, release: release)
    }

    // Every file the engine should carry, relative to its root, with its sha256: Wine's
    // stock D3D DLLs, DXMT's winemetal pair, both backends and the patched winemac.so.
    static func expectedFiles(_ release: FreeEngineRelease = current) -> [String: String] {
        var table: [String: String] = [macDriverPath: release.macDriver]
        for (path, hash) in release.stock { table["lib/wine/\(path)"] = hash }
        for (path, hash) in release.renderer.files { table[release.renderer.installPath(of: path)] = hash }
        for (path, hash) in release.dxvk.files { table["\(dxvkDirectory)/\(path)"] = hash }
        return table
    }

    // Files that are absent or differ from the pinned hash.
    static func layoutProblems(root: URL, release: FreeEngineRelease = current) -> [String] {
        expectedFiles(release).filter { path, hash in
            Digest.sha256IfPresent(root.appending(path: path)) != hash
        }.keys.sorted()
    }

    // An engine unpacked before the backends were split out still runs, but it needs
    // the new layout before the launcher can choose a renderer per game.
    static func hasRenderer(root: URL, release: FreeEngineRelease = current) -> Bool {
        layoutProblems(root: root, release: release).isEmpty
    }

    // The first layout baked DXMT's dxgi, d3d11 and d3d10core over Wine's in lib/wine.
    static func hasLegacyLayout(root: URL, release: FreeEngineRelease = current) -> Bool {
        release.renderer.files.contains { path, hash in
            !path.hasSuffix("winemetal.dll") && !path.hasSuffix("winemetal.so")
                && Digest.sha256IfPresent(root.appending(path: "lib/wine/\(path)")) == hash
        }
    }

    // Upstream Wine hides the macdrv functions DXMT looks up, so without this DXMT can
    // create a device but no swapchain, and games abort on their first window.
    static func installMacDriver(root: URL, release: FreeEngineRelease) throws {
        guard let source = Bundle.module.url(forResource: "winemac-\(release.build)", withExtension: "so"),
              Digest.sha256IfPresent(source) == release.macDriver
        else {
            throw StepFailure(step: step, detail: "NotProton is missing its winemac.so for \(release.build).")
        }
        let destination = root.appending(path: macDriverPath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking Wine"
            }
        }
    }

    static func install(
        _ release: FreeEngineRelease = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        let renderer = try await PinnedDownload.obtain(
            file: release.renderer.archive, sha256: release.renderer.sha256, bases: release.renderer.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        let dxvk = try await PinnedDownload.obtain(
            file: release.dxvk.archive, sha256: release.dxvk.sha256, bases: release.dxvk.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        // The engine is always rebuilt from the pinned archives, so an engine from the
        // first layout (DXMT over Wine's DLLs) is replaced rather than patched in place.
        return try unpack(archive, renderer: renderer, dxvk: dxvk, release: release, engines: engines)
    }

    static func unpack(
        _ archive: URL, renderer: URL?, dxvk: URL? = nil, release: FreeEngineRelease, engines: URL
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

        if let renderer {
            try untar(renderer, into: extracted)
            let tree = extracted.appending(path: release.renderer.tree, directoryHint: .isDirectory)
            for (path, hash) in release.renderer.files.sorted(by: { $0.key < $1.key }) {
                let source = tree.appending(path: path)
                guard Digest.sha256IfPresent(source) == hash else {
                    throw StepFailure(step: step, detail: "\(release.renderer.archive) has no pinned \(path).")
                }
                try place(source, at: root.appending(path: release.renderer.installPath(of: path)))
            }
            try installMacDriver(root: root, release: release)
        }

        if let dxvk {
            try untar(dxvk, into: extracted)
            let tree = extracted.appending(path: release.dxvk.tree, directoryHint: .isDirectory)
            for (path, hash) in release.dxvk.files.sorted(by: { $0.key < $1.key }) {
                let source = tree.appending(path: path)
                guard Digest.sha256IfPresent(source) == hash else {
                    throw StepFailure(step: step, detail: "\(release.dxvk.archive) has no pinned \(path).")
                }
                try place(source, at: root.appending(path: "\(dxvkDirectory)/\(path)"))
            }
        }

        // WineHQ already keeps its unix loader beside the unix libraries, where
        // CrossOver keeps its own, so the Wine tree needs no reshaping inside.
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winehq.wine.notproton",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "winehq-", with: ""),
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

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    private static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
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
