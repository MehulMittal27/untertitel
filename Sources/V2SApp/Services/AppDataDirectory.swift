import Foundation
import os.log

/// The folder in Application Support that holds the app's settings, usage record and
/// connection log. Builds before the rename used `v2s`; their files are moved into
/// `Untertitel` the first time the folder is asked for.
enum AppDataDirectory {
    static let folderName = "Untertitel"
    static let legacyFolderName = "v2s"

    /// Resolved once per launch, so the move happens before anything reads a file.
    static let url: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return resolve(inApplicationSupport: root)
    }()

    /// Moves the legacy folder's contents into the current one and returns the folder
    /// to use. Nothing is overwritten: a file that exists in both stays where it is.
    /// If the move fails, the legacy folder keeps being used so no setting is lost.
    static func resolve(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let current = root.appendingPathComponent(folderName, isDirectory: true)
        let legacy = root.appendingPathComponent(legacyFolderName, isDirectory: true)

        guard isDirectory(legacy, fileManager: fileManager) else {
            return current
        }

        guard fileManager.fileExists(atPath: current.path) else {
            do {
                try fileManager.moveItem(at: legacy, to: current)
                Logger.dataDirectory.log("Moved the app's data from \(legacyFolderName, privacy: .public) to \(folderName, privacy: .public)")
                return current
            } catch {
                Logger.dataDirectory.error("Could not move the app's data: \(error.localizedDescription, privacy: .public)")
                return legacy
            }
        }

        // Both exist, for example after an older build ran again: bring over what the
        // current folder does not have yet.
        let names = (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
        var leftBehind = false
        for name in names {
            let target = current.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: target.path) == false else {
                leftBehind = true
                continue
            }
            do {
                try fileManager.moveItem(at: legacy.appendingPathComponent(name), to: target)
            } catch {
                leftBehind = true
            }
        }
        if leftBehind == false {
            try? fileManager.removeItem(at: legacy)
        }
        return current
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private extension Logger {
    static let dataDirectory = Logger(subsystem: "com.franklioxygen.v2s", category: "dataDirectory")
}
