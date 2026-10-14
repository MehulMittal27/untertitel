import Foundation
import MeetingKit

/// Who transcribes a meeting live.
enum MeetingLiveEngine: String, Codable, CaseIterable, Sendable {
    case onDevice
    /// Soniox with speaker labels: billed while connected.
    case soniox
}

/// What happens after Stop.
enum MeetingFinalPassChoice: String, Codable, CaseIterable, Sendable {
    /// Parakeet Ultra and the offline speaker pass, when the models are here.
    case onDevice
    /// Soniox's recorded-file service: the meeting is uploaded once.
    case sonioxFile
    /// The live transcript stays as it is.
    case off
}

/// Meeting transcription settings, kept together in the settings file.
struct MeetingSettings: Codable, Equatable, Sendable {
    /// Global shortcut that starts (after the consent note) and stops a meeting.
    var hotkey: HotkeySetting
    /// The spoken language, or Auto-detect.
    var languageID: String
    /// The microphone's unique ID, or nil for the system's default input.
    var microphoneID: String?
    /// Whether transcripts are written to `~/Meeting Transcripts`. Off unless chosen.
    var savesTranscripts: Bool
    var liveEngine: MeetingLiveEngine = .onDevice
    var finalPass: MeetingFinalPassChoice = .onDevice
    /// How many people speak, as chosen before Start, for the speaker pass after Stop.
    var speakerHint: SpeakerCountHint = .auto
    /// Debug: keep the last meeting's audio for a day. Off unless chosen.
    var keepsDiagnosisAudio = false

    static let `default` = MeetingSettings(
        hotkey: .defaultMeeting,
        languageID: LanguageCatalog.autoDetectID,
        microphoneID: nil,
        savesTranscripts: false
    )

    init(hotkey: HotkeySetting, languageID: String, microphoneID: String?, savesTranscripts: Bool = false) {
        self.hotkey = hotkey
        self.languageID = languageID
        self.microphoneID = microphoneID
        self.savesTranscripts = savesTranscripts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = (try? c.decodeIfPresent(HotkeySetting.self, forKey: .hotkey)) ?? Self.default.hotkey
        languageID = (try? c.decodeIfPresent(String.self, forKey: .languageID)) ?? Self.default.languageID
        microphoneID = try? c.decodeIfPresent(String.self, forKey: .microphoneID)
        savesTranscripts = (try? c.decodeIfPresent(Bool.self, forKey: .savesTranscripts)) ?? Self.default.savesTranscripts
        liveEngine = (try? c.decodeIfPresent(MeetingLiveEngine.self, forKey: .liveEngine)) ?? .onDevice
        finalPass = (try? c.decodeIfPresent(MeetingFinalPassChoice.self, forKey: .finalPass)) ?? .onDevice
        speakerHint = (try? c.decodeIfPresent(SpeakerCountHint.self, forKey: .speakerHint)) ?? .auto
        keepsDiagnosisAudio = (try? c.decodeIfPresent(Bool.self, forKey: .keepsDiagnosisAudio)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey, languageID, microphoneID, savesTranscripts, liveEngine, finalPass, speakerHint, keepsDiagnosisAudio
    }
}

/// Which window a Transcript button opens.
enum TranscriptDestination: Equatable {
    case subtitles
    case meeting

    /// The meeting's in Meeting mode or while a meeting runs; the subtitles' otherwise.
    static func resolve(appMode: AppMode, isMeetingActive: Bool) -> TranscriptDestination {
        appMode == .meeting || isMeetingActive ? .meeting : .subtitles
    }
}

/// What the popover is for: subtitles of a call, or a transcript of a meeting in the room.
enum AppMode: String, Codable, CaseIterable, Sendable {
    case subtitles
    case meeting
}

/// One stretch of speech in a meeting, timed from the start of the meeting.
struct MeetingSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// The speaker's number, from 1. Nil until speakers are told apart.
    var speaker: Int?
    /// Said while someone else was talking too.
    var overlapping = false

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String, speaker: Int? = nil, overlapping: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.overlapping = overlapping
    }
}

/// The transcript of one meeting: final segments plus the words still being recognized.
/// Pure value type, so tests can drive it with timed text.
struct MeetingTranscript: Equatable, Sendable {
    private(set) var segments: [MeetingSegment] = []
    /// Provisional text after the last final segment. It may still change.
    private(set) var draft: MeetingSegment?
    /// Names the user gave speakers, by number.
    var speakerNames: [Int: String] = [:]
    /// False while speakers come from the live pass, which can be wrong; true once
    /// the pass after Stop has set them.
    private(set) var speakersAreFinal = false

    var isEmpty: Bool {
        segments.isEmpty && draft == nil
    }

    /// Text that will not change any more.
    mutating func applyFinal(text: String, start: TimeInterval, end: TimeInterval, speaker: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft, draft.end <= end + 0.05 {
            self.draft = nil
        }
        guard trimmed.isEmpty == false else {
            return
        }

        segments.append(MeetingSegment(start: start, end: end, text: trimmed, speaker: speaker))
    }

    /// Provisional text: it replaces the previous provisional text.
    mutating func applyVolatile(text: String, start: TimeInterval, end: TimeInterval, speaker: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            draft = nil
            return
        }

        draft = MeetingSegment(id: draft?.id ?? UUID(), start: start, end: end, text: trimmed, speaker: speaker)
    }

    mutating func clearDraft() {
        draft = nil
    }

    /// Replaces every segment, for the pass after Stop.
    mutating func replaceSegments(_ segments: [MeetingSegment], speakerNames: [Int: String]) {
        self.segments = segments
        self.speakerNames = speakerNames
        speakersAreFinal = true
        draft = nil
    }

    /// Sets the speaker of segments and the draft, for labels that arrive late.
    mutating func relabel(_ speakerFor: (MeetingSegment) -> Int?) {
        for index in segments.indices {
            if let speaker = speakerFor(segments[index]) {
                segments[index].speaker = speaker
            }
        }
        if let draft, let speaker = speakerFor(draft) {
            self.draft?.speaker = speaker
        }
    }

    /// Every speaker number that occurs, in order of first appearance.
    var speakers: [Int] {
        var seen = Set<Int>()
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// The transcript as plain text: one line per segment, with its time and speaker.
    func plainText(speakerName: (Int) -> String, overlappingMark: String = "(overlapping)") -> String {
        segments.map { segment in
            let time = MeetingTimecode.string(segment.start)
            guard let speaker = segment.speaker else {
                return "[\(time)] \(segment.text)"
            }
            let mark = segment.overlapping ? " \(overlappingMark)" : ""
            return "[\(time)] \(speakerName(speaker))\(mark): \(segment.text)"
        }
        .joined(separator: "\n")
    }
}

/// Times in a meeting: "4:05", or "1:02:05" once it runs past an hour.
enum MeetingTimecode {
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
