import XCTest
@testable import MoxieTimer

@MainActor
final class MoxieMCPParsingTests: XCTestCase {
    // MARK: parseDate

    func testParseDateWithFractionalSeconds() {
        let date = MoxieMCP.parseDate("2024-05-01T10:30:00.500Z")
        XCTAssertNotNil(date)
    }

    func testParseDateWithoutFractionalSeconds() {
        let date = MoxieMCP.parseDate("2024-05-01T10:30:00Z")
        XCTAssertNotNil(date)
    }

    func testParseDateInvalid() {
        XCTAssertNil(MoxieMCP.parseDate("not a date"))
    }

    // MARK: findEntry

    func testFindEntryAtTopLevel() {
        let object: [String: Any] = ["timerStart": "2024-05-01T10:00:00Z", "id": "abc"]
        let entry = MoxieMCP.findEntry(in: object)
        XCTAssertEqual(entry?.id, "abc")
    }

    func testFindEntryNestedOneLevel() {
        let object: [String: Any] = ["timer": ["timerStart": "2024-05-01T10:00:00Z", "id": "nested"]]
        let entry = MoxieMCP.findEntry(in: object)
        XCTAssertEqual(entry?.id, "nested")
    }

    func testFindEntryMissing() {
        let object: [String: Any] = ["somethingElse": ["foo": "bar"]]
        XCTAssertNil(MoxieMCP.findEntry(in: object))
    }

    // MARK: message(withId:in:contentType:)

    func testMessagePlainJSON() throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["ok": true]])
        let message = try MoxieMCP.message(withId: 1, in: body, contentType: "application/json")
        XCTAssertEqual((message["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testMessageSSEStream() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "result": ["ok": true]])
        let sse = "event: message\ndata: \(String(decoding: payload, as: UTF8.self))\n\n"
        let message = try MoxieMCP.message(withId: 7, in: Data(sse.utf8), contentType: "text/event-stream")
        XCTAssertEqual((message["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testMessageSSEStreamWrongId() {
        let sse = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
        XCTAssertThrowsError(try MoxieMCP.message(withId: 2, in: Data(sse.utf8), contentType: "text/event-stream"))
    }

    func testMessageUnreadable() {
        XCTAssertThrowsError(try MoxieMCP.message(withId: 1, in: Data("not json".utf8), contentType: "application/json"))
    }
}
