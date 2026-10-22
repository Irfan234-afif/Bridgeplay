import Testing
@testable import BridgeplayApp

@Suite("Download progress label")
struct DownloadProgressLabelTests {
    @Test func showsAmountAndRoundsTheEstimateUpToMinutes() {
        let label = PinnedDownload.Progress.label(host: "github.com", received: 100_000_000, total: 400_000_000, remaining: 61)
        #expect(label.hasPrefix("Downloading from github.com: 100 MB / 400 MB"))
        #expect(label.hasSuffix("about 2 minutes left"))
    }

    @Test func leavesTheEstimateOutUntilThereIsOne() {
        let label = PinnedDownload.Progress.label(host: "github.com", received: 0, total: 400_000_000, remaining: nil)
        #expect(label == "Downloading from github.com: Zero KB / 400 MB")
    }
}
