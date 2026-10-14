import CryptoKit
import Foundation
import os.log

private extension Logger {
    static let spool = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingAudio")
}

/// Keeps a meeting's audio for the pass after Stop: on this Mac only, encrypted,
/// and deleted as soon as the pass is done.
///
/// The audio is written as 16-bit samples in sealed AES-GCM blocks of about two
/// seconds each. The key is made for one meeting and lives only in memory, so a file
/// left behind by a crash cannot be read, and is removed at the next launch.
final class MeetingAudioSpool: @unchecked Sendable {
    /// The folder spool files live in, inside the app's data folder.
    static var folder: URL {
        AppDataDirectory.url.appendingPathComponent("MeetingAudio", isDirectory: true)
    }

    /// Samples per sealed block: two seconds at 16 kHz.
    static let blockSamples = 32_000

    let fileURL: URL
    private let key = SymmetricKey(size: .bits256)
    private let queue = DispatchQueue(label: "Untertitel.meeting.spool")
    private var handle: FileHandle?
    private var pending: [Int16] = []
    private(set) var sampleCount = 0
    private var failed = false

    init(folder: URL = MeetingAudioSpool.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never in a backup: a backup taken mid-meeting would outlive the deletion.
        var folderURL = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folderURL.setResourceValues(values)
        fileURL = folder.appendingPathComponent("\(UUID().uuidString).spool")
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    deinit {
        try? handle?.close()
    }

    /// Takes 16 kHz mono samples. Safe from any thread.
    func append(_ samples: [Float]) {
        queue.async {
            guard self.failed == false else { return }
            self.pending.append(contentsOf: samples.map(Self.int16))
            self.sampleCount += samples.count
            while self.pending.count >= Self.blockSamples {
                self.writeBlock(Array(self.pending.prefix(Self.blockSamples)))
                self.pending.removeFirst(Self.blockSamples)
            }
        }
    }

    /// Everything appended so far, decrypted into memory.
    func readAll() throws -> [Float] {
        try queue.sync {
            if pending.isEmpty == false {
                writeBlock(pending)
                pending.removeAll()
            }
            try handle?.synchronize()
            guard failed == false else {
                throw CocoaError(.fileWriteUnknown)
            }

            let data = try Data(contentsOf: fileURL)
            var samples: [Float] = []
            samples.reserveCapacity(sampleCount)
            var offset = 0
            while offset + 4 <= data.count {
                let length = data.subdata(in: offset..<offset + 4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                offset += 4
                guard offset + length <= data.count else { break }
                let box = try AES.GCM.SealedBox(combined: data.subdata(in: offset..<offset + length))
                let plain = try AES.GCM.open(box, using: key)
                plain.withUnsafeBytes { raw in
                    for value in raw.bindMemory(to: Int16.self) {
                        samples.append(Float(Int16(littleEndian: value)) / Float(Int16.max))
                    }
                }
                offset += length
            }
            return samples
        }
    }

    /// Removes the file. The key goes with this object.
    func delete() {
        queue.sync {
            try? handle?.close()
            handle = nil
            pending.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Removes spool files a crash left behind. Their keys are gone, so they are
    /// unreadable anyway.
    static func removeLeftovers(in folder: URL = MeetingAudioSpool.folder) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        for name in names where name.hasSuffix(".spool") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            Logger.spool.log("Removed leftover meeting audio")
        }
    }

    private func writeBlock(_ block: [Int16]) {
        do {
            let plain = block.withUnsafeBufferPointer { buffer in
                Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
            }
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
                throw CocoaError(.fileWriteUnknown)
            }
            var length = UInt32(sealed.count).littleEndian
            try handle?.write(contentsOf: Data(bytes: &length, count: 4))
            try handle?.write(contentsOf: sealed)
        } catch {
            failed = true
            Logger.spool.error("Could not keep meeting audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()).littleEndian
    }
}
