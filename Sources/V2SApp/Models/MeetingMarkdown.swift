import Foundation

/// A meeting transcript as Markdown: a title with the date, the length and the
/// speakers, then one paragraph per segment with its speaker and time.
enum MeetingMarkdown {
    static func fileName(startedAt: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        return String(
            format: "%04d-%02d-%02d %02d-%02d Meeting.md",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    static func document(
        transcript: MeetingTranscript,
        startedAt: Date,
        duration: TimeInterval,
        speakerName: (Int) -> String,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"

        var lines = ["# Meeting, \(formatter.string(from: startedAt))", ""]
        lines.append("- Duration: \(MeetingTimecode.string(duration))")
        let speakers = transcript.speakers.map(speakerName)
        if speakers.isEmpty == false {
            lines.append("- Speakers: \(speakers.joined(separator: ", "))")
        }
        lines.append("")

        var previousSpeaker: Int??
        for segment in transcript.segments {
            let time = MeetingTimecode.string(segment.start)
            let text = escaped(segment.text)
            if let speaker = segment.speaker {
                if segment.overlapping {
                    lines.append("**\(escaped(speakerName(speaker)))** (overlapping) [\(time)]  ")
                } else if previousSpeaker != .some(speaker) {
                    lines.append("**\(escaped(speakerName(speaker)))** [\(time)]  ")
                } else {
                    lines.append("[\(time)]  ")
                }
            } else {
                lines.append("[\(time)]  ")
            }
            lines.append(text)
            lines.append("")
            previousSpeaker = .some(segment.speaker)
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps speech from being read as Markdown: a sentence starting with "#" or "-",
    /// or containing "*", stays plain text.
    static func escaped(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "`", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        if let first = result.first, "#->+".contains(first) {
            result = "\\" + result
        }
        return result
    }
}
