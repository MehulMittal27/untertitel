import AVFoundation
import Foundation
import MeetingKit
import os.log

private extension Logger {
    static let sonioxMeeting = Logger(subsystem: "com.franklioxygen.v2s", category: "sonioxMeeting")
}

// MARK: - Live

/// Soniox for a meeting: text with speaker labels, no translation, endpoint detection
/// off (Soniox's advice for speaker accuracy). The connection stays open through
/// silence so speaker numbers stay stable; the cloud client's other guardrails stay:
/// no connection before there is sound, a pause after three minutes without speech,
/// Stop closes it at once, and every second sent is counted.
final class SonioxMeetingRecognizer: MeetingSpeechRecognizer, @unchecked Sendable {
    struct Callbacks {
        var streamedSeconds: @MainActor (TimeInterval) -> Void = { _ in }
        var stateChanged: @MainActor (CloudEngineState) -> Void = { _ in }
        var failed: @MainActor (CloudEngineFailure) -> Void = { _ in }
    }

    private let apiKey: String
    private let languageCode: String?
    private let resumesAutomatically: Bool
    private let registry: CloudConnectionRegistry
    private let callbacks: Callbacks
    private let makeSocket: (URLRequest) -> OpenAITranslateSocket
    private var client: OpenAITranslateClient?
    private let converter = MeetingAudioConverter(
        outputFormat: AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(OpenAITranslateProtocol.sampleRate),
            channels: 1,
            interleaved: false
        )!
    )
    /// Touched only on the client's queue.
    private var assembler = SpeakerTokenAssembler()
    private var lastProvisional: [SpeakerToken] = []
    private var lastOffset: TimeInterval = 0
    private var onUpdate: (@MainActor (MeetingRecognitionUpdate) -> Void)?

    init(
        apiKey: String,
        languageCode: String?,
        resumesAutomatically: Bool,
        registry: CloudConnectionRegistry = .shared,
        callbacks: Callbacks,
        makeSocket: @escaping (URLRequest) -> OpenAITranslateSocket = { URLSessionTranslateSocket(request: $0) }
    ) {
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.resumesAutomatically = resumesAutomatically
        self.registry = registry
        self.callbacks = callbacks
        self.makeSocket = makeSocket
    }

    static func wire(languageCode: String?) -> SonioxWire {
        var wire = SonioxWire(sourceLanguageCode: languageCode, targetLanguageCode: languageCode ?? "en")
        wire.translates = false
        wire.diarizesSpeakers = true
        wire.detectsEndpoints = false
        return wire
    }

    static func configuration(languageCode: String?, resumesAutomatically: Bool) -> OpenAITranslateClient.Configuration {
        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: languageCode ?? "en")
        configuration.wire = wire(languageCode: languageCode)
        // No voice activity detector here: activity is judged from the audio level.
        configuration.hasVoiceActivitySignal = false
        // Speaker numbers restart with every connection, so silence does not close it.
        configuration.noAudioCloseInterval = .infinity
        configuration.idlePauseInterval = 180
        configuration.resumesAutomatically = resumesAutomatically
        return configuration
    }

    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {
        self.onUpdate = onUpdate
        var handlers = OpenAITranslateClient.Handlers()
        handlers.speakerTokens = { [weak self] final, provisional, offset in
            guard let self else { return }
            self.lastProvisional = provisional
            self.lastOffset = offset
            self.deliver(self.assembler.update(final: final, provisional: provisional, offset: offset))
        }
        handlers.streamedAudio = { [callbacks] seconds, _ in
            Task { @MainActor in callbacks.streamedSeconds(seconds) }
        }
        handlers.stateChanged = { [callbacks] state in
            Task { @MainActor in callbacks.stateChanged(state) }
        }
        handlers.failed = { [callbacks] failure in
            Task { @MainActor in callbacks.failed(failure) }
        }
        let client = OpenAITranslateClient(
            apiKey: apiKey,
            configuration: Self.configuration(languageCode: languageCode, resumesAutomatically: resumesAutomatically),
            handlers: handlers,
            makeSocket: makeSocket,
            registry: registry
        )
        self.client = client
        client.start()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let client, let converted = converter.convert(buffer) else { return }
        client.appendSamples(converted.monoSamples.map(Self.int16))
    }

    func resume() {
        client?.resume()
    }

    func finish() async {
        guard let client else { return }
        client.stop()
        // The last words Soniox had not finalized are kept too.
        let segments: [SpeakerTokenAssembler.Segment] = await withCheckedContinuation { continuation in
            client.queue.async { [self] in
                _ = assembler.update(final: lastProvisional, provisional: [], offset: lastOffset)
                continuation.resume(returning: assembler.flush())
            }
        }
        if let onUpdate {
            for segment in segments {
                await onUpdate(.final(text: segment.text, start: segment.start, end: segment.end, speaker: segment.speaker))
            }
            await onUpdate(.volatile(text: "", start: 0, end: 0))
        }
        self.client = nil
    }

    private func deliver(_ output: SpeakerTokenAssembler.Output) {
        guard let onUpdate else { return }
        let updates = output.finals.map {
            MeetingRecognitionUpdate.final(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker)
        } + [
            MeetingRecognitionUpdate.volatile(
                text: output.draft?.text ?? "",
                start: output.draft?.start ?? 0,
                end: output.draft?.end ?? 0,
                speaker: output.draft?.speaker
            ),
        ]
        Task { @MainActor in
            for update in updates { onUpdate(update) }
        }
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
    }
}

// MARK: - The pass after Stop, in the cloud

/// Soniox's recorded-file service as the pass after Stop: the meeting is uploaded
/// once, transcribed with speaker labels, and the file and transcript are deleted at
/// Soniox right after, also when something fails. The audio goes from memory to
/// Soniox and is never written to disk unencrypted.
struct SonioxFilePass {
    static let baseURL = URL(string: "https://api.soniox.com/v1")!
    static let model = "stt-async-v5"

    var apiKey: String
    /// Soniox's code for the spoken language, or nil to detect it.
    var languageCode: String?
    /// Sends a request; replaceable in tests. Returns the body and status code.
    var send: @Sendable (URLRequest) async throws -> (Data, Int) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    var pollInterval: TimeInterval = 2
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    enum PassError: Error, Equatable {
        case rejected(status: Int, message: String)
        case transcriptionFailed(String)
        case tookTooLong
    }

    func run(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> FinalMeetingPass.Result {
        progress(0)
        let fileID = try await upload(Self.wav(samples: samples))
        var transcriptionID: String?
        do {
            progress(0.3)
            let id = try await createTranscription(fileID: fileID)
            transcriptionID = id
            let duration = Double(samples.count) / MeetingAudioFormat.sampleRate
            try await waitUntilDone(id, duration: duration) { progress(0.3 + 0.6 * $0) }
            let tokens = try await transcript(id)
            await cleanUp(fileID: fileID, transcriptionID: id)
            progress(1)
            return Self.result(from: tokens)
        } catch {
            await cleanUp(fileID: fileID, transcriptionID: transcriptionID)
            throw error
        }
    }

    // MARK: Requests

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func json(_ data: Data, status: Int) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            throw PassError.rejected(status: status, message: object["message"] as? String ?? "")
        }
        return object
    }

    private func upload(_ wav: Data) async throws -> String {
        let boundary = "Untertitel-\(UUID().uuidString)"
        var request = request("files", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, status) = try await send(request)
        guard let id = try json(data, status: status)["id"] as? String else {
            throw PassError.rejected(status: status, message: "no file id")
        }
        return id
    }

    private func createTranscription(fileID: String) async throws -> String {
        var request = request("transcriptions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": Self.model,
            "file_id": fileID,
            "enable_speaker_diarization": true,
            "enable_language_identification": true,
        ]
        if let languageCode {
            payload["language_hints"] = [languageCode]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let (data, status) = try await send(request)
        guard let id = try json(data, status: status)["id"] as? String else {
            throw PassError.rejected(status: status, message: "no transcription id")
        }
        return id
    }

    private func waitUntilDone(_ id: String, duration: TimeInterval, progress: (Double) -> Void) async throws {
        // Soniox works much faster than real time; give it the meeting's length and then some.
        let deadline = Date().addingTimeInterval(max(300, duration * 2))
        var polls = 0.0
        while Date() < deadline {
            let (data, status) = try await send(request("transcriptions/\(id)"))
            let object = try json(data, status: status)
            switch object["status"] as? String {
            case "completed":
                return
            case "error":
                throw PassError.transcriptionFailed(object["error_message"] as? String ?? "")
            default:
                polls += 1
                progress(min(0.95, polls * pollInterval / max(duration / 4, 10)))
                try await sleep(pollInterval)
            }
        }
        throw PassError.tookTooLong
    }

    private func transcript(_ id: String) async throws -> [SpeakerToken] {
        let (data, status) = try await send(request("transcriptions/\(id)/transcript"))
        let object = try json(data, status: status)
        let tokens = object["tokens"] as? [[String: Any]] ?? []
        return tokens.map {
            SpeakerToken(
                text: $0["text"] as? String ?? "",
                speaker: ($0["speaker"] as? String) ?? ($0["speaker"] as? Int).map(String.init),
                startMilliseconds: $0["start_ms"] as? Int ?? 0,
                endMilliseconds: $0["end_ms"] as? Int ?? 0
            )
        }
    }

    /// Deletes the transcript and the file at Soniox. Failures are logged; the caller
    /// cannot do more about them.
    private func cleanUp(fileID: String, transcriptionID: String?) async {
        if let transcriptionID {
            let status = (try? await send(request("transcriptions/\(transcriptionID)", method: "DELETE")))?.1 ?? 0
            if (200..<300).contains(status) == false {
                Logger.sonioxMeeting.error("Soniox transcription not deleted: status \(status)")
            }
        }
        let status = (try? await send(request("files/\(fileID)", method: "DELETE")))?.1 ?? 0
        if (200..<300).contains(status) == false {
            Logger.sonioxMeeting.error("Soniox file not deleted: status \(status)")
        }
    }

    // MARK: Conversions

    static func result(from tokens: [SpeakerToken]) -> FinalMeetingPass.Result {
        let words = SpeakerTokenAssembler.words(from: tokens, offset: 0)
        var turns: [SpeakerTurn] = []
        for word in words {
            let speaker = word.speaker ?? "?"
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = SpeakerTurn(speaker: speaker, start: last.start, end: word.word.end)
            } else {
                turns.append(SpeakerTurn(speaker: speaker, start: word.word.start, end: word.word.end))
            }
        }
        return FinalMeetingPass.Result(words: words.map(\.word), turns: turns)
    }

    /// A 16 kHz mono 16-bit WAV file, in memory.
    static func wav(samples: [Float]) -> Data {
        let sampleRate = UInt32(MeetingAudioFormat.sampleRate)
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        header.append(Data("RIFF".utf8)); append(UInt32(36 + pcm.count)); header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        header.append(Data("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }
}
