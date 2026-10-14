import AVFoundation
import MeetingKit
import XCTest
@testable import v2s

/// Plays a recording into a meeting as if it came from the microphone, in 100 ms
/// buffers, as fast as the models take it.
private final class FileMeetingAudioSource: MeetingAudioSource, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "test.meeting.file")
    private var stopped = false
    let finishedFeeding = XCTestExpectation(description: "whole file fed")

    init(url: URL) {
        self.url = url
    }

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let converter = MeetingAudioConverter()
        queue.async {
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while self.stopped == false, file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
                try? file.read(into: buffer, frameCount: chunk)
                if let converted = converter.convert(buffer) {
                    onAudio(converted)
                }
                // A little slower than flat out, so the speaker model keeps pace.
                Thread.sleep(forTimeInterval: 0.01)
            }
            self.finishedFeeding.fulfill()
        }
    }

    func stop() {
        queue.sync { stopped = true }
    }
}

/// Runs the real FluidAudio models end to end on a recording. Opt-in: set
/// UNTERTITEL_MEETING_E2E_AUDIO to a 16 kHz mono recording with several speakers.
/// Downloads the meeting models first if they are missing.
@MainActor
final class MeetingEndToEndTests: XCTestCase {
    func testARealMeetingGetsLiveTextSpeakersAndTheImprovedTranscript() async throws {
        guard let path = ProcessInfo.processInfo.environment["UNTERTITEL_MEETING_E2E_AUDIO"] else {
            throw XCTSkip("Set UNTERTITEL_MEETING_E2E_AUDIO to run the meeting models end to end.")
        }
        if MeetingModels.isInstalled == false {
            try await MeetingModels.download { _ in }
        }
        MeetingModels.blockDownloads()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: { SourceCatalogSnapshot(applications: [], microphones: []) }),
            cloudConnectionRegistry: CloudConnectionRegistry()
        )
        let source = FileMeetingAudioSource(url: URL(fileURLWithPath: path))
        var spoolURL: URL?
        var environment = MeetingController.Environment.live(model: model)
        environment.makeAudioSource = { _ in source }
        environment.requestMicrophoneAccess = { true }
        environment.makeAudioSpool = {
            let spool = try? MeetingAudioSpool(folder: directory.appendingPathComponent("spool"))
            spoolURL = spool?.fileURL
            return spool
        }
        let meeting = MeetingController(environment: environment)

        meeting.prepareToStart()
        let started = Date()
        await meeting.start()
        XCTAssertEqual(meeting.state, .running, "\(meeting.state)")
        await fulfillment(of: [source.finishedFeeding], timeout: 300)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let live = meeting.transcript
        print("LIVE (\(String(format: "%.1f", Date().timeIntervalSince(started))) s):")
        print(live.plainText { "Speaker \($0)" })

        await meeting.stop()
        print("AFTER STOP (\(String(format: "%.1f", Date().timeIntervalSince(started))) s):")
        print(meeting.copyText)

        XCTAssertFalse(live.segments.isEmpty, "live text arrived")
        XCTAssertGreaterThanOrEqual(Set(live.segments.compactMap(\.speaker)).count, 2, "live speakers told apart")
        XCTAssertGreaterThanOrEqual(meeting.transcript.speakers.count, 2, "speakers after Stop")
        XCTAssertTrue(meeting.copyText.localizedCaseInsensitiveContains("Budget"))
        XCTAssertTrue(meeting.copyText.localizedCaseInsensitiveContains("cloud"))
        XCTAssertEqual(meeting.state, .idle)
        if let spoolURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: spoolURL.path), "the audio is deleted")
        }
    }
}
