import Foundation

/// Seconds of audio streamed to the cloud engine, per local calendar day. Kept on this
/// Mac only, as a guide to cost; the provider's dashboard is the source of truth.
struct CloudUsageLedger: Codable, Equatable {
    private(set) var secondsByDay: [String: Double] = [:]
    /// The part of `secondsByDay` that was also transcribed in the source language,
    /// which a second model bills separately.
    private(set) var transcribedSecondsByDay: [String: Double] = [:]
    /// Seconds streamed to Soniox, which has its own price. Not part of `secondsByDay`.
    private(set) var sonioxSecondsByDay: [String: Double] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        secondsByDay = (try? container.decodeIfPresent([String: Double].self, forKey: .secondsByDay)) ?? [:]
        // A file from before the two were told apart: transcription was always on.
        transcribedSecondsByDay = (try? container.decodeIfPresent(
            [String: Double].self,
            forKey: .transcribedSecondsByDay
        )) ?? secondsByDay
        sonioxSecondsByDay = (try? container.decodeIfPresent([String: Double].self, forKey: .sonioxSecondsByDay)) ?? [:]
    }

    func sonioxSeconds(on date: Date, calendar: Calendar = .current) -> Double {
        sonioxSecondsByDay[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    mutating func addSoniox(seconds: Double, on date: Date, calendar: Calendar = .current) {
        guard seconds > 0 else {
            return
        }

        sonioxSecondsByDay[Self.dayKey(for: date, calendar: calendar), default: 0] += seconds
        let overflow = sonioxSecondsByDay.count - Self.retainedDayCount
        if overflow > 0 {
            for oldKey in sonioxSecondsByDay.keys.sorted().prefix(overflow) {
                sonioxSecondsByDay.removeValue(forKey: oldKey)
            }
        }
    }

    /// Days kept in the file. Older days are dropped when new usage is recorded.
    static let retainedDayCount = 60

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    func seconds(on date: Date, calendar: Calendar = .current) -> Double {
        secondsByDay[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    func transcribedSeconds(on date: Date, calendar: Calendar = .current) -> Double {
        transcribedSecondsByDay[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    /// - Parameter transcribedSeconds: How much of `seconds` was also transcribed in
    ///   the source language.
    mutating func add(
        seconds: Double,
        transcribedSeconds: Double,
        on date: Date,
        calendar: Calendar = .current
    ) {
        guard seconds > 0 else {
            return
        }

        let key = Self.dayKey(for: date, calendar: calendar)
        secondsByDay[key, default: 0] += seconds
        let transcribed = min(max(transcribedSeconds, 0), seconds)
        if transcribed > 0 {
            transcribedSecondsByDay[key, default: 0] += transcribed
        }

        // Keys sort chronologically, so the oldest days go first.
        let overflow = secondsByDay.count - Self.retainedDayCount
        if overflow > 0 {
            for oldKey in secondsByDay.keys.sorted().prefix(overflow) {
                secondsByDay.removeValue(forKey: oldKey)
                transcribedSecondsByDay.removeValue(forKey: oldKey)
            }
        }
    }

    /// Both models bill by audio duration: translation for all of it, source
    /// transcription for the part it was switched on for.
    static func estimatedCostUSD(seconds: Double, transcribedSeconds: Double, sonioxSeconds: Double = 0) -> Double {
        seconds / 60 * RecognitionEngine.openAITranslateUSDPerMinute
            + transcribedSeconds / 60 * RecognitionEngine.openAISourceTranscriptionUSDPerMinute
            + sonioxSeconds / 60 * RecognitionEngine.sonioxUSDPerMinute
    }
}

@MainActor
final class CloudUsageStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppDataDirectory.url.appendingPathComponent("cloud-usage.json")
        }
    }

    func load() -> CloudUsageLedger {
        guard let data = try? Data(contentsOf: fileURL),
              let ledger = try? JSONDecoder().decode(CloudUsageLedger.self, from: data) else {
            return CloudUsageLedger()
        }

        return ledger
    }

    func save(_ ledger: CloudUsageLedger) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: fileURL, options: [.atomic])
        } catch {
            fputs("Failed to save cloud usage: \(error)\n", stderr)
        }
    }
}
