import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 16 kHz mono 32-bit float: the format every meeting model takes, and the clock the
/// transcript's times are counted in.
enum MeetingAudioFormat {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
}

/// Where meeting audio comes from. Buffers arrive in `MeetingAudioFormat`, on the
/// source's own queue.
protocol MeetingAudioSource: AnyObject {
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Converts whatever a device delivers into `MeetingAudioFormat`. Keeps its converter
/// between buffers, so resampling stays continuous.
final class MeetingAudioConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat = MeetingAudioFormat.format) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else {
            return nil
        }
        if buffer.format == outputFormat {
            return buffer
        }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else {
            return nil
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}

/// The microphone, through AVCaptureSession like the subtitles' microphone source. It
/// only reads the input, so Wispr Flow and other apps can use the microphone as well.
final class MicrophoneMeetingAudioSource: NSObject, MeetingAudioSource, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    enum CaptureError: Error, Equatable {
        case noMicrophone
        case cannotUseMicrophone
    }

    private let deviceID: String?
    private let queue = DispatchQueue(label: "Untertitel.meeting.microphone")
    private var session: AVCaptureSession?
    private let converter = MeetingAudioConverter()
    private var onAudio: ((AVAudioPCMBuffer) -> Void)?

    /// - Parameter deviceID: A microphone's unique ID; nil, or one that is no longer
    ///   connected, uses the system's default input.
    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            throw CaptureError.noMicrophone
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.cannotUseMicrophone
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()

        queue.sync {
            self.onAudio = onAudio
        }
        self.session = session
        session.startRunning()
    }

    func stop() {
        session?.stopRunning()
        session = nil
        queue.sync {
            onAudio = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onAudio,
              let buffer = Self.pcmBuffer(from: sampleBuffer),
              let converted = converter.convert(buffer) else {
            return
        }
        onAudio(converted)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }

        var streamDescription = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

// MARK: - Speech recognition

/// Text a meeting recognizer has heard, timed from the start of the meeting.
enum MeetingRecognitionUpdate: Equatable, Sendable {
    /// Provisional: replaced by the next provisional text or by final text. `speaker`
    /// is set when the recognizer itself tells speakers apart.
    case volatile(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil)
    case final(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil)
}

/// Turns meeting audio into text as it arrives.
protocol MeetingSpeechRecognizer: AnyObject {
    /// Prepares the recognizer. `onUpdate` is called on the main actor.
    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws
    /// Takes audio in `MeetingAudioFormat`. Called on the audio source's queue.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Recognizes what is left and stops. Every update has been delivered on return.
    func finish() async
    /// Takes up a recognizer that paused itself (a cloud engine after long silence).
    func resume()
}

extension MeetingSpeechRecognizer {
    func resume() {}
}

enum MeetingRecognizerError: Error, Equatable {
    case languageNotSupported(String)
}

/// Apple's SpeechAnalyzer, on this Mac, for one chosen language. One transcriber
/// reports provisional text for the live line; a second reports only final text,
/// which it always delivers (the first may leave final text unreported when it did
/// not change).
@available(macOS 26.0, *)
final class AppleMeetingRecognizer: MeetingSpeechRecognizer, @unchecked Sendable {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTasks: [Task<Void, Never>] = []
    private var analyzerTask: Task<Void, Never>?
    private var converter: MeetingAudioConverter?

    init(locale: Locale) {
        self.locale = locale
    }

    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw MeetingRecognizerError.languageNotSupported(locale.identifier)
        }

        let live = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let finals = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [live, finals]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(
            modules: [live, finals],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [live, finals],
            considering: MeetingAudioFormat.format
        ) ?? MeetingAudioFormat.format
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.converter = MeetingAudioConverter(outputFormat: format)
        self.continuation = continuation
        self.analyzer = analyzer

        resultTasks = [
            Task {
                do {
                    for try await result in live.results {
                        let update = MeetingRecognitionUpdate.volatile(
                            text: String(result.text.characters),
                            start: result.range.start.seconds,
                            end: result.range.end.seconds
                        )
                        await onUpdate(update)
                    }
                } catch {}
            },
            Task {
                do {
                    for try await result in finals.results {
                        let update = MeetingRecognitionUpdate.final(
                            text: String(result.text.characters),
                            start: result.range.start.seconds,
                            end: result.range.end.seconds
                        )
                        await onUpdate(update)
                    }
                } catch {}
            },
        ]
        analyzerTask = Task {
            try? await analyzer.start(inputSequence: stream)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter?.convert(buffer) else {
            return
        }
        continuation?.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await analyzerTask?.value
        for task in resultTasks {
            await task.value
        }
        analyzer = nil
    }
}
