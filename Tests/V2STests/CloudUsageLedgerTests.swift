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
        ledger.add(seconds: 60, on: date(2026, 10, 12, hour: 9), calendar: calendar)
        ledger.add(seconds: 30, on: date(2026, 10, 12, hour: 23), calendar: calendar)
        ledger.add(seconds: 5, on: date(2026, 10, 13, hour: 0), calendar: calendar)

        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 12), calendar: calendar), 90)
        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 13), calendar: calendar), 5)
        XCTAssertEqual(ledger.seconds(on: date(2026, 10, 14), calendar: calendar), 0)
    }

    func testOldDaysAreDropped() {
        var ledger = CloudUsageLedger()
        let start = date(2026, 1, 1)
        for offset in 0..<(CloudUsageLedger.retainedDayCount + 5) {
            ledger.add(seconds: 1, on: calendar.date(byAdding: .day, value: offset, to: start)!, calendar: calendar)
        }

        XCTAssertEqual(ledger.secondsByDay.count, CloudUsageLedger.retainedDayCount)
        XCTAssertEqual(ledger.seconds(on: start, calendar: calendar), 0)
    }

    func testCostFollowsTheListPricePerMinute() {
        XCTAssertEqual(CloudUsageLedger.estimatedCostUSD(seconds: 3_600), 2.04, accuracy: 0.0001)
        XCTAssertEqual(CloudUsageLedger.estimatedCostUSD(seconds: 0), 0)
    }

    @MainActor
    func testLedgerSurvivesSaveAndLoad() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-cloud-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var ledger = CloudUsageLedger()
        ledger.add(seconds: 42, on: date(2026, 10, 12), calendar: calendar)

        CloudUsageStore(fileURL: fileURL).save(ledger)

        XCTAssertEqual(CloudUsageStore(fileURL: fileURL).load(), ledger)
        XCTAssertEqual(CloudUsageStore(fileURL: fileURL.appendingPathExtension("missing")).load(), CloudUsageLedger())
    }
}
