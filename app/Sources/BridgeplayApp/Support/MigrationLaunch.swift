import Foundation
import Observation

// Runs the 3.0.0 move from the notproton folders to the bridgeplay ones (BrandMigration).
// It starts in Launch.main, before AppLog or anything else opens the support folder. If
// Steam or a game is running it waits: the main window shows a banner, the patch keeper
// and the post-update install stand still, and the move finishes by itself once both are
// closed. Bridgeplay then installs itself into Steam again, because the copy Steam holds
// still points at the old folders.
@MainActor
@Observable
final class MigrationLaunch {
    static let shared = MigrationLaunch()

    private(set) var pending = false
    private(set) var blocker: BrandMigration.Blocker?
    @ObservationIgnored private var launchNote: String?

    // Debug builds run from the source tree and never move the real folders.
    nonisolated static var enabled: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    func runAtLaunch() {
        guard Self.enabled else { return }
        let migration = BrandMigration.live()
        guard migration.isNeeded else { return }
        if let blocker = migration.canRun() {
            pending = true
            self.blocker = blocker
            launchNote = "migration 3.0.0 waits: \(blocker)"
            return
        }
        launchNote = Self.run(migration)
    }

    // AppLog only exists once the app has started, so the launch result is logged then.
    func logLaunchResult() {
        if let launchNote { AppLog.note(launchNote) }
        launchNote = nil
    }

    func finishWhenPossible(_ status: SystemStatus) async {
        guard pending else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            let migration = BrandMigration.live()
            guard migration.isNeeded else { pending = false; return }
            blocker = migration.canRun()
            guard blocker == nil else { continue }
            AppLog.note(Self.run(migration))
            pending = false
            await status.refresh()
            await status.installIntoSteam()
            return
        }
    }

    private static func run(_ migration: BrandMigration) -> String {
        do {
            return "migration 3.0.0: \(try migration.run().description)"
        } catch {
            return "migration 3.0.0 failed: \(error)"
        }
    }

    var bannerMessage: String {
        switch blocker {
        case .gameRunning: String(localized: "Quit your game. Bridgeplay finishes moving its files to the new Bridgeplay folders by itself.")
        default: String(localized: "Quit Steam. Bridgeplay finishes moving its files to the new Bridgeplay folders by itself, then adds itself to Steam again.")
        }
    }
}
