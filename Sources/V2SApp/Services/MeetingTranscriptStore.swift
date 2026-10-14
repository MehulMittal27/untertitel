import Foundation
import os.log

private extension Logger {
    static let transcripts = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingTranscripts")
}

/// Saved meeting transcripts: Markdown files in `~/Meeting Transcripts`, written only
/// when saving is switched on.
///
/// The folder is outside iCloud Drive's Desktop and Documents and outside the folders
/// Dropbox, OneDrive and Google Drive sync (`~/Library/CloudStorage`), so nothing in it
/// leaves this Mac. If the folder turns out to be synced anyway (moved or linked into
/// such a place), nothing is written.
struct MeetingTranscriptStore {
    enum StoreError: Error, Equatable {
        /// The folder is inside a synced location; saving there would upload it.
        case folderIsSynced
    }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meeting Transcripts", isDirectory: true)
    }

    /// Shown in Settings.
    static let displayPath = "~/Meeting Transcripts"

    let folder: URL
    /// The home folder synced places are looked for in.
    let home: URL
    var fileManager: FileManager = .default

    init(
        folder: URL = MeetingTranscriptStore.defaultFolder,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.folder = folder
        self.home = home
    }

    /// Whether `url`, links resolved, lies inside a location that syncs to a cloud.
    static func isSyncedLocation(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = home.resolvingSymlinksInPath().standardizedFileURL.path
        let syncedRoots = [
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "\(home)/Dropbox",
        ]
        if syncedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }

    /// Writes the transcript, replacing an earlier save of the same meeting.
    @discardableResult
    func save(_ markdown: String, fileName: String) throws -> URL {
        // Checked before anything is created, and again once the folder exists, in
        // case a link along the way leads into a synced place.
        guard Self.isSyncedLocation(folder, home: home) == false else {
            throw StoreError.folderIsSynced
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Self.isSyncedLocation(folder, home: home) == false else {
            throw StoreError.folderIsSynced
        }
        let url = folder.appendingPathComponent(fileName)
        try Data(markdown.utf8).write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Logger.transcripts.log("Saved a meeting transcript")
        return url
    }

    /// Removes one transcript for good.
    func delete(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    /// The saved transcripts, newest first.
    func transcripts() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Removes every saved transcript for good.
    func deleteAll() throws {
        for url in transcripts() {
            try fileManager.removeItem(at: url)
        }
    }
}
