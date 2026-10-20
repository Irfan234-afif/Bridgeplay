import AppKit
import Foundation

// Drives the Setup Assistant: checks first, asks only when a check fails, and runs the
// same installs as the Status page (installIntoSteam, installWinecxEngine) in order.
@MainActor
@Observable
final class SetupAssistant {

    enum Step: Int, CaseIterable, Identifiable {
        case mac, graphics, steam, finish, done
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .mac: String(localized: "Your Mac")
            case .graphics: String(localized: "Graphics")
            case .steam: String(localized: "Steam")
            case .finish: String(localized: "Set Up")
            case .done: String(localized: "Done")
            }
        }
    }

    enum TaskState: Equatable { case waiting, running, done, failed(String) }

    struct SetupTask: Identifiable, Equatable {
        let id: String
        let title: String
        var state: TaskState = .waiting
    }

    static let finishedKey = "setupAssistantFinished"

    var step: Step = .mac
    var isWorking = false
    var message: String?

    // Mac
    var rosettaInstalled = SetupChecks.rosettaInstalled()
    let appleSilicon = SetupChecks.isAppleSilicon
    let macOSSupported = SetupChecks.macOSVersion.majorVersion >= SetupChecks.minimumMacOS
    let freeBytes = SetupChecks.freeBytes()

    // Graphics
    var gptk: WinecxD3DMetal.Payload?
    var gptkImages: [URL]
    var skippedGraphics = false

    // Steam
    var steamInstalled = SteamBundle.isPresent
    var signedIn = SetupChecks.steamSignedIn()
    @ObservationIgnored private var signInWatch: Task<Void, Never>?

    // The keychain identity that keeps Steam's controller permission across updates.
    enum TrustState: Equatable { case unknown, needed, working, done, declined(String) }
    var trust: TrustState = .unknown

    // Finish
    var tasks: [SetupTask] = SetupAssistant.plannedTasks
    var needsAppManagement = false
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    static let plannedTasks = [
        SetupTask(id: "steam", title: String(localized: "Add Bridgeplay to Steam")),
        SetupTask(id: "engine", title: String(localized: "Set up the WineCX engine")),
        SetupTask(id: "default", title: String(localized: "Make WineCX Steam's default")),
    ]

    // Set by the debug-only --setup-preview window: actions pretend instead of installing,
    // so the assistant can be clicked through on a Mac that is already set up.
    let isPreview: Bool

    init(preview: Preview? = nil, startAt start: Step = .mac) {
        isPreview = preview != nil
        let located = preview == .fresh ? nil : WinecxD3DMetal.locate()
        gptk = located
        gptkImages = preview == .fresh ? [] : GPTKImport.candidatesIfMissing(installed: located != nil)
        if preview == .fresh {
            rosettaInstalled = false
            signedIn = false
            trust = .needed
        }
        // The preview can open on a later step; the steps before it count as passed, so a
        // fresh Mac shows step 4 as someone who pressed Trust in step 3 would see it.
        if isPreview, start != .mac {
            step = start
            if start.rawValue > Step.steam.rawValue {
                rosettaInstalled = true
                signedIn = true
                trust = .done
            }
        }
    }

    enum Preview { case thisMac, fresh }

    private func pretend(_ seconds: Double = 0.9) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    var macReady: Bool { appleSilicon && macOSSupported && rosettaInstalled && hasSpace }
    var hasSpace: Bool { (freeBytes ?? .max) >= SetupChecks.requiredBytes }

    static func shouldShow(_ snapshot: StatusSnapshot?, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: finishedKey), let snapshot else { return false }
        let deployed: Bool = switch snapshot.steam {
        case .installed, .outdated: true
        default: false
        }
        return !(deployed && snapshot.currentFreeEngines.contains(FreeEngineWinecx.current.build))
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        message = nil
        step = next
        if step == .steam {
            watchSignIn()
            Task { await checkTrust() }
        }
    }

    func back() {
        guard step != .finish || !isWorking, let previous = Step(rawValue: step.rawValue - 1) else { return }
        message = nil
        step = previous
    }

    // MARK: Mac

    func installRosetta() async {
        isWorking = true
        defer { isWorking = false }
        if isPreview { await pretend(); rosettaInstalled = true; return }
        do {
            try await Task.detached(priority: .userInitiated) { try SetupChecks.installRosetta() }.value
        } catch {
            AppLog.note("setup: Rosetta install failed: \(error.localizedDescription)")
            message = SetupChecks.rosettaFailure(error)
        }
        rosettaInstalled = SetupChecks.rosettaInstalled()
    }

    // MARK: Graphics

    func importGPTK(_ image: URL) async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            gptk = try await Task.detached(priority: .userInitiated) { try GPTKImport.importImage(image) }.value
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Steam

    func installSteam() async {
        isWorking = true
        defer { isWorking = false }
        if isPreview { await pretend(); steamInstalled = true; return }
        message = nil
        do {
            try await SetupChecks.installSteam { _ in }
        } catch {
            message = String(localized: "Steam wasn't installed. \(error.localizedDescription)")
        }
        steamInstalled = SteamBundle.isPresent
    }

    func openSteam() {
        if isPreview { Task { await pretend(1.5); signedIn = true }; return }
        NSWorkspace.shared.open(SupportPaths.Steam.app)
        watchSignIn()
    }

    private func watchSignIn() {
        signInWatch?.cancel()
        guard !signedIn, !isPreview else { return }
        signInWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if SetupChecks.steamSignedIn() {
                    self.signedIn = true
                    return
                }
            }
        }
    }

    func checkTrust() async {
        guard trust == .unknown else { return }
        let present = await Task.detached(priority: .utility) { LocalSigning.existingHash() != nil }.value
        if trust == .unknown { trust = present ? .done : .needed }
    }

    // One click, no password: see LocalSigning for why no prompt is needed. A failure keeps
    // ad hoc signing, which works but loses the controller permission on every update.
    func trustThisMac() async {
        guard trust != .working, trust != .done else { return }
        trust = .working
        if isPreview { await pretend(); trust = .done; return }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try LocalSigning.ensure() }.value
            trust = .done
        } catch {
            AppLog.note("setup: signing identity not created: \(error.localizedDescription)")
            trust = .declined(Self.untrustedNote)
        }
    }

    static let untrustedNote =
        String(localized: "Not set up. Bridgeplay still works, but after each update you'll need to allow your controller again.")

    // MARK: Finish

    func finish(with status: SystemStatus) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        needsAppManagement = false
        message = nil
        tasks = Self.plannedTasks

        if isPreview {
            for task in Self.plannedTasks {
                set(task.id, .running)
                await pretend(1.2)
                set(task.id, .done)
            }
            step = .done
            return
        }

        set("steam", .running)
        await status.installIntoSteam()
        if let failure = status.failure {
            if status.failureRemedy == .appManagement {
                needsAppManagement = true
                set("steam", .failed(String(localized: "macOS needs your permission first.")))
                watchPermission(status)
            } else {
                set("steam", .failed(failure))
            }
            return
        }
        set("steam", .done)

        set("engine", .running)
        await status.installWinecxEngine()
        if let failure = status.failure {
            set("engine", .failed(failure))
            return
        }
        set("engine", .done)

        set("default", .running)
        if SteamBundle.isRunning {
            set("default", .failed(String(localized: "Quit Steam, then press Try Again.")))
            return
        }
        do {
            if let tool = FreeEngineWinecx.current.runner.tools.first?.name {
                try SteamDefaultTool.set(tool)
            }
            set("default", .done)
        } catch {
            set("default", .failed(error.localizedDescription))
            return
        }

        UserDefaults.standard.set(true, forKey: Self.finishedKey)
        step = .done
    }

    var notStarted: Bool { tasks.allSatisfy { $0.state == .waiting } }
    var failed: Bool { tasks.contains { if case .failed = $0.state { true } else { false } } }

    private func set(_ id: String, _ state: TaskState) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
    }

    func openAppManagement() {
        if let pane = Remedy.appManagement.settingsPane { Remedy.openSettings(pane) }
    }

    // Retries on its own as soon as macOS lets this app write into Steam.app.
    private func watchPermission(_ status: SystemStatus) {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.needsAppManagement else { return }
                if Self.canWriteSteam() {
                    await self.finish(with: status)
                    return
                }
            }
        }
    }

    nonisolated static func canWriteSteam(app: URL = SupportPaths.Steam.app) -> Bool {
        let probe = app.appending(path: "Contents/.bridgeplay-write-probe")
        guard FileManager.default.createFile(atPath: probe.path(percentEncoded: false), contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    func openSteamAndClose() {
        guard !isPreview else { return }
        NSWorkspace.shared.open(SupportPaths.Steam.app)
    }

    func dismiss() {
        signInWatch?.cancel()
        permissionWatch?.cancel()
        guard !isPreview else { return }
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
    }
}
