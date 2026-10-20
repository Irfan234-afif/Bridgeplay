import SwiftUI
import UniformTypeIdentifiers

// First-run Setup Assistant. Built from the Status page's own pieces (a grouped Form of
// StatusRows with StatusTone dots and StatusActions) so it reads as part of the same app.
// Each step checks first; buttons appear only for what a check could not do on its own.
struct SetupAssistantView: View {
    @Environment(SystemStatus.self) private var status
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: SetupAssistant
    // How many rows of the current step have resolved; the rest still show "Checking…".
    @State private var revealed: Int
    @State private var forward = true
    private let fixedReveal: Int?

    init(model: SetupAssistant = SetupAssistant(), revealed: Int? = nil) {
        _model = State(initialValue: model)
        _revealed = State(initialValue: revealed ?? 0)
        fixedReveal = revealed
    }

    static let pageSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let rowSpring = Animation.spring(response: 0.32, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: model.step)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ZStack {
                Form {
                    content
                    if let message = model.message {
                        Section {
                            StatusRow(title: String(localized: "Something went wrong"), value: message, tone: .bad)
                        }
                    }
                }
                .formStyle(.grouped)
                .id(model.step)
                .transition(pageTransition)
            }
            .clipped()
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 640, height: 560)
        .task(id: model.step) { await wave() }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // Rows resolve one after another so the checks read as work being done, not a wall of
    // results. Reduce Motion shows them all at once.
    private func wave() async {
        if let fixedReveal { revealed = fixedReveal; return }
        guard !reduceMotion else { revealed = .max; return }
        revealed = 0
        try? await Task.sleep(for: .milliseconds(260))
        for index in 1...5 {
            withAnimation(Self.rowSpring) { revealed = index }
            try? await Task.sleep(for: .milliseconds(210))
        }
        revealed = .max
    }

    private func go(forward: Bool, _ change: () -> Void) {
        self.forward = forward
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.pageSpring, change)
    }

    // One row of the wave: pending rows keep their title and show a spinner in place of the
    // result, then swap in the real value and tone.
    private func checked(_ index: Int, _ row: StatusRow) -> some View {
        let pending = index >= revealed
        var shown = row
        if pending {
            shown.value = String(localized: "Checking…")
            shown.tone = .neutral
            shown.detail = nil
            shown.action = nil
            shown.secondaryAction = nil
            shown.trailing = nil
        }
        return shown
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if pending {
                    ProgressView().controlSize(.small).transition(.opacity)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .mac: macStep
        case .graphics: graphicsStep
        case .steam: steamStep
        case .finish: finishStep
        case .done: doneStep
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var macStep: some View {
        Section {
            checked(0, StatusRow(title: String(localized: "Apple silicon"),
                      value: model.appleSilicon ? SetupChecks.chipName : String(localized: "Bridgeplay doesn't run on Intel Macs."),
                      tone: model.appleSilicon ? .ok : .bad))
            checked(1, StatusRow(title: String(localized: "macOS \(SetupChecks.minimumMacOS) or later"),
                      value: model.macOSSupported ? SetupChecks.macOSDisplay : String(localized: "\(SetupChecks.macOSDisplay). Update macOS first."),
                      tone: model.macOSSupported ? .ok : .bad))
            checked(2, StatusRow(title: String(localized: "Free space"),
                      value: model.freeBytes.map { String(localized: "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) available, 3 GB needed") },
                      tone: model.hasSpace ? .ok : .bad))
            checked(3, StatusRow(title: String(localized: "Rosetta 2"),
                      value: model.rosettaInstalled ? String(localized: "Installed.") : String(localized: "Apple's translator for Windows games. Asks for your Mac password."),
                      tone: model.rosettaInstalled ? .ok : .warning,
                      action: model.rosettaInstalled ? nil : StatusAction(
                        label: String(localized: "Install"), isProminent: true, isEnabled: !model.isWorking
                      ) { Task { await model.installRosetta() } }))
        } header: {
            StepHeader(title: "Check your Mac",
                       detail: "Bridgeplay runs Windows games from your Steam library. First, a few quick checks.")
        }
    }

    @ViewBuilder
    private var graphicsStep: some View {
        Section {
            if let gptk = model.gptk {
                StatusRow(title: String(localized: "Game Porting Toolkit"),
                          value: String(localized: "Ready from \(gptk.libRoot.path(percentEncoded: false))."),
                          tone: .ok, trailing: gptk.version)
            } else {
                if let image = model.gptkImages.first {
                    StatusRow(title: image.lastPathComponent, value: String(localized: "Found in Downloads."), tone: .info,
                              action: StatusAction(label: String(localized: "Use This"), isProminent: true, isEnabled: !model.isWorking) {
                                  Task { await model.importGPTK(image) }
                              })
                }
                StatusRow(title: String(localized: "Choose a disk image"),
                          value: String(localized: "Drop Game_Porting_Toolkit .dmg on this window, or pick it from a folder."),
                          tone: .neutral,
                          secondaryAction: StatusAction(label: String(localized: "Get It from Apple")) {
                              NSWorkspace.shared.open(URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!)
                          },
                          action: StatusAction(label: String(localized: "Choose…"), isEnabled: !model.isWorking) { chooseImage() })
            }
        } header: {
            StepHeader(title: "Add Apple's game graphics",
                       detail: "The Game Porting Toolkit (D3DMetal) runs DirectX 11 and 12 games on Metal. Apple gives it away for free with an Apple Account. Without it, games use DXMT.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "dmg" }) else { return false }
            Task { await model.importGPTK(url) }
            return true
        }
    }

    @ViewBuilder
    private var steamStep: some View {
        Section {
            checked(0, StatusRow(title: String(localized: "Steam"),
                      value: model.steamInstalled ? SupportPaths.Steam.app.path(percentEncoded: false) : String(localized: "Not installed."),
                      tone: model.steamInstalled ? .ok : .warning,
                      action: model.steamInstalled ? nil : StatusAction(
                        label: String(localized: "Install Steam"), isProminent: true, isEnabled: !model.isWorking
                      ) { Task { await model.installSteam() } }))
            checked(1, StatusRow(title: String(localized: "Steam account"),
                      value: model.signedIn ? String(localized: "Signed in.") : String(localized: "Waiting for you to sign in. Bridgeplay never sees your password."),
                      tone: model.signedIn ? .ok : .info,
                      action: model.signedIn || !model.steamInstalled ? nil : StatusAction(label: String(localized: "Open Steam")) { model.openSteam() }))
            checked(2, trustRow)
        } header: {
            StepHeader(title: "Sign in to Steam",
                       detail: "Sign in with your account in Steam. Bridgeplay continues on its own once you're in.")
        }
    }

    // Optional: Continue does not wait for it. No password is asked for.
    private var trustRow: StatusRow {
        let title = String(localized: "Trust Bridgeplay on this Mac")
        switch model.trust {
        case .unknown, .needed:
            return StatusRow(title: title,
                             value: String(localized: "Keeps your controller working after Bridgeplay updates. Adds a certificate for this Mac to your login keychain."),
                             tone: .info,
                             action: StatusAction(label: String(localized: "Trust"), isEnabled: !model.isWorking && model.trust == .needed) {
                                 Task { await model.trustThisMac() }
                             })
        case .working:
            return StatusRow(title: title, value: String(localized: "Adding the certificate…"), tone: .info)
        case .done:
            return StatusRow(title: title, value: String(localized: "Done. Your controller keeps working after updates."), tone: .ok)
        case .declined(let note):
            return StatusRow(title: title, value: note, tone: .warning,
                             action: StatusAction(label: String(localized: "Try Again"), isEnabled: !model.isWorking) {
                                 Task { await model.trustThisMac() }
                             })
        }
    }

    @ViewBuilder
    private var finishStep: some View {
        Section {
            ForEach(model.tasks) { task in
                StatusRow(title: task.title, value: value(of: task), tone: tone(of: task))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if task.state == .running {
                            ProgressView().controlSize(.small).transition(.opacity)
                        }
                    }
                    .animation(Self.rowSpring, value: task.state)
            }
        } header: {
            StepHeader(title: "Set up Bridgeplay",
                       detail: "Bridgeplay adds itself to Steam, sets up the WineCX engine and makes it Steam's default. Steam closes for a moment.")
        } footer: {
            let done = model.tasks.filter { $0.state == .done }.count
            HStack(spacing: 12) {
                ProgressView(value: Double(done), total: Double(model.tasks.count))
                    .tint(.accentColor)
                    .animation(Self.rowSpring, value: done)
                Text("\(done) of \(model.tasks.count)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(done)))
                    .animation(Self.rowSpring, value: done)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        if model.needsAppManagement {
            Section {
                StatusRow(title: String(localized: "App Management"),
                          value: String(localized: "Turn on Bridgeplay in Privacy & Security › App Management. Setup continues by itself once it's on."),
                          tone: .warning,
                          detail: String(localized: "After a Bridgeplay update the switch can look on but no longer work. Turn it off and on again, or remove Bridgeplay from the list with − and add it back with +."),
                          action: StatusAction(label: Remedy.settingsButton, isProminent: true) { model.openAppManagement() })
            }
        }
    }

    @ViewBuilder
    private var doneStep: some View {
        Section {
            checked(0, StatusRow(title: String(localized: "Bridgeplay"), value: String(localized: "Installed into Steam."), tone: .ok))
            checked(1, StatusRow(title: String(localized: "WineCX Engine"), value: String(localized: "Steam's default for Windows games."), tone: .ok))
            checked(2, StatusRow(title: String(localized: "Game Porting Toolkit"),
                      value: model.gptk == nil ? String(localized: "Skipped. Games use DXMT; add it later from Status.") : String(localized: "Linked."),
                      tone: model.gptk == nil ? .neutral : .ok))
            checked(3, StatusRow(title: String(localized: "Controllers"),
                      value: String(localized: "The first time a game uses a controller, macOS asks to let Steam use Input Monitoring. Click Allow. If you missed it, turn on Steam in Input Monitoring."),
                      tone: .info,
                      action: StatusAction(label: String(localized: "Open Input Monitoring")) { SystemStatus.openInputMonitoring() }))
        } header: {
            StepHeader(title: "You're all set",
                       detail: "Open Steam, install a Windows game and press Play. Status, Prefixes and Prefix Backups in this window change engines, fix a game or undo everything.")
        }
    }

    private func value(of task: SetupAssistant.SetupTask) -> String? {
        switch task.state {
        case .waiting: nil
        case .running: status.activity ?? String(localized: "Working…")
        case .done: String(localized: "Done.")
        case .failed(let reason): reason
        }
    }

    private func tone(of task: SetupAssistant.SetupTask) -> StatusTone {
        switch task.state {
        case .waiting: .neutral
        case .running: .info
        case .done: .ok
        case .failed: .bad
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage]
        panel.directoryURL = GPTKImport.downloads
        panel.prompt = String(localized: "Use This")
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importGPTK(url) } }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step == .mac {
                Button("Not Now") { model.dismiss(); dismiss() }
            } else if model.step != .done {
                Button("Back") { go(forward: false) { model.back() } }
                    .disabled(model.isWorking)
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small).padding(.trailing, 6) }
            switch model.step {
            case .mac:
                Button("Continue") { go(forward: true) { model.advance() } }
                    .disabled(!model.macReady || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .graphics:
                if model.gptk == nil {
                    Button("Skip") { go(forward: true) { model.skippedGraphics = true; model.advance() } }.disabled(model.isWorking)
                }
                Button("Continue") { go(forward: true) { model.advance() } }
                    .disabled(model.gptk == nil || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .steam:
                Button("Continue") { go(forward: true) { model.advance() } }
                    .disabled(!model.steamInstalled || !model.signedIn || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .finish:
                Button(model.failed ? "Try Again" : "Set Up") { Task { await model.finish(with: status) } }
                    .disabled(model.isWorking || !(model.failed || model.notStarted))
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Close") { model.dismiss(); dismiss() }
                Button("Open Steam") { model.openSteamAndClose(); model.dismiss(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Pieces

private struct StepBar: View {
    let current: SetupAssistant.Step
    private let steps = SetupAssistant.Step.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let fraction = CGFloat(current.rawValue + 1) / CGFloat(steps.count)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 3)
            .animation(SetupAssistantView.pageSpring, value: current)
            HStack(spacing: 0) {
                ForEach(steps) { step in
                    Text(step.title)
                        .font(.caption.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.2), value: current)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(steps.count), \(current.title)")
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}
