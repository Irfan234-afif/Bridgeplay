// Download one hash pinned file from a list of CDN hosts

import Foundation

enum PinnedDownload {

    enum Progress: Sendable {
        case reusing
        case fetching(host: String)
        case receiving(host: String, received: Int64, total: Int64, remaining: TimeInterval?)

        var label: String {
            switch self {
            case .reusing: String(localized: "Preparing")
            case .fetching(let host): String(localized: "Downloading from \(host)")
            case .receiving(let host, let received, let total, let remaining):
                Self.label(host: host, received: received, total: total, remaining: remaining)
            }
        }

        static func label(host: String, received: Int64, total: Int64, remaining: TimeInterval?) -> String {
            let amount = ByteCountFormatter.string(fromByteCount: received, countStyle: .file) + " / "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let time = DateComponentsFormatter()
            time.unitsStyle = .full
            time.maximumUnitCount = 1
            time.allowedUnits = [.hour, .minute, .second]
            // Seconds only near the end, so the estimate doesn't tick every second.
            let rounded = remaining.map { $0 < 60 ? $0 : ($0 / 60).rounded(.up) * 60 }
            guard let rounded, let left = time.string(from: max(rounded, 1)) else {
                return String(localized: "Downloading from \(host): \(amount)")
            }
            return String(localized: "Downloading from \(host): \(amount), about \(left) left")
        }
    }

    // The engine is about 440 MB: three hours still finishes it at about 42 KB/s. Stalls
    // fail sooner on the 60 second idle timeout.
    static let session = session(deadline: 3 * 60 * 60)

    static func session(deadline: TimeInterval, protocols: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = deadline
        config.protocolClasses = protocols + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    static func obtain(
        file: String,
        sha256: String,
        bases: [URL],
        into downloads: URL,
        step: String,
        from source: String = "Valve",
        session: URLSession = PinnedDownload.session,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let archive = downloads.appending(path: file)
        if Digest.sha256IfPresent(archive) == sha256 {
            report(.reusing)
            return archive
        }

        var refusals: [String] = []
        var kinds: Set<Refusal> = []
        for base in bases {
            let host = base.host() ?? base.absoluteString
            report(.fetching(host: host))
            let body: URL, response: URLResponse
            do {
                (body, response) = try await withoutActuallyEscaping(report) { report in
                    let relay = ProgressRelay(host: host, report: report)
                    defer { relay.finish() }
                    return try await session.download(from: base.appending(path: file), delegate: relay)
                }
            } catch {
                refusals.append("\(host): \(error.localizedDescription)")
                kinds.insert(.unreachable)
                continue
            }
            defer { try? FileManager.default.removeItem(at: body) }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                refusals.append("\(host) answered \(http.statusCode)")
                kinds.insert(.answered)
                continue
            }

            let got = try Digest.sha256(of: body)
            guard got == sha256 else {
                refusals.append("\(host) served \(got.prefix(16)) rather than \(sha256.prefix(16))")
                kinds.insert(.mismatch)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: downloads, withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: body, to: archive)
            } catch {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(downloads.path(percentEncoded: false)) could not be written. ")
                        + error.localizedDescription
                )
            }
            return archive
        }

        AppLog.note("\(file) refused by all \(bases.count) hosts: \(refusals.joined(separator: ". "))")
        throw StepFailure(step: step, detail: reason(kinds, from: source))
    }

    private enum Refusal {
        case unreachable
        case mismatch
        case answered
    }

    private static func reason(_ kinds: Set<Refusal>, from source: String) -> String {
        if kinds == [.mismatch] {
            return String(localized: "Something is wrong with the downloaded files. Please check for a Bridgeplay update.")
        }
        if kinds == [.unreachable] {
            return String(localized: "Bridgeplay could not reach \(source)'s servers. Please check your internet connection and try again.")
        }
        return String(localized: "Bridgeplay could not download the files it needs from \(source). Please try again later.")
    }
}

// Turns the task's byte count into .receiving reports, once per percent.
private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    // Dropped by finish(): the caller's closure only lives as long as the download.
    private var report: (@Sendable (PinnedDownload.Progress) -> Void)?
    private let started = Date()
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var shown = -1

    init(host: String, report: @escaping @Sendable (PinnedDownload.Progress) -> Void) {
        self.host = host
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            self?.update(received: progress.completedUnitCount, total: progress.totalUnitCount)
        }
        lock.withLock { self.observation = observation }
    }

    func finish() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
            report = nil
        }
    }

    private func update(received: Int64, total: Int64) {
        guard total > 0, received <= total else { return }
        let percent = Int(received * 100 / total)
        let elapsed = Date().timeIntervalSince(started)
        // A few seconds in, so the first estimate isn't wild.
        let remaining = received > 0 && elapsed > 3 ? elapsed * Double(total - received) / Double(received) : nil
        // Reported under the lock, so finish() can't drop the closure mid-call.
        lock.withLock {
            guard percent != shown, let report else { return }
            shown = percent
            report(.receiving(host: host, received: received, total: total, remaining: remaining))
        }
    }
}
