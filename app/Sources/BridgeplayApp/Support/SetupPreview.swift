#if DEBUG
import AppKit
import SwiftUI

// Debug builds only: `.build/debug/BridgeplayApp --setup-preview [--fresh]` opens the Setup
// Assistant by itself for design review, then the main window once it closes. The assistant
// reads this Mac's state and only pretends to act (--fresh shows a Mac that still needs
// setup; --main skips straight to the main window). The main window is the real one: its
// buttons do what they do in the app.
struct SetupPreviewApp: App {
    static let flag = "--setup-preview"

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    @State private var pane: Pane = .status
    private static let mainFirst = CommandLine.arguments.contains("--main")
    private let preview: SetupAssistant.Preview =
        CommandLine.arguments.contains("--fresh") ? .fresh : .thisMac
    // --step 4 opens on Set Up; numbers match the wizard's "Step N of 5".
    private static let start: SetupAssistant.Step = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--step"), index + 1 < arguments.count,
              let number = Int(arguments[index + 1]),
              let step = SetupAssistant.Step(rawValue: number - 1) else { return .mac }
        return step
    }()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        Window("Bridgeplay Setup", id: "setup-preview") {
            PreviewWizard(preview: preview, start: Self.start)
                .environment(status)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.mainFirst ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window("Bridgeplay", id: "main-preview") {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 900, height: 760)
        .defaultLaunchBehavior(Self.mainFirst ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct PreviewWizard: View {
    let preview: SetupAssistant.Preview
    let start: SetupAssistant.Step
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SetupAssistantView(model: SetupAssistant(preview: preview, startAt: start)) {
            openWindow(id: "main-preview")
            dismissWindow(id: "setup-preview")
        }
    }
}
#endif
