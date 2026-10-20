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
    var gptk: WinecxD3DMetal.Payload? = WinecxD3DMetal.locate()
    var gptkImages: [URL] = GPTKImport.candidates()
    var skippedGraphics = false

    // Steam
    var steamInstalled = SteamBundle.isPresent
    var signedIn = SetupChecks.steamSignedIn()
    @ObservationIgnored private var signInWatch: Task<Void, Never>?

    // Finish
    var tasks: [SetupTask] = SetupAssistant.plannedTasks
    var needsAppManagement = false
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    static let plannedTasks = [
        SetupTask(id: "steam", title: String(localized: "Add Bridgeplay to Steam")),
        SetupTask(id: "engine", title: String(localized: "Set up the WineCX engine")),
        SetupTask(id: "default", title: String(localized: "Make WineCX Steam's default")),
    ]

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
        if step == .steam { watchSignIn() }
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
        do {
            try await Task.detached(priority: .userInitiated) { try SetupChecks.installRosetta() }.value
        } catch {
            message = String(localized: "Rosetta wasn't installed. \(error.localizedDescription)")
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
        message = nil
        do {
            try await SetupChecks.installSteam { _ in }
        } catch {
            message = String(localized: "Steam wasn't installed. \(error.localizedDescription)")
        }
        steamInstalled = SteamBundle.isPresent
    }

    func openSteam() {
        NSWorkspace.shared.open(SupportPaths.Steam.app)
        watchSignIn()
    }

    private func watchSignIn() {
        signInWatch?.cancel()
        guard !signedIn else { return }
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

    // MARK: Finish

    func finish(with status: SystemStatus) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        needsAppManagement = false
        message = nil
        tasks = Self.plannedTasks

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
        let probe = app.appending(path: "Contents/.notproton-write-probe")
        guard FileManager.default.createFile(atPath: probe.path(percentEncoded: false), contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    func openSteamAndClose() {
        NSWorkspace.shared.open(SupportPaths.Steam.app)
    }

    func dismiss() {
        signInWatch?.cancel()
        permissionWatch?.cancel()
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
    }
}
