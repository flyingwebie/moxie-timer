import XCTest
@testable import MoxieTimer

final class DurationFormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(DurationFormat.clock(0), "0:00:00")
        XCTAssertEqual(DurationFormat.clock(65), "0:01:05")
        XCTAssertEqual(DurationFormat.clock(3661), "1:01:01")
        XCTAssertEqual(DurationFormat.clock(-5), "0:00:00")
    }

    func testShort() {
        XCTAssertEqual(DurationFormat.short(0), "0m")
        XCTAssertEqual(DurationFormat.short(29), "0m")   // rounds to nearest minute
        XCTAssertEqual(DurationFormat.short(31), "1m")
        XCTAssertEqual(DurationFormat.short(30 * 60), "30m")
        XCTAssertEqual(DurationFormat.short(90 * 60), "1h 30m")
        XCTAssertEqual(DurationFormat.short(2 * 3600), "2h")
    }

    func testParseMinutesAndHours() {
        XCTAssertEqual(DurationFormat.parse("45m"), 45 * 60)
        XCTAssertEqual(DurationFormat.parse("1.5h"), 1.5 * 3600)
        XCTAssertEqual(DurationFormat.parse("1h 30m"), 90 * 60)
        XCTAssertEqual(DurationFormat.parse("90"), 90 * 60)  // bare number = minutes
        XCTAssertEqual(DurationFormat.parse("30s"), 30)
    }

    func testParseClockShorthand() {
        XCTAssertEqual(DurationFormat.parse("1:30"), 90 * 60)
        XCTAssertEqual(DurationFormat.parse("1:30:15"), 3600 + 30 * 60 + 15)
    }

    func testParseInvalid() {
        XCTAssertNil(DurationFormat.parse(""))
        XCTAssertNil(DurationFormat.parse("not a duration"))
        XCTAssertNil(DurationFormat.parse("1:2:3:4"))
    }
}
