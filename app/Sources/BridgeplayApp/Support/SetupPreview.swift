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

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        Window("Bridgeplay Setup", id: "setup-preview") {
            PreviewWizard(preview: preview)
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SetupAssistantView(model: SetupAssistant(preview: preview)) {
            openWindow(id: "main-preview")
            dismissWindow(id: "setup-preview")
        }
    }
}
#endif
