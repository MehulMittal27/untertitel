import AVFoundation
import Foundation
import MeetingKit
import os.log

private extension Logger {
    static let fluid = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingModels")
}

/// Tells speakers apart while a meeting runs.
protocol MeetingSpeakerTracking: AnyObject {
    /// Takes 16 kHz mono samples. Called on the audio source's queue.
    func append(_ samples: [Float])
    /// Who spoke when, so far.
    var turns: [SpeakerTurn] { get }
}

extension MeetingSpeakerTracking {
    var speakerCount: Int {
        Set(turns.map(\.speaker)).count
    }
}

/// Keeps a meeting's audio for the pass after Stop.
protocol MeetingAudioSpooling: AnyObject {
    func append(_ samples: [Float])
    func readAll() throws -> [Float]
    func delete()
}

extension MeetingAudioSpool: MeetingAudioSpooling {}

extension AVAudioPCMBuffer {
    /// The first channel's samples.
    var monoSamples: [Float] {
        guard let channel = floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(frameLength)))
    }
}

/// FluidAudio's live speaker model, fed on its own queue so the microphone never waits.
final class FluidSpeakerTracker: MeetingSpeakerTracking, @unchecked Sendable {
    private let tracker: LiveSpeakerTracker
    private let queue = DispatchQueue(label: "Untertitel.meeting.speakers")

    init(tracker: LiveSpeakerTracker) {
        self.tracker = tracker
    }

    static func load() async -> FluidSpeakerTracker? {
        do {
            return FluidSpeakerTracker(tracker: try await LiveSpeakerTracker.load())
        } catch {
            Logger.fluid.error("Live speaker model did not load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func append(_ samples: [Float]) {
        queue.async { [tracker] in
            do {
                try tracker.append(samples)
            } catch {
                Logger.fluid.error("Live speaker model failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    var turns: [SpeakerTurn] {
        tracker.turns
    }
}

/// FluidAudio's live multilingual model, for Auto-detect. It works in chunks, so
/// audio is gathered into half-second batches and recognized in order.
final class FluidLiveRecognizer: MeetingSpeechRecognizer, @unchecked Sendable {
    static let batchSamples = 8_000

    private var transcriber: LiveMultilingualTranscriber?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var worker: Task<Void, Never>?
    private let gatherLock = NSLock()
    private var gathered: [Float] = []

    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {
        let transcriber = try await LiveMultilingualTranscriber.load()
        self.transcriber = transcriber
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        worker = Task {
            var segmenter = LiveWordSegmenter()
            var audioTime: TimeInterval = 0
            var words: [TimedWord] = []
            for await batch in stream {
                audioTime += TimeInterval(batch.count) / MeetingAudioFormat.sampleRate
                do {
                    words = try await transcriber.process(batch)
                } catch {
                    Logger.fluid.error("Live speech model failed: \(String(describing: error), privacy: .public)")
                    continue
                }
                await Self.deliver(segmenter.update(words: words, audioTime: audioTime), to: onUpdate)
            }
            if let last = try? await transcriber.finish() {
                words = last
            }
            await Self.deliver(segmenter.update(words: words, audioTime: audioTime, flush: true), to: onUpdate)
        }
    }

    private static func deliver(
        _ output: LiveWordSegmenter.Output,
        to onUpdate: @MainActor (MeetingRecognitionUpdate) -> Void
    ) async {
        for final in output.finals {
            await onUpdate(.final(text: final.text, start: final.start, end: final.end))
        }
        let draft = output.draft
        await onUpdate(.volatile(text: draft?.text ?? "", start: draft?.start ?? 0, end: draft?.end ?? 0))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let batch: [Float]? = gatherLock.withLock {
            gathered.append(contentsOf: buffer.monoSamples)
            guard gathered.count >= Self.batchSamples else { return nil }
            defer { gathered.removeAll(keepingCapacity: true) }
            return gathered
        }
        if let batch {
            continuation?.yield(batch)
        }
    }

    func finish() async {
        let rest = gatherLock.withLock { () -> [Float] in
            defer { gathered.removeAll() }
            return gathered
        }
        if rest.isEmpty == false {
            continuation?.yield(rest)
        }
        continuation?.finish()
        continuation = nil
        await worker?.value
        worker = nil
        transcriber = nil
    }
}
