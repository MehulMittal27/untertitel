import Foundation
import os.log

private extension Logger {
    static let debugAudio = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingDiagnosis")
}

/// The last meeting's audio and speaker figures, kept for diagnosis only when the
/// user switches it on: on this Mac, in the app's data folder, out of backups, and
/// deleted after 24 hours. Only the last meeting is kept.
struct MeetingDebugStore {
    static let lifetime: TimeInterval = 24 * 60 * 60

    let folder: URL
    var fileManager: FileManager = .default

    init(folder: URL = AppDataDirectory.url.appendingPathComponent("MeetingDiagnosis", isDirectory: true)) {
        self.folder = folder
    }

    var audioURL: URL { folder.appendingPathComponent("last-meeting.wav") }
    var diagnosticsURL: URL { folder.appendingPathComponent("last-meeting.json") }

    func saveAudio(_ samples: [Float]) {
        write(SonioxFilePass.wav(samples: samples), to: audioURL)
    }

    /// Speaker figures and turn times. No transcript text.
    func saveDiagnostics(_ diagnostics: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        write(data, to: diagnosticsURL)
    }

    /// Removes files older than a day. Called at launch and every hour.
    func removeExpired(now: Date = Date()) {
        for url in [audioURL, diagnosticsURL] {
            guard let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(created) >= Self.lifetime else {
                continue
            }
            try? fileManager.removeItem(at: url)
            Logger.debugAudio.log("Deleted meeting diagnosis file after 24 hours")
        }
    }

    func deleteAll() {
        try? fileManager.removeItem(at: audioURL)
        try? fileManager.removeItem(at: diagnosticsURL)
    }

    var hasFiles: Bool {
        fileManager.fileExists(atPath: audioURL.path) || fileManager.fileExists(atPath: diagnosticsURL.path)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var folderURL = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folderURL.setResourceValues(values)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Logger.debugAudio.error("Meeting diagnosis not kept: \(error.localizedDescription, privacy: .public)")
        }
    }
}
