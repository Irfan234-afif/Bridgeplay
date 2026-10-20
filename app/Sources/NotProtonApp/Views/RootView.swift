import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .prefixes: String(localized: "Prefixes")
        case .backups: String(localized: "Prefix Backups")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane
    @Environment(SystemStatus.self) private var status

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch pane {
                case .status: StatusView()
                case .prefixes: PrefixesView()
                case .backups: BackupsView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner = status.patchBanner {
                    PatchBanner(banner: banner)
                }
            }
        }
    }
}
