import Foundation

/// A plain-text record, kept on this Mac only, of every cloud session and every
/// connection to the cloud engine: when it opened and closed, what triggered it, and
/// how much audio was sent. It answers "what was I billed for" without guesswork.
/// It never holds audio, transcript or translation text.
@MainActor
final class CloudConnectionJournal {
    static let maximumLineCount = 2_000

    let fileURL: URL
    private let timestampFormatter: DateFormatter
    private var recordedSinceTrim = 0

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = appSupportRoot
                .appendingPathComponent("v2s", isDirectory: true)
                .appendingPathComponent("cloud-connections.log")
        }

        timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    }

    func record(_ message: String, at date: Date = Date()) {
        let line = "\(timestampFormatter.string(from: date))  \(message)\n"

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL, options: [.atomic])
            }
        } catch {
            fputs("Failed to write the cloud connection log: \(error)\n", stderr)
            return
        }

        recordedSinceTrim += 1
        if recordedSinceTrim >= 200 {
            recordedSinceTrim = 0
            trim()
        }
    }

    func lines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        return text.split(separator: "\n").map(String.init)
    }

    /// Keeps the newest lines, so the file cannot grow without bound.
    func trim() {
        let all = lines()
        guard all.count > Self.maximumLineCount else {
            return
        }

        let kept = all.suffix(Self.maximumLineCount).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: fileURL, options: [.atomic])
    }
}
