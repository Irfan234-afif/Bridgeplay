// Links a Game Porting Toolkit the user installed into a WineCX engine, so D3DMetal can
// run on it. Nothing of Apple's is copied or shipped: every entry is a symlink into the
// user's own copy, and the marker compat_run.sh reads is written only once all of them
// are in place. Apple's payload is the redist/lib tree: external/ (D3DMetal.framework and
// libd3dshared.dylib) and builtin-marked PE forwarders under wine/x86_64-windows. There
// is no i386 half, so D3DMetal is 64-bit only.
//
// Layout in the engine root, beside the stock Direct3D that lib/wine keeps:
//   lib/external/{D3DMetal.framework,libd3dshared.dylib}  -> the user's external/
//       winecx's own lib/external, where its build expects the payload. Also the
//       CX_APPLEGPTK_LIBD3DSHARED_PATH winecx's ntdll dlopens for non-native code regions.
//   lib/notproton-backends/d3dmetal/x86_64-windows/<forwarder> -> the user's forwarder
//   lib/notproton-backends/d3dmetal/x86_64-unix/<name>.so -> ../../../external/libd3dshared.dylib
//       Wine takes a builtin's unix half from the x86_64-unix beside the directory the PE
//       came from. A symlink rather than a copy, so libd3dshared's @loader_path rpath
//       still lands beside D3DMetal.framework.
//   lib/notproton-backends/d3dmetal.enabled

import Foundation

enum WinecxD3DMetal {

    static let forwarders = ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]
    static let sharedLibrary = "libd3dshared.dylib"
    static let framework = "D3DMetal.framework"

    static let externalPath = "lib/external"
    static let backendPath = "\(FreeEngineWinecx.backendsPath)/d3dmetal"
    static let enabledMarkerPath = "\(FreeEngineWinecx.backendsPath)/d3dmetal.enabled"
    static let unixLinkDestination = "../../../external/\(sharedLibrary)"

    struct Payload: Sendable, Equatable {
        // The folder holding external/ and wine/.
        let libRoot: URL
        // D3DMetal.framework's CFBundleShortVersionString, when it has one.
        let version: String?
    }

    // Where the user puts a copy by hand: GPTK's redist/lib, or the whole redist folder.
    static var userFolder: URL {
        SupportPaths.support.appending(path: "gptk", directoryHint: .isDirectory)
    }

    // In order of preference. The user's own folder wins over an installed app.
    static func searchRoots(home: URL = SupportPaths.home) -> [URL] {
        [
            home.appending(path: "Library/Application Support/\(SupportPaths.supportDirName)/gptk",
                           directoryHint: .isDirectory),
            // Gcenx's game-porting-toolkit cask installs here.
            URL(filePath: "/Applications/Game Porting Toolkit.app", directoryHint: .isDirectory),
            home.appending(path: "Applications/Game Porting Toolkit.app", directoryHint: .isDirectory),
        ]
    }

    // Accepts the lib folder itself, a redist folder, an evaluation-environment volume
    // root, or a Game Porting Toolkit.app.
    static func payloadRoot(under url: URL) -> URL? {
        [
            url,
            url.appending(path: "lib"),
            url.appending(path: "redist/lib"),
            url.appending(path: "Contents/Resources/wine/lib"),
        ].first(where: isPayloadRoot)
    }

    static func isPayloadRoot(_ lib: URL) -> Bool {
        let fm = FileManager.default
        let external = lib.appending(path: "external")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: external.appending(path: sharedLibrary).path(percentEncoded: false)),
              fm.fileExists(atPath: external.appending(path: framework).path(percentEncoded: false),
                            isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return forwarders.allSatisfy { isBuiltin(lib.appending(path: "wine/x86_64-windows/\($0)")) }
    }

    // Apple's forwarders are winebuild builtins, and only a builtin gets a unix half, so a
    // forwarder without the marker could never reach D3DMetal. Wine compares the 17 bytes
    // at 0x40 against the marker and its terminator.
    static func isBuiltin(_ dll: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x51), head.count == 0x51 else { return false }
        let marker = Array("Wine builtin DLL".utf8) + [0]
        return Array(head[0x40 ..< 0x51]) == marker
    }

    static func locate(in roots: [URL] = searchRoots()) -> Payload? {
        for root in roots {
            guard let lib = payloadRoot(under: root) else { continue }
            return Payload(libRoot: lib, version: version(ofExternal: lib.appending(path: "external")))
        }
        return nil
    }

    static func version(ofExternal external: URL) -> String? {
        let bundle = external.appending(path: framework)
        for plist in [bundle.appending(path: "Versions/A/Resources/Info.plist"),
                      bundle.appending(path: "Resources/Info.plist")] {
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }

    static func enabledMarker(in root: URL) -> URL { root.appending(path: enabledMarkerPath) }

    // Every link the layout needs, as (link, destination it must resolve to).
    static func links(for payload: Payload, root: URL) -> [(link: URL, target: String)] {
        let source = payload.libRoot.standardizedFileURL
        let external = root.appending(path: externalPath)
        let backend = root.appending(path: backendPath)
        var links: [(link: URL, target: String)] = [
            (external.appending(path: framework),
             source.appending(path: "external/\(framework)").path(percentEncoded: false)),
            (external.appending(path: sharedLibrary),
             source.appending(path: "external/\(sharedLibrary)").path(percentEncoded: false)),
        ]
        for name in forwarders {
            links.append((backend.appending(path: "x86_64-windows/\(name)"),
                          source.appending(path: "wine/x86_64-windows/\(name)").path(percentEncoded: false)))
            let unix = (name as NSString).deletingPathExtension + ".so"
            links.append((backend.appending(path: "x86_64-unix/\(unix)"), unixLinkDestination))
        }
        return links
    }

    static func link(_ payload: Payload, root: URL) throws {
        let fm = FileManager.default
        unlink(root: root)
        do {
            for entry in links(for: payload, root: root) {
                try fm.createDirectory(at: entry.link.deletingLastPathComponent(), withIntermediateDirectories: true)
                if isSymlink(entry.link) { try fm.removeItem(at: entry.link) }
                try fm.createSymbolicLink(atPath: entry.link.path(percentEncoded: false),
                                          withDestinationPath: entry.target)
            }
            guard linksResolve(root: root) else {
                throw StepFailure(step: FreeEngineWinecx.step,
                                  detail: "The Game Porting Toolkit links in the engine do not resolve.")
            }
            let marker = [
                "source=\(payload.libRoot.standardizedFileURL.path(percentEncoded: false))",
                "version=\(payload.version ?? "unknown")",
                "libd3dshared=\(externalPath)/\(sharedLibrary)",
                "dllpath=\(backendPath)",
            ].joined(separator: "\n") + "\n"
            try Data(marker.utf8).write(to: enabledMarker(in: root))
        } catch {
            unlink(root: root)
            throw error
        }
    }

    // Removes what link made and nothing else: the marker goes first so a consumer never
    // sees it over a half-removed layout, and lib/external keeps winecx's own README.
    static func unlink(root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: enabledMarker(in: root))
        try? fm.removeItem(at: root.appending(path: backendPath))
        for name in [framework, sharedLibrary] {
            let link = root.appending(path: "\(externalPath)/\(name)")
            if isSymlink(link) { try? fm.removeItem(at: link) }
        }
    }

    static func isLinked(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: enabledMarker(in: root).path(percentEncoded: false))
            && linksResolve(root: root)
    }

    // fileExists follows links, so a GPTK that was moved or deleted shows up here.
    private static func linksResolve(root: URL) -> Bool {
        let backend = root.appending(path: backendPath)
        let external = root.appending(path: externalPath)
        let paths = [external.appending(path: framework), external.appending(path: sharedLibrary)]
            + forwarders.flatMap { name in
                [backend.appending(path: "x86_64-windows/\(name)"),
                 backend.appending(path: "x86_64-unix/\((name as NSString).deletingPathExtension).so")]
            }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    // Links the first Game Porting Toolkit found, or clears the layout when there is none
    // or the old one went away. Only ever touches a WineCX root: a CrossOver bundle has
    // its own D3DMetal and is never written to.
    @discardableResult
    static func refresh(root: URL, roots: [URL] = searchRoots()) -> Payload? {
        guard isWinecx(root: root) else { return nil }
        guard let payload = locate(in: roots) else {
            unlink(root: root)
            return nil
        }
        do {
            try link(payload, root: root)
            AppLog.note("winecx: linked D3DMetal \(payload.version ?? "unknown") from "
                + payload.libRoot.path(percentEncoded: false))
            return payload
        } catch {
            AppLog.note("winecx: could not link D3DMetal: \(error.localizedDescription)")
            return nil
        }
    }

    static func isWinecx(root: URL) -> Bool {
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        return Digest.sha256IfPresent(loader) == FreeEngineWinecx.runnerBuild.loaderSHA256
    }
}
