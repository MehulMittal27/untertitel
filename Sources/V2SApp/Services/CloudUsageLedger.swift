import Foundation

/// Seconds of audio streamed to the cloud engine, per local calendar day. Kept on this
/// Mac only, as a guide to cost; the provider's dashboard is the source of truth.
struct CloudUsageLedger: Codable, Equatable {
    private(set) var secondsByDay: [String: Double] = [:]

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

    mutating func add(seconds: Double, on date: Date, calendar: Calendar = .current) {
        guard seconds > 0 else {
            return
        }

        secondsByDay[Self.dayKey(for: date, calendar: calendar), default: 0] += seconds

        // Keys sort chronologically, so the oldest days go first.
        let overflow = secondsByDay.count - Self.retainedDayCount
        if overflow > 0 {
            for key in secondsByDay.keys.sorted().prefix(overflow) {
                secondsByDay.removeValue(forKey: key)
            }
        }
    }

    static func estimatedCostUSD(seconds: Double) -> Double {
        seconds / 60 * RecognitionEngine.openAITranslateUSDPerMinute
    }
}

@MainActor
final class CloudUsageStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = appSupportRoot.appendingPathComponent("v2s", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("cloud-usage.json")
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
