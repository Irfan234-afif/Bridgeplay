import AppKit
import Foundation
import Observation
import BridgeplayInstallerCore

@MainActor
@Observable
final class InstallerModel {
    enum Stage: Int { case checking, review, downloading, installing, done, failed }
    var stage: Stage = .checking
    var version = ""
    var installedVersion: String?
    var isCurrent = false
    var progress: Double?
    var received: Int64 = 0
    var total: Int64?
    var failure: String?
    var openBridgeplay = true
    var removeInstaller = true
    var finishing = false
    let preview: String?
    private var release: InstallerRelease?
    private var operation: Task<Void, Never>?
    private let service: InstallerService
    var destination: URL { service.destination }
    private(set) var cleanupSource: InstallerCleanup.Source?

    static var previewArgument: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--preview"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static var destinationArgument: URL {
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--test-destination"), args.indices.contains(index + 1) {
            let value = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            if value.lastPathComponent == "Bridgeplay.app",
               value.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(temp + "/") { return value }
            fatalError("Test destination must be Bridgeplay.app inside the temporary directory.")
        }
        #endif
        return URL(fileURLWithPath: "/Applications/Bridgeplay.app")
    }

    init(preview: String? = InstallerModel.previewArgument) {
        self.preview = preview
        self.service = InstallerService(destination: Self.destinationArgument)
        if let preview {
            version = "3.4.1"
            switch preview {
            case "update": installedVersion = "3.3.0"; stage = .review
            case "current": installedVersion = version; isCurrent = true; stage = .done
            case "download": stage = .downloading; received = 31_659_404; total = 79_148_511; progress = 0.4
            case "install": stage = .installing
            case "done": stage = .done
            case "error": stage = .failed; failure = tr("The download could not be verified. Your installed application has been kept.")
            default: stage = .review
            }
        } else {
            cleanupSource = try? InstallerCleanup.source()
        }
    }

    var busy: Bool { stage == .checking || stage == .downloading || stage == .installing || finishing }
    var updating: Bool { installedVersion != nil }
    var step: Int {
        switch stage { case .checking: 0; case .review, .failed: 1; case .downloading, .installing: 2; case .done: 3 }
    }

    func check() async {
        guard preview == nil else { return }
        stage = .checking
        failure = nil
        do {
            let service = self.service
            try await Task.detached(priority: .userInitiated) { try service.recoverIfNeeded() }.value
            try Task.checkCancellation()
            let fetched = try await InstallerRelease.latest()
            try Task.checkCancellation()
            release = fetched
            version = fetched.shortVersion
            total = fetched.archiveLength
            let state = try service.state(for: fetched)
            switch state {
            case .notInstalled: installedVersion = nil; stage = .review
            case .updateAvailable(_, let current, _): installedVersion = current; stage = .review
            case .upToDate(_, let current): installedVersion = current; version = current; isCurrent = true; stage = .done
            }
        } catch is CancellationError {
            stage = .review
        } catch { fail(error) }
    }

    func start() {
        guard operation == nil, let release, preview == nil else { return }
        operation = Task {
            defer { operation = nil }
            stage = .downloading
            failure = nil
            received = 0
            progress = nil
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeplay-install-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let archive = try await release.download(to: work) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.stage == .downloading else { return }
                        self.received = value.received
                        self.total = value.total
                        self.progress = value.total.flatMap { $0 > 0 ? Double(value.received) / Double($0) : nil }
                    }
                }
                try Task.checkCancellation()
                stage = .installing
                progress = nil
                let service = self.service
                _ = try await Task.detached(priority: .userInitiated) {
                    try service.install(release: release, archive: archive)
                }.value
                stage = .done
            } catch is CancellationError {
                stage = .review
            } catch { fail(error) }
        }
    }

    func cancel() {
        guard stage != .installing else { return }
        operation?.cancel()
    }

    func retry() {
        guard !busy else { return }
        operation = Task { await check(); operation = nil }
    }

    func finish() {
        guard preview == nil, stage == .done, !finishing else { return }
        finishing = true
        if openBridgeplay {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
                Task { @MainActor in
                    if let error { self.failure = error.localizedDescription; self.finishing = false }
                    else { self.finishCleanup() }
                }
            }
        } else { finishCleanup() }
    }

    private func finishCleanup() {
        do {
            if removeInstaller, let cleanupSource { try InstallerCleanup.schedule(cleanupSource) }
            NSApplication.shared.terminate(nil)
        } catch { failure = error.localizedDescription; finishing = false }
    }

    private func fail(_ error: Error) {
        failure = InstallerMessage.describe(error)
        stage = .failed
    }
}
