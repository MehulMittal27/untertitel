import XCTest
@testable import v2s

final class CloudUsageLedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testUsageAccumulatesPerLocalDay() {
        var ledger = CloudUsageLedger()
        ledger.add(seconds: 60, transcribedSeconds: 60, on: date(2026, 10, 12, hour: 9), calendar: calendar)
        ledger.add(seconds: 30, transcribedSeconds: 0, on: date(2026, 10, 12, hour: 23), calendar: calendar)
        ledger.add(seconds: 5, transcribedSeconds: 5, on: date(2026, 10, 13, hour: 0), calendar: calendar)

        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 12), calendar: calendar), 90)
        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 13), calendar: calendar), 5)
        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 14), calendar: calendar), 0)
    }

    func testAudioTranscribedInTheSourceLanguageIsCountedSeparately() {
        var ledger = CloudUsageLedger()
        ledger.add(seconds: 60, transcribedSeconds: 60, on: date(2026, 10, 12, hour: 9), calendar: calendar)
        ledger.add(seconds: 30, transcribedSeconds: 0, on: date(2026, 10, 12, hour: 23), calendar: calendar)
        // More transcribed than streamed cannot happen; it is capped rather than trusted.
        ledger.add(seconds: 10, transcribedSeconds: 25, on: date(2026, 10, 12, hour: 23), calendar: calendar)

        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 12), calendar: calendar), 100)
        XCTAssertEqual(ledger.transcribedSeconds(on: date(2026, 10, 12), calendar: calendar), 70)
        XCTAssertEqual(ledger.transcribedSeconds(on: date(2026, 10, 13), calendar: calendar), 0)
    }

    /// Before the two models were told apart the original line was always on, so every
    /// second in an older file was billed by both.
    func testAnOlderUsageFileCountsAllItsAudioAsTranscribed() throws {
        let json = #"{ "secondsByDay": { "2026-10-12": 409.2 } }"#

        let ledger = try JSONDecoder().decode(CloudUsageLedger.self, from: Data(json.utf8))

        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 12), calendar: calendar), 409.2)
        XCTAssertEqual(ledger.transcribedSeconds(on: date(2026, 10, 12), calendar: calendar), 409.2)
        XCTAssertEqual(
            CloudUsageLedger.estimatedCostUSD(seconds: 409.2, transcribedSeconds: 409.2),
            409.2 / 60 * 0.051,
            accuracy: 0.0001
        )
    }

    func testOldDaysAreDropped() {
        var ledger = CloudUsageLedger()
        let start = date(2026, 1, 1)
        for offset in 0..<(CloudUsageLedger.retainedDayCount + 5) {
            ledger.add(
                seconds: 1,
                transcribedSeconds: 1,
                on: calendar.date(byAdding: .day, value: offset, to: start)!,
                calendar: calendar
            )
        }

        XCTAssertEqual(ledger.secondsByDay.count, CloudUsageLedger.retainedDayCount)
        XCTAssertEqual(ledger.transcribedSecondsByDay.count, CloudUsageLedger.retainedDayCount)
        XCTAssertEqual(ledger.seconds(on: start, calendar: calendar), 0)
    }

    func testCostFollowsTheListPricesOfBothModels() {
        // Translation alone: $0.034 per minute.
        XCTAssertEqual(CloudUsageLedger.estimatedCostUSD(seconds: 3_600, transcribedSeconds: 0), 2.04, accuracy: 0.0001)
        // With the original-language line, $0.017 per minute on top.
        XCTAssertEqual(
            CloudUsageLedger.estimatedCostUSD(seconds: 3_600, transcribedSeconds: 3_600),
            3.06,
            accuracy: 0.0001
        )
        XCTAssertEqual(CloudUsageLedger.estimatedCostUSD(seconds: 3_600, transcribedSeconds: 1_800), 2.55, accuracy: 0.0001)
        XCTAssertEqual(CloudUsageLedger.estimatedCostUSD(seconds: 0, transcribedSeconds: 0), 0)

        XCTAssertEqual(RecognitionEngine.openAIUSDPerHour(transcribesSource: false), 2.04, accuracy: 0.0001)
        XCTAssertEqual(RecognitionEngine.openAIUSDPerHour(transcribesSource: true), 3.06, accuracy: 0.0001)
    }

    @MainActor
    func testLedgerSurvivesSaveAndLoad() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-cloud-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var ledger = CloudUsageLedger()
        ledger.add(seconds: 42, transcribedSeconds: 12, on: date(2026, 10, 12), calendar: calendar)

        CloudUsageStore(fileURL: fileURL).save(ledger)

        XCTAssertEqual(CloudUsageStore(fileURL: fileURL).load(), ledger)
        XCTAssertEqual(CloudUsageStore(fileURL: fileURL.appendingPathExtension("missing")).load(), CloudUsageLedger())
    }
}
