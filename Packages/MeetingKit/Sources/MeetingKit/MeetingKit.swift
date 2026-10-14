import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingModels")

/// How many people the user says are in the meeting, for the speaker pass after Stop.
public enum SpeakerCountHint: String, Codable, CaseIterable, Sendable {
    case auto
    case two
    case three
    /// Four or more.
    case fourOrMore
}

// The app's only contact with FluidAudio. Everything here runs on this Mac; the
// network is used only by `MeetingModels.download`, which the user starts from
// Settings. Every other call runs with FluidAudio's offline switch on.

/// A word and the stretch of audio it was heard in, in seconds from the start.
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One speaker talking, from `start` to `end`. Speakers are told apart, not named:
/// `speaker` is only an identity within one run.
public struct SpeakerTurn: Equatable, Sendable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

// MARK: - Models

/// The four models meetings use, downloaded once from Hugging Face and kept in
/// FluidAudio's cache in Application Support:
/// the live multilingual speech model (Nemotron, 1.12 s chunks, Latin languages),
/// Parakeet Ultra for the pass after Stop, LS-EEND (meeting-tuned) for live
/// speakers and pyannote community-1 with VBx for the speakers after Stop.
public enum MeetingModels {
    public static let liveChunkMilliseconds = 1_120

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Written after every model downloaded and loaded once, so "installed" never
    /// means "half downloaded".
    static var markerURL: URL {
        directory.appendingPathComponent("untertitel-meeting-models.json")
    }

    /// The folders these models live in, inside `directory`.
    static var folders: [URL] {
        [
            Repo.nemotronMultilingual.folderName,
            Repo.parakeetUltra.folderName,
            Repo.lseendAmi.folderName,
            Repo.diarizer.folderName,
        ].map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Blocks every download. Called at launch and after a download finishes.
    public static func blockDownloads() {
        ModelHub.offlineMode = true
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
            && folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Disk space the models take.
    public static func installedBytes() -> Int64 {
        folders.reduce(0) { total, folder in
            total + Self.size(of: folder)
        }
    }

    /// Downloads and loads each model once. `progress` gets 0...1 on an arbitrary
    /// thread. Downloads are blocked again when it returns, also after a failure.
    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }

        // Weighted roughly by size: live model 590 MB, Ultra 613 MB, the others small.
        func stage(_ base: Double, _ weight: Double) -> ProgressHandler {
            { update in progress(base + weight * min(max(update.fractionCompleted, 0), 1)) }
        }

        progress(0)
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "en",
            chunkMs: liveChunkMilliseconds,
            progressHandler: stage(0, 0.45)
        )
        _ = try await AsrModels.download(version: .ultra, progressHandler: stage(0.45, 0.45))
        _ = try await LSEENDModel.loadFromHuggingFace(variant: .ami, stepSize: .step100ms, progressHandler: stage(0.9, 0.03))
        _ = try await OfflineDiarizerModels.load(progressHandler: stage(0.93, 0.07))

        let marker = ["fluidAudio": "0.17.7", "downloadedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL, options: .atomic)
        progress(1)
    }

    /// Removes the models. Meetings then run with Apple's speech recognition only.
    public static func delete() throws {
        try? FileManager.default.removeItem(at: markerURL)
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Live speakers

/// Tells speakers apart while the meeting runs (LS-EEND, tuned on meeting
/// recordings, up to 10 speakers). Feed it 16 kHz mono audio from one serial queue.
public final class LiveSpeakerTracker: @unchecked Sendable {
    private let diarizer: LSEENDDiarizer
    private let lock = NSLock()
    private var currentTurns: [SpeakerTurn] = []

    private init(diarizer: LSEENDDiarizer) {
        self.diarizer = diarizer
    }

    public static func load() async throws -> LiveSpeakerTracker {
        let model = try await LSEENDModel.loadFromHuggingFace(variant: .ami, stepSize: .step100ms)
        return LiveSpeakerTracker(diarizer: try LSEENDDiarizer(model: model))
    }

    public func append(_ samples: [Float]) throws {
        guard try diarizer.process(samples: samples, sourceSampleRate: 16_000) != nil else {
            return
        }
        let turns = diarizer.timeline.speakers.values.flatMap { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).map { segment in
                SpeakerTurn(
                    speaker: String(segment.speakerIndex),
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(Float(segment.endFrame) * segment.frameDurationSeconds)
                )
            }
        }
        .sorted { $0.start < $1.start }
        lock.withLock { currentTurns = turns }
    }

    public var turns: [SpeakerTurn] {
        lock.withLock { currentTurns }
    }

    /// How many speakers it has told apart so far.
    public var speakerCount: Int {
        Set(turns.map(\.speaker)).count
    }
}

// MARK: - Live multilingual speech-to-text

/// The live model for Auto-detect: it finds the language itself and handles a
/// meeting that switches between languages. Text arrives once per 1.12 s chunk.
public final class LiveMultilingualTranscriber: @unchecked Sendable {
    private let manager: StreamingNemotronMultilingualAsrManager

    private init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
    }

    public static func load() async throws -> LiveMultilingualTranscriber {
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "en",
            chunkMs: MeetingModels.liveChunkMilliseconds
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: directory)
        await manager.setLanguage("auto")
        return LiveMultilingualTranscriber(manager: manager)
    }

    /// Takes 16 kHz mono audio and returns every word heard so far, timed.
    public func process(_ samples: [Float]) async throws -> [TimedWord] {
        _ = try await manager.process(samples: samples)
        return Self.words(from: await manager.getTokenTimings())
    }

    /// Recognizes what is left and returns every word of the run.
    public func finish() async throws -> [TimedWord] {
        let result = try await manager.finishWithTokenTimings()
        return Self.words(from: result.timings)
    }

    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        buildWordTimings(from: tokens).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}

// MARK: - The pass after Stop

/// Transcribes the whole meeting again with Parakeet Ultra and tells the speakers
/// apart with pyannote community-1 and VBx clustering, both on this Mac.
public enum FinalMeetingPass {
    public struct Result: Sendable {
        public let words: [TimedWord]
        public let turns: [SpeakerTurn]
        /// How the speakers were found, for the log and the diagnosis file.
        public let diagnostics: [String: String]

        public init(words: [TimedWord], turns: [SpeakerTurn], diagnostics: [String: String] = [:]) {
            self.words = words
            self.turns = turns
            self.diagnostics = diagnostics
        }

        public var speakerCount: Int {
            Set(turns.map(\.speaker)).count
        }
    }

    /// The speaker pass's settings for a hint: community-1 defaults, with the
    /// number of speakers fixed (2, 3) or bounded (4 or more) when the user says so.
    /// Overlapping speech is kept (`keepsOverlaps`): FluidAudio's default trims it by
    /// cutting the later speaker, which hands an interruption to the person interrupted.
    public static func diarizerConfig(hint: SpeakerCountHint, keepsOverlaps: Bool = true) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.postProcessing.exclusiveSegments = keepsOverlaps == false
        switch hint {
        case .auto: break
        case .two: config.clustering.numSpeakers = 2
        case .three: config.clustering.numSpeakers = 3
        case .fourOrMore: config.clustering.minSpeakers = 4
        }
        return config
    }

    /// - Parameter samples: The whole meeting, 16 kHz mono.
    public static func run(
        samples: [Float],
        speakerHint: SpeakerCountHint = .auto,
        keepsOverlaps: Bool = true,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        progress(0)
        let config = diarizerConfig(hint: speakerHint, keepsOverlaps: keepsOverlaps)
        let diarizer = OfflineDiarizerManager(config: config)
        try await diarizer.prepareModels()
        let diarization = try await diarizer.process(audio: samples) { done, total in
            progress(0.5 * Double(done) / Double(max(total, 1)))
        }
        let turns = diarization.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }

        progress(0.5)
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
        let asr = AsrManager(models: models)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        let diagnostics: [String: String] = [
            "audioSeconds": String(format: "%.1f", Double(samples.count) / 16_000),
            "speakerHint": speakerHint.rawValue,
            "clusteringThreshold": String(config.clustering.threshold),
            "numSpeakers": config.clustering.numSpeakers.map(String.init) ?? "auto",
            "minSpeakers": config.clustering.minSpeakers.map(String.init) ?? "-",
            "speakerTurns": String(turns.count),
            "speakersFound": String(Set(turns.map(\.speaker)).count),
            "words": String(words.count),
            "peakLevel": String(format: "%.3f", samples.map(abs).max() ?? 0),
        ]
        log.log("Speaker pass after Stop: \(diagnostics.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public)")
        progress(1)
        return Result(words: words, turns: turns, diagnostics: diagnostics)
    }
}
